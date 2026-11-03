import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/services/ble/plaud_crypto.dart';
import '../lib/services/plaud/plaud_cloud_api.dart';

/// A Dio adapter that never touches the network: it inspects the request and
/// returns canned JSON. Lets us verify request construction + response parsing
/// without the (Cloudflare-gated) live API.
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
  test('login() sends passwordEncrypted (no plaintext) when provided', () async {
    final adapter = _FakeAdapter((o) async => {
          'code': 0,
          'data': {
            'access_token': 'AT',
            'refresh_token': 'RT',
            'token_type': 'bearer',
            'expires_in': 3600,
          },
        });
    final api = PlaudCloudApi(
        dio: Dio(BaseOptions(baseUrl: 'https://example.com'))
          ..httpClientAdapter = adapter);

    final session = await api.login('a@b.c', 'hunter2', passwordEncrypted: 'ENC');

    final req = adapter.seen.single;
    final data = req.data as Map<String, dynamic>;
    expect(req.method, 'POST');
    expect(req.path, '/auth/otp-login');
    expect(data['email'], 'a@b.c');
    expect(data['passwordEncrypted'], 'ENC');
    expect(data.containsKey('password'), isFalse);
    expect(session.accessToken, 'AT');
    expect(session.refreshToken, 'RT');
  });

  test('login() falls back to plaintext password when no encrypted form', () async {
    final adapter = _FakeAdapter((o) async => {
          'code': 0,
          'data': {'access_token': 'AT', 'refresh_token': 'RT'},
        });
    final api = PlaudCloudApi(
        dio: Dio(BaseOptions(baseUrl: 'https://example.com'))
          ..httpClientAdapter = adapter);

    await api.login('a@b.c', 'hunter2');

    final data = adapter.seen.single.data as Map<String, dynamic>;
    expect(data['password'], 'hunter2');
    expect(data.containsKey('passwordEncrypted'), isFalse);
  });

  test('loginSecure() fetches /config/security and encrypts the password', () async {
    final keys = PlaudCrypto.generateKeyPair();
    final adapter = _FakeAdapter((o) async {
      switch (o.path) {
        case '/config/security':
          return {
            'code': 0,
            'data': {'pass_pub_key': keys.publicPem, 'pass_algorithm': 'RSA'},
          };
        default:
          return {
            'code': 0,
            'data': {'access_token': 'AT', 'refresh_token': 'RT'},
          };
      }
    });
    final api = PlaudCloudApi(
        dio: Dio(BaseOptions(baseUrl: 'https://example.com'))
          ..httpClientAdapter = adapter);

    final session = await api.loginSecure('a@b.c', 'hunter2');

    expect(session.accessToken, 'AT');

    final loginReq = adapter.seen.firstWhere((r) => r.path == '/auth/otp-login');
    final data = loginReq.data as Map<String, dynamic>;
    expect(data.containsKey('password'), isFalse);
    final enc = data['passwordEncrypted'] as String;
    // Should be a 256-byte PKCS#1 v1.5 ciphertext, base64 (344 chars).
    expect(base64Decode(enc).length, 256);
    // And should decrypt back with the private key we handed out.
    final priv = PlaudCrypto.privateKeyFromPem(keys.privatePem);
    expect(
      utf8.decode(PlaudCrypto.rsaUnwrap(priv, Uint8List.fromList(base64Decode(enc)))),
      'hunter2',
    );
  });

  test('loadExistingKey() parses sn-sign + e2ee responses defensively', () async {
    final keys = PlaudCrypto.generateKeyPair();
    final pubB64 = base64Encode(
        utf8.encode('-----BEGIN PUBLIC KEY-----\nAAEC\n-----END PUBLIC KEY-----'));
    final privB64 = base64Encode(
        utf8.encode('-----BEGIN PRIVATE KEY-----\nAAEC\n-----END PRIVATE KEY-----'));

    final adapter = _FakeAdapter((o) async {
      switch (o.path) {
        case '/config/security':
          return {'data': {'pass_pub_key': keys.publicPem}};
        case '/auth/otp-login':
          return {'data': {'access_token': 'AT', 'refresh_token': 'RT'}};
        case '/device/sn-sign':
          return {
            'code': 0,
            'data': {
              'user_id': 'user-123',
              'private_key_base64': privB64,
              'public_key_base64': pubB64,
              'sn_signature': 'sig-abc',
            },
          };
        case '/e2ee/get_key':
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
    // The device public key is not in these responses, so it stays null (the
    // 256B `20 FE 03` value comes from elsewhere — confirmed by the live capture).
    expect(out.devicePublicKey, isNull);
  });
}
