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
    'gAAAAABq6fqW31qYKzubmJsCOX7eWc5puciV60XJMtJpZOPh8SduItSYqNPgwCdfzlsHsy3B2Jm-J0X-pm-amnZaGyf_a6V-WzzMEncV5TY0RLtswXp2xAg-2hm_OfGv9Tt31hAKLOUlN6EvHd8nLtFbhi3kmBAcvaXTimXiAkxfmLNhUq_i1JWCO1e4Jy4o0mdBXlY-DTTko2W9B1fcQMjtBkVtaK2FCLy3F7lhbAtFBC8XNQBIXO8m97zQbi85d3q7DQkb7JgugoCOwIhLFshol0t3_1p8K0V-aB3jSzBdPHJHyw-S7I_x6wb4l2FbOp4loWz5mE442hlwfWLY9n6fSFWUH9dkRoZxeMYUYRdoVfoBmMksSa2XSxz2Tf8hma7AEK8AtZDVIoq4cpYayZiSPv5As22w8DTha88naNOuhAsbwtIdS0kBux9lNaRylIVFvoipyQMcoHwloYDLQQMsA0MwKj5XMiY0rFxcPMRnfjj2TAI5EPzpdp9r0DKmPYNAJXIPA358GhITvP9kBzZquWQDCBmuf9ieY1QrOqn2jMraJQ3aaR7mlIeTUEuGxHGfCpO4EMtLeeCGRWyvc2GG9OLUBoEwPhAae16eE6wBk8B9WvBbemVoo6pjkibjx-QGzhxXTeUW';
const _gkToken =
    'gAAAAABq6fqWVb5ygg-tM_5PmgT-VX_cTVwTDEoGF7RZ8Kf0BlN3SOB7naj6JVDFTISSktEkivjd48pE8Xl2AB0-sccFEWa0DGz1msyrclmFL05mWD463gJJs1izu2dO2EH1vk469iM8ey2CI1h4mi5L_Y2YdM5f3GHsWXSCQwKdS0cBgFeSBPpktmNqFdrpRnCHcOk_DWd9llEL2kzhUSi9fx631RwhoVF062KcHY_8C4w5YTpw-mliJRGZymLtclzKrDNQ8JS21LHSDmotKq-Q3khL6hofEEP9ToZ20LSlJ-JfNjYOAqtI9Kgbe2QuDki1u0_lXJFjQfRqWc9JNFlyol5z0ksNV51_C12y6FwTeDMPgBE_R4-jTpdrQ64EPUBEM_aPp8iLQ6xu5phB5pkYeoVX1j_9ew==';

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

    final body = loginReq.data as String;
    expect(body, contains('username='));
    expect(body, contains('&client_id=web'));
    expect(body, contains('&password_encrypted=true'));
    final m = RegExp(r'password=([^&]+)').firstMatch(body);
    expect(m, isNotNull);
    final sealed = Uri.decodeQueryComponent(m!.group(1)!);
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

  test('listDevices() parses data_devices (direct sn and key-wrapped) from '
      '/device-app/device/list', () async {
    final adapter = _FakeAdapter((o) async {
      return {
        'status': 0,
        'msg': 'success',
        'data_devices': [
          // Live response shape: entries carry `sn` directly (no `key`).
          {
            'sn': '88831804767178688B',
            'name': 'Plaud Note',
            'model': '888',
            'version_number': 131592,
          },
          // Older app-log shape: entry wrapped in `key`.
          {
            'key': {
              'sn': '88831797810177288B',
              'name': 'Plaud Note',
              'model': '888',
              'version_number': 100,
            }
          },
        ],
      };
    });
    final api = PlaudCloudApi(
        dio: Dio(BaseOptions(baseUrl: 'https://example.com'))
          ..httpClientAdapter = adapter);

    final devices = await api.listDevices('AT');

    final req = adapter.seen.single;
    expect(req.path, '/device-app/device/list');
    expect(req.method, 'GET');
    expect(req.headers['X-Encrypt-Response'], '1');
    expect(devices, hasLength(2));
    expect(devices.first.sn, '88831804767178688B');
    expect(devices.first.modelLabel, 'Plaud Note');
  });

  test('loadAccount() lists devices and signs every serial', () async {
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
        case '/device-app/device/list':
          return {
            'status': 0,
            'msg': 'success',
            'data_devices': [
              {
                'key': {
                  'sn': '88831804767178688B',
                  'name': 'Plaud Note',
                  'model': '888',
                  'version_number': 131592,
                }
              },
            ],
          };
        case '/device/sn-sign':
          return _snToken;
        case '/e2ee/gen_key':
          return _gkToken;
        default:
          return {'status': 0};
      }
    });
    final api = PlaudCloudApi(
        dio: Dio(BaseOptions(baseUrl: 'https://example.com'))
          ..httpClientAdapter = adapter);

    final acc = await api.loadAccount('a@b.c', 'hunter2');

    expect(acc.userId, 'user-123');
    expect(acc.privateKeyPem, contains('BEGIN PRIVATE KEY'));
    expect(acc.devices, hasLength(1));
    expect(acc.devices.single.sn, '88831804767178688B');
    expect(acc.deviceKeys, contains('88831804767178688B'));
    expect(acc.deviceKeys['88831804767178688B'], hasLength(256));
  });
}
