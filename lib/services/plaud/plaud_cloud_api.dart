import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../ble/plaud_crypto.dart';

/// Logs every request/response via `dart:developer.log` (visible in `adb logcat`
/// even in release builds) so a failing endpoint can be identified precisely.
class _LoggingInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    developer.log('REQ ${options.method} ${options.uri} body=${_trim(options.data)}',
        name: 'PlaudApi');
    handler.next(options);
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    developer.log(
        'RES ${response.requestOptions.method} ${response.requestOptions.uri} '
        '-> ${response.statusCode} body=${_trim(response.data)}',
        name: 'PlaudApi');
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    developer.log(
        'ERR ${err.requestOptions.method} ${err.requestOptions.uri} '
        '-> ${err.response?.statusCode} ${err.type.name} body=${_trim(err.response?.data)}',
        name: 'PlaudApi');
    handler.next(err);
  }

  static String _trim(dynamic v) {
    final s = (v == null) ? '' : v.toString();
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }
}

/// Consumer Plaud cloud API (`https://api-euc1.plaud.ai` — the Europe Central
/// regional host the Plaud app actually uses, confirmed from its own `[REQ]`/`[RES]`
/// logcat lines; `api.plaud.ai` is the US default). LocalScribe uses it only for the
/// *optional* "sign in to Plaud and load the existing key" path: log in with the
/// user's own Plaud account and fetch the escrowed e2ee key for an already-bound
/// recorder, so recordings can be decrypted without re-enrolling.
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
  final String userId;

  PlaudSession({
    required this.accessToken,
    required this.refreshToken,
    this.tokenType = 'bearer',
    this.expiresIn = 0,
    this.userId = '',
  });
}

/// The Plaud API reports errors in the response body (`status`/`code` != 0)
/// while still returning HTTP 200, so this surfaces those as a real exception.
class PlaudApiException implements Exception {
  PlaudApiException(this.message);
  final String message;
  @override
  String toString() => message;
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
      : baseUrl = baseUrl ?? 'https://api-euc1.plaud.ai',
        _dio = dio ??
            (Dio(BaseOptions(
              baseUrl: baseUrl ?? 'https://api-euc1.plaud.ai',
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
              headers: const {'Content-Type': 'application/json'},
            ))..interceptors.add(_LoggingInterceptor()));

  final String baseUrl;
  final Dio _dio;

  /// Fernet key the API uses to encrypt responses when `X-Encrypt-Response: 1`
  /// is sent (standard Fernet, 32 bytes). Extracted from the app (class `wng.b`,
  /// 7 joined parts) and verified live.
  static const String _fernetKey =
      '8rRmMCskL3NaUiGr-UsmEEeI8NKH-ZfeGbpRGqSLpuI=';

