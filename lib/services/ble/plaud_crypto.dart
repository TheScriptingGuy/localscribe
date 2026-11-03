import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:basic_utils/basic_utils.dart';
import 'package:pointycastle/export.dart';

/// Crypto for the Plaud BLE session, reverse-engineered and verified against a
/// real capture (`findings/plaud-ble-phase5.md`):
///
///  * handshake: the device returns a 256-byte blob that is RSA/PKCS1-v1.5
///    encrypted to the *user's* RSA public key; unwrapping it with the user's
///    private key yields `[32B ChaCha20 key][12B nonce][12B aad][24B data]`;
///  * every subsequent BLE frame is ChaCha20-Poly1305 with that key, with the
///    nonce and aad reused for the whole session.
///
/// Nothing here is Plaud code; it is a clean-room reimplementation from the
/// observed wire format, used only with the user's own device and credentials.
class PlaudSessionKeys {
  final Uint8List key; // 32
  final Uint8List nonce; // 12
  final Uint8List aad; // 12
  final Uint8List firstData; // 24 (start of the handshake-carried payload)

  PlaudSessionKeys(this.key, this.nonce, this.aad, this.firstData);
}

class PlaudCrypto {
  /// Parse a PEM-encoded PKCS#8 (or PKCS#1) RSA private key.
  static RSAPrivateKey privateKeyFromPem(String pem) =>
      CryptoUtils.rsaPrivateKeyFromPem(pem);

  /// Parse a PEM public key (used to sanity-check an imported key pair).
  static RSAPublicKey publicKeyFromPem(String pem) =>
      CryptoUtils.rsaPublicKeyFromPem(pem);

  /// Generate a fresh RSA-2048 keypair. Returns (publicPem, privatePem).
  ///
  /// This is the "get our own e2ee key" path: the recorder accepts any user
  /// public key via the `12 FE 05` write (see findings/plaud-fresh-enroll-verified.md),
  /// so LocalScribe can mint its own key instead of importing the Plaud one.
  static ({String publicPem, String privatePem}) generateKeyPair() {
    final pair = CryptoUtils.generateRSAKeyPair(keySize: 2048);
    final pub = pair.publicKey as RSAPublicKey;
    final priv = pair.privateKey as RSAPrivateKey;
    return (
      publicPem: CryptoUtils.encodeRSAPublicKeyToPem(pub),
      privatePem: CryptoUtils.encodeRSAPrivateKeyToPem(priv),
    );
  }

  /// PEM public key derived from a private key (the `12 FE 05` enrollment write
  /// sends the *public* key of the same keypair whose private key we unwrap with).
  static String publicKeyPemFromPrivate(RSAPrivateKey priv) =>
      CryptoUtils.encodeRSAPublicKeyToPem(
          RSAPublicKey(priv.modulus!, priv.exponent ?? BigInt.from(65537)));

  /// RSA/ECB/PKCS1Padding decrypt (mode used by the device handshake).
  static Uint8List rsaUnwrap(RSAPrivateKey priv, Uint8List wrapped) {
    final cipher = PKCS1Encoding(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(priv));
    return _processBlocks(cipher, wrapped);
  }

  /// RSA PKCS#1 v1.5 encrypt (the app's `RSA_ECB_PKCS1Padding`). Used to wrap
  /// the login password with the server public key from `/config/security`.
  static Uint8List rsaEncryptPkcs1(RSAPublicKey pub, Uint8List plain) {
    final cipher = PKCS1Encoding(RSAEngine())
      ..init(true, PublicKeyParameter<RSAPublicKey>(pub));
    return _processBlocks(cipher, plain);
  }

  /// Parse a server public key that may be PEM or bare base64 (SPKI DER).
  static RSAPublicKey publicKeyFromAny(String key) {
    final s = key.trim();
    if (s.contains('BEGIN')) {
      return CryptoUtils.rsaPublicKeyFromPem(s);
    }
    final b64 = s.replaceAll(RegExp(r'\s'), '');
    final pem = '-----BEGIN PUBLIC KEY-----\n$b64\n-----END PUBLIC KEY-----';
    return CryptoUtils.rsaPublicKeyFromPem(pem);
  }

  /// RSA-encrypt a password with the server public key, base64-encoded — the
  /// `passwordEncrypted` field of `/login/login-email`.
  static String encryptPasswordWithPublicKey(String publicKey, String password) {
    final pub = publicKeyFromAny(publicKey);
    final enc = rsaEncryptPkcs1(pub, Uint8List.fromList(utf8.encode(password)));
    return base64Encode(enc);
  }

