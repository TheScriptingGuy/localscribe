import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/services/plaud/plaud_cloud_api.dart';

/// A Dio adapter that never touches the network: it inspects the request and
/// returns canned JSON. Lets us verify request construction + response parsing
/// without the live API.
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);

  final Future<Map<String, dynamic>> Function(RequestOptions options) handler;
  final List<RequestOptions> seen = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    seen.add(options);
    final body = await handler(options);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('login() POSTs username+password to /auth/access-token', () async {
    final adapter = _FakeAdapter((o) async => {
          'status': 0,
          'msg': 'success',
          'access_token': 'AT',
          'refresh_token': 'RT',
          'token_type': 'bearer',
          'expires_in': 3600,
          'uid': 'user-123',
        });
    final api = PlaudCloudApi(
        dio: Dio(BaseOptions(baseUrl: 'https://example.com'))
          ..httpClientAdapter = adapter);

    final session = await api.login('a@b.c', 'hunter2');

    final req = adapter.seen.single;
    final data = req.data as Map<String, dynamic>;
    expect(req.method, 'POST');
    expect(req.path, '/auth/access-token');
    expect(data['username'], 'a@b.c');
    expect(data['password'], 'hunter2');
    expect(session.accessToken, 'AT');
    expect(session.refreshToken, 'RT');
    expect(session.userId, 'user-123');
  });

  test('login() throws PlaudApiException when status != 0', () async {
    final adapter = _FakeAdapter((o) async => {
          'status': -2,
          'msg': 'wrong account or password',
          'access_token': '',
          'refresh_token': '',
        });
    final api = PlaudCloudApi(
        dio: Dio(BaseOptions(baseUrl: 'https://example.com'))
          ..httpClientAdapter = adapter);

    expect(
      () => api.login('a@b.c', 'wrong'),
      throwsA(isA<PlaudApiException>()),
    );
  });

  test('loginSecure() delegates to the plaintext /auth/access-token login',
      () async {
    final adapter = _FakeAdapter((o) async => {
          'status': 0,
          'access_token': 'AT',
          'refresh_token': 'RT',
        });
    final api = PlaudCloudApi(
        dio: Dio(BaseOptions(baseUrl: 'https://example.com'))
          ..httpClientAdapter = adapter);

    final session = await api.loginSecure('a@b.c', 'hunter2');

    expect(session.accessToken, 'AT');
    final req = adapter.seen.single;
    expect(req.path, '/auth/access-token');
    final data = req.data as Map<String, dynamic>;
    expect(data['username'], 'a@b.c');
    expect(data['password'], 'hunter2');
  });

  test('loadExistingKey() parses sn-sign + e2ee responses defensively',
      () async {
    final pubB64 = base64Encode(
        utf8.encode('-----BEGIN PUBLIC KEY-----\nAAEC\n-----END PUBLIC KEY-----'));
    final privB64 = base64Encode(
        utf8.encode('-----BEGIN PRIVATE KEY-----\nAAEC\n-----END PRIVATE KEY-----'));

    final adapter = _FakeAdapter((o) async {
      switch (o.path) {
        case '/auth/access-token':
          return {
            'status': 0,
            'access_token': 'AT',
            'refresh_token': 'RT',
            'uid': 'user-123',
          };
        case '/device/sn-sign':
          return {
            'code': 0,
            'data': {
              'private_key_base64': privB64,
              'public_key_base64': pubB64,
              'sn_signature': 'sig-abc',
            },
          };
        case '/e2ee/gen_key':
          return {'code': 0, 'data': <String, dynamic>{}};
        default:
          return {'code': 0, 'data': <String, dynamic>{}};
      }
    });
    final api = PlaudCloudApi(
        dio: Dio(BaseOptions(baseUrl: 'https://example.com'))
          ..httpClientAdapter = adapter);

    final out = await api.loadExistingKey('a@b.c', 'hunter2', '88831804767178688B');

    expect(out.userId, 'user-123');
    expect(out.privateKeyPem, contains('BEGIN PRIVATE KEY'));
    expect(out.publicKeyPem, contains('BEGIN PUBLIC KEY'));
    expect(out.snSignature, 'sig-abc');
    // The device public key is not in these responses, so it stays null.
    expect(out.devicePublicKey, isNull);
  });
}