  /// Sign in with email + password.
  ///
  /// `POST /auth/access-token` (form-encoded) with the password sealed with the
  /// server's secp256k1 public key from `/config/security`
  /// (`password_encrypted=true`, `client_id=web`) — no plaintext password. The
  /// response is **flat** (no `data` wrapper) and reports errors via `status`
  /// while still answering HTTP 200 (`status:-2` = wrong password).
  Future<PlaudSession> login(String email, String password) async {
    final sec = await fetchSecurityConfig();
    final pub = sec['pass_pub_key'];
    if (pub is! String || pub.isEmpty) {
      throw PlaudApiException('Plaud returned no pass_pub_key to seal the password');
    }
    final sealed = PlaudCrypto.encryptPasswordSecp256k1(pub, password);
    // Encode the form body explicitly (rather than relying on dio's Map
    // transformer) so the base64 `+`/`/`/`=` in the sealed password survive.
    final body = 'username=${Uri.encodeQueryComponent(email)}'
        '&password=${Uri.encodeQueryComponent(sealed)}'
        '&client_id=web'
        '&password_encrypted=true';
    final resp = await _dio.post<dynamic>(
      '/auth/access-token',
      data: body,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final d = _data(resp.data);
    final status = _int(d['status']);
    if (status != 0) {
      throw PlaudApiException(
          'Plaud login failed (status $status): ${_str(d['msg'])}');
    }
    return PlaudSession(
      accessToken: _str(d['access_token']),
      refreshToken: _str(d['refresh_token']),
      tokenType: _str(d['token_type'], fallback: 'bearer'),
      expiresIn: _int(d['expires_in']),
      userId: _str(d['uid']),
    );
  }

  /// Server security config: `pass_pub_key` + `pass_algorithm`.
  Future<Map<String, dynamic>> fetchSecurityConfig() async {
    final resp = await _dio.get<dynamic>('/config/security');
    return _data(resp.data);
  }

  /// Sign in (password sealed with secp256k1 ECIES inside `login`).
  Future<PlaudSession> loginSecure(String email, String password) =>
      login(email, password);

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

  /// Sign one or more device serials (`/device/sn-sign`). Requires
  /// `X-Encrypt-Response: 1`; the body is a Fernet token, decrypted here.
  /// Returns `data.signature[serial]` = base64 of the 256-byte SN signature.
  Future<Map<String, dynamic>> snSign(String accessToken, List<String> serials) async {
    final resp = await _dio.post<dynamic>(
      '/device/sn-sign',
      data: <String, dynamic>{'sns': serials},
      options: Options(
        headers: _auth(accessToken),
        responseType: ResponseType.plain,
      ),
    );
    return _fernetData(resp.data);
  }

  /// Fetch the escrowed e2ee RSA key pair (`/e2ee/gen_key`; `/e2ee/get_key` is
  /// gone). Fernet-decrypted. Returns `data.private_key_base64` /
  /// `public_key_base64` (base64 of RSA-2048 PEM text).
  Future<Map<String, dynamic>> e2eeGetKey(String accessToken) async {
    final resp = await _dio.post<dynamic>(
      '/e2ee/gen_key',
      options: Options(
        headers: _auth(accessToken),
        responseType: ResponseType.plain,
      ),
    );
    return _fernetData(resp.data);
  }

  /// High-level flow: sign in, then fetch the SN signature + e2ee key for
  /// `serial`. Response shapes are verified against the live API.
  Future<PlaudCloudKeys> loadExistingKey(String email, String password, String serial) async {
    final session = await loginSecure(email, password);
    final sign = await snSign(session.accessToken, <String>[serial]);

    String? snSignature;
    Uint8List? deviceKey;
    final sigMap = sign['signature'];
    if (sigMap is Map) {
      final v = sigMap[serial];
      if (v is String && v.isNotEmpty) {
        snSignature = v;
        final bytes = _tryB64(v);
        if (bytes != null && bytes.length == 256) deviceKey = bytes;
      }
    }

    Map<String, dynamic> e2ee = const {};
    try {
      e2ee = await e2eeGetKey(session.accessToken);
    } catch (_) {/* key may already be inside sn-sign for some accounts */}

    return PlaudCloudKeys(
      userId: session.userId.isNotEmpty ? session.userId : null,
      privateKeyPem:
          _b64Pem(e2ee, const ['private_key_base64', 'private_key', 'user_key']),
      publicKeyPem: _b64Pem(e2ee, const ['public_key_base64', 'public_key']),
      snSignature: snSignature,
      devicePublicKey: deviceKey,
    );
  }

  Map<String, String> _auth(String token) => {
        'Authorization': 'Bearer $token',
        'X-Encrypt-Response': '1',
      };

  /// Fernet-decrypt a plain response body and parse it as the `{status,data}`
  /// envelope (merging `data` over the top level via `_data`).
  Map<String, dynamic> _fernetData(dynamic body) {
    final token = body is String ? body : body.toString();
    final json = PlaudCrypto.fernetDecrypt(token, _fernetKey);
    return _data(jsonDecode(json));
  }

  /// Decode a field that is base64(PEM text) back to the PEM string.
  static String? _b64Pem(Map<String, dynamic> m, List<String> keys) {
    for (final k in keys) {
      final v = m[k];
      if (v is String && v.isNotEmpty) {
        if (v.contains('BEGIN')) return v;
        final bytes = _tryB64(v.replaceAll(RegExp(r'\s'), ''));
        if (bytes != null) {
          final s = utf8.decode(bytes);
          if (s.contains('BEGIN')) return s;
        }
      }
    }
    return null;
  }

  static Uint8List? _tryB64(String s) {
    try {
      return base64Decode(s);
    } catch (_) {
      return null;
    }
  }

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