  /// Seal a login password with the server's secp256k1 public key (ECIES), the
  /// scheme Plaud's web/mobile clients use on `POST /auth/access-token`
  /// (`password_encrypted=true`). Ported from `jaisonerick/plaud-cli` and
  /// verified against its eciesjs reference vector + a live login.
  ///
  /// Envelope (base64): ephemeralPub.uncompressed(65) || nonce(16) || tag(16)
  /// || ciphertext. Key = HKDF-SHA256(ephPub || sharedPoint, salt=nil, info="",
  /// 32) where sharedPoint = ephPriv * serverPub (full point, uncompressed).
  /// Payload = AES-256-GCM(16-byte nonce) over `{"pass":…,"time":…}`.
  static String encryptPasswordSecp256k1(String pubKeyHex, String password) {
    final domain = ECCurve_secp256k1();
    final serverPoint = _decodeServerPoint(domain, pubKeyHex);

    // Generate the ephemeral key directly (avoids pointycastle's ECKeyGenerator,
    // whose default SecureRandom() constructor isn't registered).
    final rng = Random.secure();
    BigInt d;
    do {
      final buf = Uint8List(32);
      for (var i = 0; i < buf.length; i++) {
        buf[i] = rng.nextInt(256);
      }
      d = _bytesToBigInt(buf);
    } while (d == BigInt.zero || d >= domain.n);
    final ephPub = ECPublicKey(domain.G * d, domain);
    final ephPriv = ECPrivateKey(d, domain);

    final ephBytes = ephPub.Q!.getEncoded(false); // 65 bytes uncompressed
    final agreement = ECDHBasicAgreement()..init(ephPriv);
    final sharedX = agreement.calculateAgreement(ECPublicKey(serverPoint, domain));
    final sharedBytes = _pointBytes(sharedX, _secp256k1Y(sharedX));

    final ikm = Uint8List.fromList([...ephBytes, ...sharedBytes]);
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(ikm, 32, null, Uint8List(0)));
    final key = Uint8List(32);
    hkdf.deriveKey(null, 0, key, 0);

    final payload = utf8.encode(jsonEncode(<String, dynamic>{
      'pass': password,
      'time': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    }));
    final nonce = _randomBytes(16);

    final gcm = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    final sealed = _processAead(gcm, payload); // ciphertext || tag
    final ciphertext = Uint8List.sublistView(sealed, 0, sealed.length - 16);
    final tag = Uint8List.sublistView(sealed, sealed.length - 16);

