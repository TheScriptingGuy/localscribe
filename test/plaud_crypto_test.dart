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

  group('PlaudCrypto secp256k1 ECIES password seal', () {
    // Reference vector from jaisonerick/plaud-cli (eciesjs) — see crypto_test.go.
    const refPriv =
        'f9e7d2a02c6ceefd4590f8b79b6af668b13ff5140bcaea5e41db7cc2a4827351';
    const refPub =
        '03565039cd9ca53ca784f7d692fa133cf89d3924325cce282f822305a46a8e3660';
    const refPlain = '{"pass":"s3nha-de-teste!","time":1786000000}';
    const refEnvelope =
        'BEyG417VRylogNJPeoZ7GSC8OW91Td9bKvWAyphMSQX2kzj4qQ4HAp+1i6I3neCqpXuGITk2L/pnWQla8D0GvuyaNl36aIHr4rUn/gkaFgfGvnwX65owGkpaf1RZr2PhVjHIC63o0pW5DnBVVSJ8dFL79MUw4WDZYNbpYbE4CESgPPWoAx7jtqCgmJGq';

    test('decrypts the eciesjs reference envelope', () {
      expect(PlaudCrypto.decryptPasswordSecp256k1(refPriv, refEnvelope), refPlain);
    });

    test('encrypt/decrypt round-trips against the reference key', () {
      final sealed = PlaudCrypto.encryptPasswordSecp256k1(refPub, 's3nha-de-teste!');
      final plain = PlaudCrypto.decryptPasswordSecp256k1(refPriv, sealed);
      expect(plain, contains('"pass":"s3nha-de-teste!"'));
      expect(plain, contains('"time":'));
    });

    test('envelopes are never deterministic (ephemeral key per call)', () {
      final a = PlaudCrypto.encryptPasswordSecp256k1(refPub, 'same');
      final b = PlaudCrypto.encryptPasswordSecp256k1(refPub, 'same');
      expect(a, isNot(b));
    });
  });

  group('PlaudCrypto Fernet', () {
    test('decrypts a known Fernet token', () {
      const key = '8rRmMCskL3NaUiGr-UsmEEeI8NKH-ZfeGbpRGqSLpuI=';
      const token =
          'gAAAAABq6faFOWmt4j5QB8N1icLmLN28oQv5SezCXvkb4J-7raO_lyVPTIhKf5iZ9ps2xThKa2ksQO5Jfs8OuMFjbkek0sjnyslP25Q5sg4ksB8RS_d5tgM=';
      expect(PlaudCrypto.fernetDecrypt(token, key), '{"status":0,"msg":"success"}');
    });
  });
}
