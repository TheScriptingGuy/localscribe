import 'dart:convert';

import 'package:dio/dio.dart';

/// Official **Plaud Embedded** developer API
/// (`https://platform-us.plaud.ai/developer/api`), documented at docs.plaud.ai.
///
/// This is the sanctioned "Plaud SDK" REST surface. ⚠️ It only supports the
/// **Plaud Note Pro** (`881…`) and **NotePin S** (`882…`) — NOT the original
/// Plaud Note — so it is scaffolded here for the future and for partner
/// transcription/binding, not wired into the current device flow.
///
/// Auth is two-stage (OAuth2 client-credentials → per-user token), requiring
/// `client_id` + `secret_key` from the Plaud Developer Portal (apply at
/// dev.plaud.ai/contact — free).
class PlaudEmbeddedApi {
  PlaudEmbeddedApi({
    required String clientId,
    required String secretKey,
    String? baseUrl,
    Dio? dio,
  })  : _clientId = clientId,
        _secretKey = secretKey,
        baseUrl = baseUrl ?? 'https://platform-us.plaud.ai/developer/api',
        _dio = dio ??
            Dio(BaseOptions(
              baseUrl: baseUrl ?? 'https://platform-us.plaud.ai/developer/api',
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 20),
            ));

  final String _clientId;
  final String _secretKey;
  final String baseUrl;
  final Dio _dio;

  /// Exchange `client_id:secret_key` for a partner (application-level) token.
  Future<Map<String, dynamic>> getPartnerToken() async {
    final basic = base64Encode(utf8.encode('$_clientId:$_secretKey'));
    final resp = await _dio.post<dynamic>(
      '/oauth/partner/access-token',
      options: Options(
        headers: <String, dynamic>{
          'Authorization': 'Basic $basic',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      ),
      data: 'grant_type=client_credentials',
    );
    return _data(resp.data);
  }

  /// Mint a per-user access token with a partner token. `userId` must be a
  /// stable id (6–120 chars) scoped to your own product.
  Future<Map<String, dynamic>> getUserToken(String partnerToken, String userId) async {
    final resp = await _dio.post<dynamic>(
      '/open/partner/users/access-token',
      options: Options(headers: _auth(partnerToken)),
      data: <String, dynamic>{'user_id': userId, 'expires_in': 86400},
    );
    return _data(resp.data);
  }

  /// Register a device/owner association (idempotent re-bind).
  Future<Map<String, dynamic>> bindDevice(String userToken, Map<String, dynamic> body) async {
    final resp = await _dio.post<dynamic>(
      '/open/partner/sdk/bind',
      options: Options(headers: _auth(userToken)),
      data: body,
    );
    return _data(resp.data);
  }

  /// Remote binding state for a device (and every client_id ever bound).
  Future<Map<String, dynamic>> getBinding(String userToken, String serial) async {
    final resp = await _dio.get<dynamic>(
      '/open/partner/sdk/binding',
      queryParameters: <String, dynamic>{'sn': serial},
      options: Options(headers: _auth(userToken)),
    );
    return _data(resp.data);
  }

  /// Remove the device/owner association (idempotent).
  Future<Map<String, dynamic>> unbindDevice(String userToken, Map<String, dynamic> body) async {
    final resp = await _dio.post<dynamic>(
      '/open/partner/sdk/unbind',
      options: Options(headers: _auth(userToken)),
      data: body,
    );
    return _data(resp.data);
  }

  /// Sign the device serial (device auth pre-handshake).
  Future<Map<String, dynamic>> snSign(String userToken, String deviceType, String serial) async {
    final resp = await _dio.post<dynamic>(
      '/open/partner/sdk/sn-sign',
      options: Options(headers: _auth(userToken)),
      data: <String, dynamic>{'device_type': deviceType, 'sn': serial},
    );
    return _data(resp.data);
  }

  /// Generate/escrow the RSA key pair used for audio E2EE.
  Future<Map<String, dynamic>> genKey(String userToken) async {
    final resp = await _dio.post<dynamic>(
      '/open/partner/sdk/gen-key',
      options: Options(headers: _auth(userToken)),
    );
    return _data(resp.data);
  }

  Map<String, String> _auth(String token) => {'Authorization': 'Bearer $token'};

  static Map<String, dynamic> _data(dynamic raw) {
    if (raw is Map<String, dynamic>) {
      final inner = raw['data'];
      if (inner is Map<String, dynamic>) return <String, dynamic>{...raw, ...inner};
      return raw;
    }
    return const <String, dynamic>{};
  }
}
