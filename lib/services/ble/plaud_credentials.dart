import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// One paired Plaud recorder: its serial, display name, and the 256-byte public
/// key the phone presents to it during the handshake.
class PlaudDeviceCred {
  final String serial;
  String name;
  final Uint8List publicKey; // 256 bytes

  PlaudDeviceCred({required this.serial, required this.name, required this.publicKey});

  Map<String, dynamic> toJson() => {
        'serial': serial,
        'name': name,
        'publicKeyHex': _hex(publicKey),
      };

  factory PlaudDeviceCred.fromJson(Map<String, dynamic> j) => PlaudDeviceCred(
        serial: j['serial'] ?? '',
        name: j['name'] ?? 'Plaud Note',
        publicKey: _unhex(j['publicKeyHex'] ?? ''),
      );
}

/// One Plaud cloud account and everything needed to talk to its recorders: the
/// user id (sent in the BLE/WiFi handshakes), the account's e2ee RSA key (used
/// to unwrap each session key and decrypt recordings) and the recorders bound
/// to it. A recorder only talks to the key of the account it is bound to, so
/// every recorder belongs to exactly one account.
class PlaudAccount {
  final String userId;
  String email;
  String? accessToken;
  String? refreshToken;

  /// API host for this account's region; null means the default.
  String? apiBase;
  String? rsaPrivateKeyPem;
  final List<PlaudDeviceCred> devices;

  PlaudAccount({
    required this.userId,
    this.email = '',
    this.accessToken,
    this.refreshToken,
    this.apiBase,
    this.rsaPrivateKeyPem,
    List<PlaudDeviceCred>? devices,
  }) : devices = devices ?? [];

  bool get isConfigured =>
      (rsaPrivateKeyPem?.isNotEmpty ?? false) && devices.isNotEmpty;

  /// What to show in lists: the sign-in email, else the user id.
  String get label => email.isNotEmpty ? email : userId;

  Map<String, dynamic> toJson() => {
        'userId': userId,
        if (email.isNotEmpty) 'email': email,
        'accessToken': accessToken,
        if (refreshToken != null) 'refreshToken': refreshToken,
        if (apiBase != null) 'apiBase': apiBase,
        'rsaPrivateKeyPem': rsaPrivateKeyPem,
        'devices': devices.map((d) => d.toJson()).toList(),
      };

  factory PlaudAccount.fromJson(Map<String, dynamic> j) => PlaudAccount(
        userId: (j['userId'] as String?) ?? '',
        email: (j['email'] as String?) ?? '',
        accessToken: j['accessToken'] as String?,
        refreshToken: j['refreshToken'] as String?,
        apiBase: j['apiBase'] as String?,
        rsaPrivateKeyPem: j['rsaPrivateKeyPem'] as String?,
        devices: ((j['devices'] as List?) ?? const [])
            .map((e) => PlaudDeviceCred.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

/// Credentials for talking to the user's own Plaud recorders directly: one
/// entry per signed-in Plaud account. Stored in the app's private documents
/// directory (never in git or the APK).
///
/// File format v2: `{"version": 2, "accounts": [...]}`. The earlier single
/// account format (`userId`/`accessToken`/`rsaPrivateKeyPem`/`devices` at the
/// top level) is read as one account and rewritten as v2 on the next save.
class PlaudCredentials extends ChangeNotifier {
  final List<PlaudAccount> accounts = [];

  late File _file;

  /// Every recorder on every account.
  List<PlaudDeviceCred> get devices =>
      [for (final a in accounts) ...a.devices];

  bool get isConfigured => accounts.any((a) => a.isConfigured);

  /// True when at least one account is signed in.
  bool get hasAccounts => accounts.isNotEmpty;

  Future<void> load() async {
    final docs = await getApplicationDocumentsDirectory();
    _file = File(p.join(docs.path, 'plaud_credentials.json'));
    if (await _file.exists()) {
      try {
        final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
        accounts
          ..clear()
          ..addAll(parseAccounts(j));
      } catch (_) {/* start empty on a corrupt file */}
    }
    notifyListeners();
  }

  /// Reads either file format into accounts. Exposed for tests.
  @visibleForTesting
  static List<PlaudAccount> parseAccounts(Map<String, dynamic> j) {
    if (j['accounts'] is List) {
      return [
        for (final e in j['accounts'] as List)
          PlaudAccount.fromJson(Map<String, dynamic>.from(e)),
      ];
    }
    // v1: a single account stored flat.
    final userId = j['userId'] as String?;
    if (userId == null || userId.isEmpty) return [];
    return [PlaudAccount.fromJson(j)];
  }

  PlaudAccount? accountById(String userId) {
    for (final a in accounts) {
      if (a.userId == userId) return a;
    }
    return null;
  }

  /// The account a recorder is bound to.
  PlaudAccount? accountFor(String serial) {
    for (final a in accounts) {
      if (a.devices.any((d) => d.serial == serial)) return a;
    }
    return null;
  }

  PlaudDeviceCred? deviceBySerial(String serial) {
    for (final a in accounts) {
      for (final d in a.devices) {
        if (d.serial == serial) return d;
      }
    }
    return null;
  }

  /// Adds [account], or replaces the signed-in account with the same user id
  /// (signing in again refreshes its key, token and recorder list).
  Future<void> upsertAccount(PlaudAccount account) async {
    final i = accounts.indexWhere((a) => a.userId == account.userId);
    if (i >= 0) {
      accounts[i] = account;
    } else {
      accounts.add(account);
    }
    await _save();
  }

  /// Signs one account out; the others are untouched.
  Future<void> removeAccount(String userId) async {
    accounts.removeWhere((a) => a.userId == userId);
    await _save();
  }

  /// Signs every account out and deletes the credentials file.
  Future<void> clear() async {
    accounts.clear();
    if (await _file.exists()) await _file.delete();
    notifyListeners();
  }

  /// Persists changes made to an account in place (e.g. a refreshed token).
  Future<void> save() => _save();

  Future<void> _save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
        jsonEncode({
          'version': 2,
          'accounts': accounts.map((a) => a.toJson()).toList(),
        }),
        flush: true);
    await tmp.rename(_file.path);
    notifyListeners();
  }
}

String _hex(Uint8List b) {
  final sb = StringBuffer();
  for (final x in b) {
    sb.write(x.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List _unhex(String s) {
  final clean = s.replaceAll(RegExp(r'\s'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
