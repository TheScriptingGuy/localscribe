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

  /// RSA/ECB/PKCS1Padding decrypt (mode used by the device handshake).
  static Uint8List rsaUnwrap(RSAPrivateKey priv, Uint8List wrapped) {
    final cipher = PKCS1Encoding(RSAEngine())
      ..init(false, PrivateKeyParameter<RSAPrivateKey>(priv));
    return _processBlocks(cipher, wrapped);
  }

  /// PEM public key derived from a private key (the `12 FE 05` enrollment write
  /// sends the *public* key of the same keypair whose private key we unwrap with).
  static String publicKeyPemFromPrivate(RSAPrivateKey priv) {
    // Recover the public exponent with the Carmichael function λ(n)=lcm(p-1,q-1),
    // because OpenSSL-derived keys set d = e⁻¹ mod λ(n). RSAPrivateKey's own
    // `publicExponent` uses φ(n), which returns a wrong huge value for such keys.
    final p1 = priv.p! - BigInt.one;
    final q1 = priv.q! - BigInt.one;
    final lambda = (p1 * q1) ~/ p1.gcd(q1);
    final e = priv.privateExponent!.modInverse(lambda);
    return CryptoUtils.encodeRSAPublicKeyToPem(RSAPublicKey(priv.modulus!, e));
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
