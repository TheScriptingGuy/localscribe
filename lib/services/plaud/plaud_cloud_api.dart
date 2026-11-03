import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../ble/plaud_crypto.dart';

/// Consumer Plaud cloud API (`https://api.plaud.ai`) — the undocumented API the
/// Plaud app itself uses. LocalScribe uses it only for the *optional* "sign in to
/// Plaud and load the existing key" path: log in with the user's own Plaud account
/// and fetch the escrowed e2ee key for an already-bound recorder, so recordings can
/// be decrypted without re-enrolling.
///
/// Endpoints reverse-engineered from the app (see findings/plaud-consumer-api.md).
/// Login uses `loginSecure`, which RSA-encrypts the password with the server public
/// key from `/config/security` (`pass_pub_key`) and sends only the encrypted form —
/// matching the app — falling back to plaintext only if that config is unavailable.
class PlaudSession {
  final String accessToken;
  final String refreshToken;
  final String tokenType;
  final int expiresIn;

  PlaudSession({
    required this.accessToken,
    required this.refreshToken,
    this.tokenType = 'bearer',
    this.expiresIn = 0,
  });
}

/// Key material extracted from the cloud for one already-bound recorder.
class PlaudCloudKeys {
  final String? userId;
  final String? privateKeyPem; // user e2ee RSA private key (PEM)
  final String? publicKeyPem; // user e2ee RSA public key (PEM)
  final String? snSignature; // per-device serial signature
  final Uint8List? devicePublicKey; // 256-byte recorder public key, if the cloud returns it

  PlaudCloudKeys({
    this.userId,
    this.privateKeyPem,
    this.publicKeyPem,
    this.snSignature,
    this.devicePublicKey,
  });
}