    final envelope = Uint8List(65 + 16 + 16 + ciphertext.length)
      ..setRange(0, 65, ephBytes)
      ..setRange(65, 81, nonce)
      ..setRange(81, 97, tag)
      ..setRange(97, 97 + ciphertext.length, ciphertext);
    return base64Encode(envelope);
  }

  /// Inverse of [encryptPasswordSecp256k1] — used by tests and for verification
  /// against the reference vector. `privKeyHex` is the server's secp256k1
  /// private key (hex); `envelopeB64` is the base64 envelope.
  static String decryptPasswordSecp256k1(String privKeyHex, String envelopeB64) {
    final domain = ECCurve_secp256k1();
    final raw = base64Decode(envelopeB64);
    final ephBytes = Uint8List.sublistView(raw, 0, 65);
    final nonce = Uint8List.sublistView(raw, 65, 81);
    final tag = Uint8List.sublistView(raw, 81, 97);
    final ct = Uint8List.sublistView(raw, 97);

    final ephPoint = domain.curve.decodePoint(ephBytes)!;
    final priv = ECPrivateKey(BigInt.parse(privKeyHex, radix: 16), domain);
    final agreement = ECDHBasicAgreement()..init(priv);
    final sharedX = agreement.calculateAgreement(ECPublicKey(ephPoint, domain));
    final sharedBytes = _pointBytes(sharedX, _secp256k1Y(sharedX));

    final ikm = Uint8List.fromList([...ephBytes, ...sharedBytes]);
    final hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(ikm, 32, null, Uint8List(0)));
    final key = Uint8List(32);
    hkdf.deriveKey(null, 0, key, 0);

    final ctTag = Uint8List.fromList([...ct, ...tag]);
    final gcm = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
    return utf8.decode(_processAead(gcm, ctTag));
  }

  /// Standard Fernet decrypt (AES-128-CBC + HMAC-SHA256). `token` is the raw
  /// base64url token; `keyBase64Url` is the 32-byte key (sign[0:16] / enc[16:32]).
  static String fernetDecrypt(String token, String keyBase64Url) {
    final key = base64Url.decode(base64Url.normalize(keyBase64Url));
    final raw = base64Url.decode(base64Url.normalize(token));
    final signKey = Uint8List.sublistView(key, 0, 16);
    final encKey = Uint8List.sublistView(key, 16, 32);
    final data = Uint8List.sublistView(raw, 0, raw.length - 32);
    final mac = Uint8List.sublistView(raw, raw.length - 32);

    final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(signKey));
    final calc = Uint8List(32);
    hmac.update(data, 0, data.length);
    hmac.doFinal(calc, 0);
    if (!_constantTimeEquals(calc, mac)) {
      throw StateError('Fernet HMAC mismatch');
    }

    final iv = Uint8List.sublistView(data, 9, 25);
    final ct = Uint8List.sublistView(data, 25);
    return utf8.decode(_pkcs7Unpad(_cbcDecrypt(encKey, iv, ct)));
  }

  /// Decode the server's secp256k1 public key (compressed or uncompressed hex).
  /// Compressed keys are decompressed manually because pointycastle's
  /// `decompressPoint` yields a negated `y` for these keys, which breaks the
  /// ECDH shared-point y used in the HKDF material.
  static ECPoint _decodeServerPoint(ECDomainParameters domain, String pubKeyHex) {
    final enc = _hexDecode(pubKeyHex);
    if (enc.length == 33 && (enc[0] == 0x02 || enc[0] == 0x03)) {
      final x = _bytesToBigInt(enc.sublist(1));
      final y = _secp256k1Y(x);
      final yOdd = (enc[0] & 1) == 1;
      final p = _secp256k1P();
      final yCorrect = (y.isOdd == yOdd) ? y : p - y;
      return domain.curve.createPoint(x, yCorrect, false);
    }
    final p = domain.curve.decodePoint(enc);
    if (p == null) {
      throw ArgumentError('Invalid secp256k1 server public key');
    }
    return p;
  }

  static BigInt _secp256k1P() => BigInt.parse(
      'fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f',
      radix: 16);

  static BigInt _secp256k1Y(BigInt x) {
    final p = _secp256k1P();
    final y2 = (x.modPow(BigInt.from(3), p) + BigInt.from(7)) % p;
    return y2.modPow((p + BigInt.one) >> 2, p); // p ≡ 3 (mod 4)
  }

  /// Encode an uncompressed secp256k1 point (0x04 || x || y).
  static Uint8List _pointBytes(BigInt x, BigInt y) {
    final out = Uint8List(65);
    out[0] = 0x04;
    _bigIntInto(out, 1, x);
    _bigIntInto(out, 33, y);
    return out;
  }

  static void _bigIntInto(Uint8List buf, int off, BigInt v) {
    var tmp = v;
    for (var i = 31; i >= 0; i--) {
      buf[off + i] = (tmp & BigInt.from(0xff)).toInt();
      tmp = tmp >> 8;
    }
  }

  static BigInt _bytesToBigInt(Uint8List b) {
    var v = BigInt.zero;
    for (final x in b) {
      v = (v << 8) | BigInt.from(x);
    }
    return v;
  }

  static Uint8List _randomBytes(int n) {
    final rng = Random.secure();
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = rng.nextInt(256);
    }
    return b;
  }

  static Uint8List _cbcDecrypt(Uint8List key, Uint8List iv, Uint8List ct) {
    final cbc = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), iv));
    final out = Uint8List(ct.length);
    for (var off = 0; off < ct.length; off += cbc.blockSize) {
      cbc.processBlock(ct, off, out, off);
    }
    return out;
  }

  static Uint8List _pkcs7Unpad(Uint8List data) {
    final pad = data[data.length - 1];
    return Uint8List.sublistView(data, 0, data.length - pad);
  }

  static Uint8List _hexDecode(String s) {
    final clean = s.replaceAll(RegExp(r'\s'), '');
    final out = Uint8List(clean.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// Unwrap the 80-byte handshake payload into session keys.
  static PlaudSessionKeys sessionKeysFrom(RSAPrivateKey priv, Uint8List wrapped) {
    final pt = rsaUnwrap(priv, wrapped);
    if (pt.length < 44) {
      throw StateError('handshake unwrap too short: ${pt.length}');
    }
    return PlaudSessionKeys(
      Uint8List.sublistView(pt, 0, 32),
      Uint8List.sublistView(pt, 32, 44),
      Uint8List.sublistView(pt, 44, pt.length >= 56 ? 56 : pt.length),
      pt.length > 56 ? Uint8List.sublistView(pt, 56) : Uint8List(0),
    );
  }

  /// ChaCha20-Poly1305 decrypt of a received frame (ct||tag) -> plaintext.
  /// Throws on tag mismatch.
  static Uint8List frameDecrypt(PlaudSessionKeys k, List<int> frame) =>
      _chacha(false, k, Uint8List.fromList(frame));

  /// ChaCha20-Poly1305 encrypt of a plaintext frame -> ct||tag to write.
  static Uint8List frameEncrypt(PlaudSessionKeys k, List<int> plain) =>
      _chacha(true, k, Uint8List.fromList(plain));

  static Uint8List _chacha(bool forEncrypt, PlaudSessionKeys k, Uint8List data) {
    final aead = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305())
      ..init(
        forEncrypt,
        AEADParameters(KeyParameter(k.key), 128, k.nonce, k.aad),
      );
    return _processAead(aead, data);
  }

  static Uint8List _processBlocks(AsymmetricBlockCipher cipher, Uint8List input) {
    final bs = cipher.inputBlockSize;
    final out = <int>[];
    for (var off = 0; off < input.length;) {
      final chunk = (off + bs < input.length) ? bs : input.length - off;
      out.addAll(cipher.process(Uint8List.sublistView(input, off, off + chunk)));
      off += chunk;
    }
    return Uint8List.fromList(out);
  }

  static Uint8List _processAead(AEADCipher aead, Uint8List input) {
    final out = Uint8List(aead.getOutputSize(input.length));
    var len = aead.processBytes(input, 0, input.length, out, 0);
    len += aead.doFinal(out, len);
    return Uint8List.sublistView(out, 0, len);
  }
}
