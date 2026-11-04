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

/// Credentials for talking to the user's own Plaud recorder directly, imported
/// once from the user's phone. Stored in the app's private documents directory
/// (never in git or the APK). The RSA private key is the user's own key used to
/// unwrap the per-session ChaCha key the device sends.
class PlaudCredentials extends ChangeNotifier {
  String? userId;
  String? rsaPrivateKeyPem;
  final List<PlaudDeviceCred> devices = [];

  late File _file;

  bool get isConfigured =>
      (rsaPrivateKeyPem?.isNotEmpty ?? false) && devices.isNotEmpty;

  Future<void> load() async {
    final docs = await getApplicationDocumentsDirectory();
    _file = File(p.join(docs.path, 'plaud_credentials.json'));
    if (await _file.exists()) {
      try {
        final j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
        userId = j['userId'];
        rsaPrivateKeyPem = j['rsaPrivateKeyPem'];
        devices
          ..clear()
          ..addAll(((j['devices'] as List?) ?? const [])
              .map((e) => PlaudDeviceCred.fromJson(Map<String, dynamic>.from(e))));
      } catch (_) {/* start empty on a corrupt file */}
    }
    notifyListeners();
  }

  Future<void> setIdentity({required String userId, required String pem}) async {
    this.userId = userId.trim();
    rsaPrivateKeyPem = pem.trim();
    await _save();
  }

  Future<void> upsertDevice(PlaudDeviceCred d) async {
    final i = devices.indexWhere((e) => e.serial == d.serial);
    if (i >= 0) {
      devices[i] = d;
    } else {
      devices.add(d);
    }
    await _save();
  }

  PlaudDeviceCred? deviceBySerial(String serial) {
    for (final d in devices) {
      if (d.serial == serial) return d;
    }
    return null;
  }

  /// Replace the whole device list in one save (used by the "pair all" flow so
  /// a single sign-in reflects every recorder on the account).
  Future<void> replaceDevices(List<PlaudDeviceCred> next) async {
    devices
      ..clear()
      ..addAll(next);
    await _save();
  }

  Future<void> clear() async {
    userId = null;
    rsaPrivateKeyPem = null;
    devices.clear();
    if (await _file.exists()) await _file.delete();
    notifyListeners();
  }

  Future<void> _save() async {
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsString(
        jsonEncode({
          'userId': userId,
          'rsaPrivateKeyPem': rsaPrivateKeyPem,
          'devices': devices.map((d) => d.toJson()).toList(),
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
