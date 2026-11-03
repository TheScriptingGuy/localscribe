import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/services/plaud/plaud_cloud_api.dart';

/// A Dio adapter that never touches the network: it inspects the request and
/// returns canned content. A `String` result is returned raw (Fernet token);
/// anything else is JSON-encoded.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<Object> Function(RequestOptions options) handler;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    final body = await handler(options);
    final String s = body is String ? body : jsonEncode(body);
    return ResponseBody.fromString(
      s,
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

// A valid compressed secp256k1 point (the reference vector's public key).
const _refPub =
    '03565039cd9ca53ca784f7d692fa133cf89d3924325cce282f822305a46a8e3660';

// Fernet tokens (key 8rRmMCskL3NaUiGr-UsmEEeI8NKH-ZfeGbpRGqSLpuI=) for the
// sn-sign / gen_key JSON responses, generated for these fixtures.
const _snToken =
    'gAAAAABq6fbP0aOq-GyIB9WX11l8yrjepqpb4c4-ED1jQpnpVHA0TE_Ic0u7UBZIyXq7U_5OtXL-Hqla1klrkvGA_6jWONVlPDFJadB0n-iY5yEB9NilN19tMH8cZHCOUueNhiNr_qkHoqAAMJEkASIq7fzQoFvgNgUZhavFH-0d-GQkee53lB8ClzMZg9Bfs22awzMBJPhhIxyG50JKh7wVB2rVrbKODfH453itv6snmToI70yteQwNZVSZdXkv6D_EiIgcU91PuEf6bBppvL188dYvre1Ty5nqBqYtEZg058przeOQw_yy7z1_dEUb041i7y5EcOArvJ_cGbfZzT_OYUhR0RyvjBx1QQVaKPhBPMGjHp_XbgKuRXVscbZZkWuPNlOPaubWwo4Ky1xylYv-yq7cpmT5STTLpNdCoK3J-Y-9_tgFFwriKSaTfH7iNDJUbh4BnQfRooQ45gBvXokv37qwsladLgfgvoYyoCD-Ws-ttpMbEWX45FgsNin7ejHDO4aN6xzYPjZYJ6730-o-mlXg72zq9DDqhiXbldJk2P-d8DTa5OFC0MVquzYLQif7F73hlvSQh4J-LczLeqoeWd7tygOy_y4eOApoE_MNLQ07VXYDv5o3JP3QH_wgK1BnOQTqjdMb';
const _gkToken =
    'gAAAAABq6fbPeva5UGYU85NfB1vY2mVQcMkDPhe0jJ_dAIYQH3mp1msLJPUTqmUrzWQ3zqaPTbTWMXpOd7RYLUxZU8geQKajJTzW-2LtsFH2Vw8cW3gvtDS2GzIY1QD8gL0IHIPDfe0Wfi6KMV-5z85rnq4FMD5k5Js1JTLONDm4gjuqgY73yV2pZG1EW9L_ocYqSdW_n_vRtdSsbMaSZbdCZpoEIhvhYiW0j25eY9dV3rGtUxpLjS8UXK4Eiz43nk3QkDmq0jZnhaW9_cOu3eQxmf_cbcKLGIWTCPiJbG6emq4b6qJd5wBnmBx3wHkY_3dDMLc21vXYTxGaLSzkRJ77_wH7u1W0ghOtPKgLhYCt3Mcf_gh9EkqTbRHDgEZ5U0h6_05TLSxGuAq-IsG-R_iKgPx0odJ8kw==';

void main() {
  test('login() seals the password and POSTs form-encoded to /auth/access-token',
      () async {
    final adapter = _FakeAdapter((o) async {
      if (o.path == '/config/security') {
        return {
          'status': 0,
          'data': {'pass_pub_key': _refPub, 'pass_algorithm': 'secp256k1'},
        };
      }
      return {
        'status': 0,
        'access_token': 'AT',
        'refresh_token': 'RT',
        'token_type': 'bearer',
        'expires_in': 3600,
        'uid': 'user-123',
      };
    });
    final api = PlaudCloudApi(
        dio: Dio(BaseOptions(baseUrl: 'https://example.com'))
          ..httpClientAdapter = adapter);

    final session = await api.login('a@b.c', 'hunter2');

    final loginReq = adapter.seen.firstWhere((r) => r.path == '/auth/access-token');
    expect(loginReq.method, 'POST');
    expect(loginReq.contentType, contains('application/x-www-form-urlencoded'));

    final data = loginReq.data as Map<String, dynamic>;
    expect(data['username'], 'a@b.c');
    expect(data['client_id'], 'web');
    expect(data['password_encrypted'], 'true');
    // The sealed password is an ECIES envelope: 65B ephemeral pub + nonce/tag/ct.
    final sealed = (data['password'] as String);
    expect(base64Decode(sealed).length, greaterThan(65));

    expect(session.accessToken, 'AT');
    expect(session.refreshToken, 'RT');
    expect(session.userId, 'user-123');
  });

  test('login() throws PlaudApiException when status != 0', () async {
    final adapter = _FakeAdapter((o) async {
      if (o.path == '/config/security') {
        return {
          'status': 0,
          'data': {'pass_pub_key': _refPub, 'pass_algorithm': 'secp256k1'},
        };
      }
      return {'status': -2, 'msg': 'wrong account or password'};
    });
    final api = PlaudCloudApi(
        dio: Dio(BaseOptions(baseUrl: 'https://example.com'))
          ..httpClientAdapter = adapter);

    expect(() => api.login('a@b.c', 'wrong'), throwsA(isA<PlaudApiException>()));
  });

  test('loadExistingKey() extracts SN signature + e2ee key from Fernet responses',
      () async {
    final adapter = _FakeAdapter((o) async {
      switch (o.path) {
        case '/config/security':
          return {
            'status': 0,
            'data': {'pass_pub_key': _refPub, 'pass_algorithm': 'secp256k1'},
          };
        case '/auth/access-token':
          return {
            'status': 0,
            'access_token': 'AT',
            'refresh_token': 'RT',
            'uid': 'user-123',
          };
        case '/device/sn-sign':
          return _snToken; // raw Fernet token
        case '/e2ee/gen_key':
          return _gkToken; // raw Fernet token
        default:
          return {'status': 0};
      }
    });
    final api = PlaudCloudApi(
        dio: Dio(BaseOptions(baseUrl: 'https://example.com'))
          ..httpClientAdapter = adapter);

    final out = await api.loadExistingKey('a@b.c', 'hunter2', '88831804767178688B');

    expect(out.userId, 'user-123');
    expect(out.privateKeyPem, contains('BEGIN PRIVATE KEY'));
    expect(out.publicKeyPem, contains('BEGIN PUBLIC KEY'));
    expect(out.snSignature, isNotNull);
    expect(out.devicePublicKey, hasLength(256));
  });
}
