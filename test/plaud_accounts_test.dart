import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localscribe/models/recording.dart';
import 'package:localscribe/services/ble/plaud_credentials.dart';

Map<String, dynamic> _device(String serial) => {
      'serial': serial,
      'name': 'Note $serial',
      'publicKeyHex': '00' * 256,
    };

void main() {
  group('PlaudCredentials.parseAccounts', () {
    test('reads the old single-account file as one account', () {
      final accounts = PlaudCredentials.parseAccounts({
        'userId': 'u1',
        'accessToken': 'tok',
        'rsaPrivateKeyPem': 'PEM',
        'devices': [_device('888A')],
      });
      expect(accounts, hasLength(1));
      expect(accounts.first.userId, 'u1');
      expect(accounts.first.accessToken, 'tok');
      expect(accounts.first.rsaPrivateKeyPem, 'PEM');
      expect(accounts.first.devices.single.serial, '888A');
      expect(accounts.first.email, '');
      expect(accounts.first.label, 'u1');
      expect(accounts.first.isConfigured, isTrue);
    });

    test('an old file without a user id has no account', () {
      expect(PlaudCredentials.parseAccounts({'devices': []}), isEmpty);
      expect(PlaudCredentials.parseAccounts({'userId': ''}), isEmpty);
    });

    test('reads a v2 file with several accounts', () {
      final accounts = PlaudCredentials.parseAccounts({
        'version': 2,
        'accounts': [
          {
            'userId': 'u1',
            'email': 'a@example.com',
            'rsaPrivateKeyPem': 'K1',
            'devices': [_device('1')],
          },
          {
            'userId': 'u2',
            'email': 'b@example.com',
            'refreshToken': 'r2',
            'apiBase': 'https://api.plaud.ai',
            'rsaPrivateKeyPem': 'K2',
            'devices': [_device('2'), _device('3')],
          },
        ],
      });
      expect(accounts.map((a) => a.userId), ['u1', 'u2']);
      expect(accounts[0].label, 'a@example.com');
      expect(accounts[1].refreshToken, 'r2');
      expect(accounts[1].apiBase, 'https://api.plaud.ai');
      expect(accounts[1].devices.map((d) => d.serial), ['2', '3']);
    });

    test('an account round-trips through json', () {
      final a = PlaudAccount(
        userId: 'u9',
        email: 'x@example.com',
        accessToken: 'a',
        refreshToken: 'r',
        apiBase: 'https://api.plaud.ai',
        rsaPrivateKeyPem: 'PEM',
        devices: [
          PlaudDeviceCred(
              serial: 'S1', name: 'One', publicKey: Uint8List(256)..[0] = 7),
        ],
      );
      final b = PlaudAccount.fromJson(a.toJson());
      expect(b.userId, 'u9');
      expect(b.email, 'x@example.com');
      expect(b.refreshToken, 'r');
      expect(b.devices.single.publicKey[0], 7);
    });

    test('an account without a key or devices is not configured', () {
      expect(PlaudAccount(userId: 'u').isConfigured, isFalse);
      expect(
          PlaudAccount(userId: 'u', rsaPrivateKeyPem: 'K').isConfigured, isFalse);
    });
  });

  group('Recording Plaud fields', () {
    test('round-trip and stay optional for older recordings', () {
      final r = Recording(
        id: 'r1',
        title: 't',
        createdAt: DateTime(2026, 1, 1),
        audioFile: 'audio.opus',
        source: RecordingSource.plaud,
        deviceFileId: 123,
        plaudSerial: 'S1',
        plaudAccountId: 'u1',
        plaudCloudId: 'c1',
      );
      final back = Recording.fromJson(r.toJson());
      expect(back.plaudSerial, 'S1');
      expect(back.plaudAccountId, 'u1');
      expect(back.plaudCloudId, 'c1');

      final old = Recording.fromJson({
        'id': 'r0',
        'title': 'old',
        'createdAt': '2026-01-01T00:00:00.000',
        'audioFile': 'audio.opus',
        'source': 'plaud',
        'deviceFileId': 5,
      });
      expect(old.plaudSerial, isNull);
      expect(old.plaudAccountId, isNull);
      expect(old.plaudCloudId, isNull);
      expect(old.toJson().containsKey('plaudSerial'), isFalse);
    });
  });
}
