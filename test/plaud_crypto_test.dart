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

    test('parses PKCS#8 (BEGIN PRIVATE KEY) and derives public exponent 65537',
        () {
      // Fresh throwaway RSA-2048 PKCS#8 key (not the user's).
      const pkcs8 = '''-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDUDmHpffhWOavx
tyeUasxwgYdnLrbT1qUfAWZ7PXWc6ADr/qeG264tycl79xZWAnvVXtndwyKw4ZKy
ggugNmUZCRDchYGhOmcBiNHtWE9QH0Nrr6BkKQsw2s1Pay6C7fqRx0Ul/EOvaSrg
etlbSGQPY9Xa4f4rLR0mR4sbQs075jFSypGZmys76n9z2F3QW+VtpiCV1RtdEnmf
wa6r640Jv3H9Eyl6ObqVDWZ5Gjf1DFOghcK4Qv5PXUmKohpmMUsxCah3x3EPcdPD
CzHYAT7uGraPGJL4G5gaI/XD4ttXoT0taOzHn6kmOQcERHtnvPlRac4mdpMmT7f8
QUa7K+5zAgMBAAECggEAQBMKdc147MDnWhWwEXIFzRbubXiZiL/qS8iWCTYEZEFc
CfL79s1JP4+h4GHEL3/3n/zVkuMEB/NY6rRNw/67pIlvPVrf1PI7LqUDXZaZ/Ik9
y3uZWLpoJb5vXAh0WN6EoGjYVYZ4gzehW4vzQlhI17egZk90B+LNVIQ4naedMPQr
xSntCEbMXolBr+L/pdTQ0Rd+ZrdIHVY53rrTDEubMLD5MbvwM6Q8n0YxGaxxJgI9
F09hivU74GoBwELJU83MS+/klu9fNejSsjSfMLgfefpw6L7rqzb9FTCzhADCQ9QR
NiRVl/9Keshb/RPGmT0vyi5pzKH/cZ6PqBMnvrVCoQKBgQD1N9sTVsxKlowzcInp
Gzus46kP398iHDgidRb5qcCmh5GssulNrIr5XigfiUP7iZ3264erWUNrpijD/Kc5
kI8BQ4ZUKuqM0xoXduWQCbVhzVHP4C68Xf8tw8mnJULYUNfokmN65lxHxDzgaZ8O
Tzxs60nN3zRFu3i1tQaJ++ADEwKBgQDdYUJr7vLVfC3fnNU9PlwjfnWinBIh3TIT
7jOezbzKDQa2Ejej7C+tzATB8FcqdrmRSH21ZqDn4NCj9P5ayvrcgUlhdnvkt4Rc
RuGe+GQm/tMqyKRE6Xck8h71w+KuyesxqM0zM80k8erKul+sNVcOhiTp8fpToKhc
wdZ6qa5zIQKBgQDIfX2Z5zqqtUI2AIpRU9nLtmuQthqKmgXvbkp1oCwKPAeH6tPD
lRIfZrNpbWJu84p6ywGmwBnWlwj3jMfw0deKUfovMNOKhkLr8mMpDDcHmsaMLqAn
lLbBZTWneliX4ilVVvMNFfFXIAQh+1l3aqNd7lXug9MKPIgqELMi+BOkjwKBgEeX
jm1tRua3U/Z+t48ovY9U9CH0KwD8kZdUbykqC6Wj9MmotomydfDUi61UVjwLTROo
x86ENAEI+TAsqJ0gC2SIAv0b3hEnMAzPd2N7nJfnzM6HOGh4v+kYy95azNINxpu2
pTWryOnruix5fTspvM+bnhByCqxExm3I2d2tRhdBAoGBAM9kXZm5I5+iDOAdIBZW
pYyHmaTNHE+uM2chrP7KXCsvT2s+W9yfSpggOUVml3v6bFdEgyGTAYaAixbTeWtX
v2gy0vXUkw5Gy5Bjcxq+f3vkqdGfk1JKCIuK4n7oQqS76QyGUNnRBsvD+G2I70F0
lD8rPC6LXPIridfz5UDxFiQy
-----END PRIVATE KEY-----''';

      final priv = PlaudCrypto.privateKeyFromPem(pkcs8);
      final pubPem = PlaudCrypto.publicKeyPemFromPrivate(priv);
      final pub = PlaudCrypto.publicKeyFromPem(pubPem);
      expect(pub.publicExponent, BigInt.from(65537));

      // The derived public key must actually encrypt for the private key.
      const msg = 'hello pkcs8';
      final ct = PlaudCrypto.rsaEncryptPkcs1(
          pub, Uint8List.fromList(utf8.encode(msg)));
      expect(utf8.decode(PlaudCrypto.rsaUnwrap(priv, ct)), msg);
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
          'gAAAAABq6fqWZQngKcm6YxdN3ha1pWGkHObPa_cWBuKNDFyVrGkmgx9xfwuspkk81glxqAPL3jg81y8F4ndme6p1gqxZ-J0XFL2Us7LtHQXn1DWQZave-rw=';
      expect(PlaudCrypto.fernetDecrypt(token, key), '{"status":0,"msg":"success"}');
    });
  });
}