class PlaudCloudApi {
  PlaudCloudApi({String? baseUrl, Dio? dio})
      : baseUrl = baseUrl ?? 'https://api.plaud.ai',
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl ?? 'https://api.plaud.ai',
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              headers: const {'Content-Type': 'application/json'},
            ));

  final String baseUrl;
  final Dio _dio;

  /// Sign in with email + password. When `passwordEncrypted` is provided (the
  /// password RSA-wrapped with the server key from `/config/security`), the
  /// plaintext `password` is **not** sent; otherwise it falls back to plaintext
  /// exactly as the app's own fallback path does.
  Future<PlaudSession> login(
    String email,
    String password, {
    String? passwordEncrypted,
  }) async {
    final body = <String, dynamic>{'email': email};
    if (passwordEncrypted != null && passwordEncrypted.isNotEmpty) {
      body['passwordEncrypted'] = passwordEncrypted;
    } else {
      body['password'] = password;
    }
    final resp = await _dio.post<dynamic>('/login/login-email', data: body);
    final d = _data(resp.data);
    return PlaudSession(
      accessToken: _str(d['access_token']),
      refreshToken: _str(d['refresh_token']),
      tokenType: _str(d['token_type'], fallback: 'bearer'),
      expiresIn: _int(d['expires_in']),
    );
  }

  /// Server security config: `pass_pub_key` (RSA public key) + `pass_algorithm`.
  Future<Map<String, dynamic>> fetchSecurityConfig() async {
    final resp = await _dio.get<dynamic>('/config/security');
    return _data(resp.data);
  }

  /// Sign in, encrypting the password with the server public key from
  /// `/config/security` (matching the app). Falls back to plaintext only if the
  /// security config is unavailable.
  Future<PlaudSession> loginSecure(String email, String password) async {
    try {
      final sec = await fetchSecurityConfig();
      final pub = sec['pass_pub_key'];
      if (pub is String && pub.isNotEmpty) {
        final enc = PlaudCrypto.encryptPasswordWithPublicKey(pub, password);
        return login(email, password, passwordEncrypted: enc);
      }
    } catch (_) {/* fall through to plaintext fallback */}
    return login(email, password);
  }

  /// Refresh the access token.
  Future<PlaudSession> refresh(String refreshToken) async {
    final resp = await _dio.post<dynamic>(
      '/auth/refresh-access-token',
      data: <String, dynamic>{'refresh_token': refreshToken},
    );
    final d = _data(resp.data);
    return PlaudSession(
      accessToken: _str(d['access_token']),
      refreshToken: _str(d['refresh_token'], fallback: refreshToken),
      tokenType: _str(d['token_type'], fallback: 'bearer'),
      expiresIn: _int(d['expires_in']),
    );
  }

  /// Sign one or more device serials (`/device/sn-sign`). Returns the parsed
  /// response `data` map, which carries the per-device SN signature and the
  /// escrowed key material (fields like `user_key`, `public_key_base64`,
  /// `private_key_base64`, `enc_private_key`, `sn_signature`).
  Future<Map<String, dynamic>> snSign(String accessToken, List<String> serials) async {
    final resp = await _dio.post<dynamic>(
      '/device/sn-sign',
      data: <String, dynamic>{'sns': serials},
      options: Options(headers: _auth(accessToken)),
    );
    return _data(resp.data);
  }

  /// Fetch the escrowed e2ee key pair (`/e2ee/get_key`). Returns the parsed
  /// `data` map (the RSA public/private key material).
  Future<Map<String, dynamic>> e2eeGetKey(String accessToken) async {
    final resp = await _dio.post<dynamic>(
      '/e2ee/get_key',
      options: Options(headers: _auth(accessToken)),
    );
    return _data(resp.data);
  }

  /// High-level flow: sign in and fetch the key material for `serial`. The
  /// response shapes are only partially mapped, so this extracts best-effort and
  /// is meant to be tightened once the live capture nails the exact fields.
  Future<PlaudCloudKeys> loadExistingKey(String email, String password, String serial) async {
    final session = await loginSecure(email, password);
    final sign = await snSign(session.accessToken, <String>[serial]);
    Map<String, dynamic> e2ee = const {};
    try {
      e2ee = await e2eeGetKey(session.accessToken);
    } catch (_) {/* key may already be inside sn-sign for some accounts */}
    final merged = <String, dynamic>{...sign, ...e2ee};
    return PlaudCloudKeys(
      userId: _firstStr(merged, const ['user_id', 'userId', 'member_id', 'memberId']),
      privateKeyPem: _keyPem(merged,
          const ['private_key', 'private_key_base64', 'user_key'],
          isPrivate: true),
      publicKeyPem:
          _keyPem(merged, const ['public_key', 'public_key_base64']),
      snSignature: _firstStr(merged, const ['sn_signature', 'snSignature', 'signature']),
      devicePublicKey: _deviceKey(merged),
    );
  }

  Map<String, String> _auth(String token) => {'Authorization': 'Bearer $token'};

  /// Best-effort flatten of the standard `{code,msg,data:{...}}` envelope: merge
  /// `data` over the top-level map so callers can read fields either way.
  static Map<String, dynamic> _data(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      final inner = raw['data'];
      if (inner is Map<String, dynamic>) return <String, dynamic>{...raw, ...inner};
      return raw;
    }
    return const <String, dynamic>{};
  }

  static String _str(dynamic v, {String fallback = ''}) =>
      (v == null) ? fallback : v.toString();

  static int _int(dynamic v) => (v is num) ? v.toInt() : int.tryParse('$v') ?? 0;

  static String? _firstStr(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  /// Normalise a base64- or PEM-encoded RSA key into a PEM string.
  static String? _keyPem(Map<String, dynamic> m, List<String> keys,
      {bool isPrivate = false}) {
    final header = isPrivate ? 'PRIVATE KEY' : 'PUBLIC KEY';
    for (final k in keys) {
      final v = m[k];
      if (v is String && v.isNotEmpty) {
        if (v.contains('BEGIN')) return v;
        final b64 = v.replaceAll(RegExp(r'\s'), '');
        if (_looksLikeBase64(b64)) {
          return '-----BEGIN $header-----\n$b64\n-----END $header-----';
        }
        return v;
      }
    }
    return null;
  }

  /// Candidate 256-byte recorder public key (device key written via `20 FE 03`).
  static Uint8List? _deviceKey(Map<String, dynamic> m) {
    for (final k in const ['device_public_key', 'sn_public_key', 'device_public_key_base64']) {
      final v = m[k];
      if (v is String && v.isNotEmpty) {
        final clean = v.replaceAll(RegExp(r'\s'), '');
        if (_looksLikeBase64(clean) || RegExp(r'^[0-9a-fA-F]{512}$').hasMatch(clean)) {
          final bytes = _looksLikeBase64(clean)
              ? base64Decode(clean)
              : _unhex(clean);
          if (bytes.length == 256) return bytes;
        }
      }
    }
    return null;
  }

  static bool _looksLikeBase64(String s) =>
      RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(s);

  static Uint8List _unhex(String s) {
    final out = Uint8List(s.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}
