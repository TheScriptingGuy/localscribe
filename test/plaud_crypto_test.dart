import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../lib/services/ble/plaud_crypto.dart';

void main() {
  group('PlaudCrypto password encryption (login)', () {
    test('generated keypair parses and round-trips RSA PKCS#1 v1.5', () {
      final keys = PlaudCrypto.generateKeyPair();
      final priv = PlaudCrypto.privateKeyFromPem(keys.privatePem);
      final pub = PlaudCrypto.publicKeyFromPem(keys.publicPem);
      expect(pub.modulus, isNotNull);
      expect(priv.modulus, isNotNull);

      const password = 'SuperSecret123!';
      final encrypted = PlaudCrypto.encryptPasswordWithPublicKey(
          keys.publicPem, password);

      // 2048-bit PKCS#1 v1.5 => 256-byte ciphertext, base64-encoded.
      final ct = base64Decode(encrypted);
      expect(ct.length, 256);

      // Server side: decrypt with the private key.
      final pt = PlaudCrypto.rsaUnwrap(priv, Uint8List.fromList(ct));
      expect(utf8.decode(pt), password);
    });

    test('publicKeyFromAny accepts PEM and bare base64 (SPKI)', () {
      final keys = PlaudCrypto.generateKeyPair();
      final viaPem = PlaudCrypto.publicKeyFromAny(keys.publicPem);

      final b64 = keys.publicPem
          .replaceAll('-----BEGIN PUBLIC KEY-----', '')
          .replaceAll('-----END PUBLIC KEY-----', '')
          .replaceAll(RegExp(r'\s'), '');
      final viaB64 = PlaudCrypto.publicKeyFromAny(b64);

      expect(viaB64.modulus, viaPem.modulus);
    });

    test('encryptPasswordWithPublicKey is deterministic-gated (PKCS#1 v1.5, not raw)',
        () {
      final keys = PlaudCrypto.generateKeyPair();
      // PKCS#1 v1.5 is randomized, so two encryptions differ (proves padding),
      // and both decrypt to the same plaintext.
      const password = 'hunter2';
      final a = PlaudCrypto.encryptPasswordWithPublicKey(keys.publicPem, password);
      final b = PlaudCrypto.encryptPasswordWithPublicKey(keys.publicPem, password);
      expect(a, isNot(b));

      final priv = PlaudCrypto.privateKeyFromPem(keys.privatePem);
      expect(
        utf8.decode(PlaudCrypto.rsaUnwrap(
            priv, Uint8List.fromList(base64Decode(a)))),
        password,
      );
      expect(
        utf8.decode(PlaudCrypto.rsaUnwrap(
            priv, Uint8List.fromList(base64Decode(b)))),
        password,
      );
    });
  });
}
