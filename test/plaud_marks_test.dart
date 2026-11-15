import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localscribe/services/ble/plaud_container.dart';
import 'package:localscribe/services/ble/plaud_crypto.dart';
import 'package:localscribe/services/ble/plaud_import.dart';
import 'package:localscribe/models/recording.dart';
import 'package:pointycastle/export.dart';

/// A throwaway RSA-2048 key pair (the container's wrapped key is 256 bytes).
AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _keyPair() {
  final rnd = FortunaRandom()
    ..seed(KeyParameter(Uint8List.fromList(
        List.generate(32, (_) => Random.secure().nextInt(256)))));
  final gen = RSAKeyGenerator()
    ..init(ParametersWithRandom(
        RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64), rnd));
  final pair = gen.generateKeyPair();
  return AsymmetricKeyPair(
      pair.publicKey as RSAPublicKey, pair.privateKey as RSAPrivateKey);
}

/// Builds a PLAUD.AI container whose units decrypt to [tocs][i] followed by
/// a recognisable payload byte (i & 0xff), then [padding] zero units.
Uint8List _container(RSAPublicKey pub, List<int> tocs, {int padding = 2}) {
  final key = Uint8List.fromList(List.generate(32, (i) => i * 7 + 1));
  final nonce = Uint8List.fromList(List.generate(12, (i) => 0xa0 + i));
  final wrapped = PlaudCrypto.rsaEncryptPkcs1(pub, key);
  expect(wrapped.length, 256);

  final engine = ChaCha7539Engine()
    ..init(true, ParametersWithIV(KeyParameter(key), nonce));
  final ks = Uint8List(80);
  engine.processBytes(Uint8List(80), 0, 80, ks, 0);

  final out = BytesBuilder();
  final header = Uint8List(0x200);
  header.setRange(0, 8, 'PLAUD.AI'.codeUnits);
  header.setRange(0x84, 0x84 + 12, nonce);
  ByteData.sublistView(header).setUint32(0x90, 80, Endian.little);
  header.setRange(0x100, 0x200, wrapped);
  out.add(header);
  for (var i = 0; i < tocs.length; i++) {
    final plain = Uint8List(80)
      ..[0] = tocs[i]
      ..fillRange(1, 80, i & 0xff);
    out.add(List.generate(80, (j) => plain[j] ^ ks[j]));
  }
  // Padding: units whose decrypted first byte is not a TOC (raw zeros, XORed).
  for (var i = 0; i < padding; i++) {
    out.add(List.generate(80, (j) => (j == 0 ? 0x00 : 0) ^ ks[j]));
  }
  return out.toBytes();
}

void main() {
  late AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> keys;
  setUpAll(() => keys = _keyPair());

  group('PlaudContainer.decode', () {
    test('a recorder highlight unit (0xb9) no longer ends the audio', () {
      final tocs = List.filled(10, 0xb8)..[4] = 0xb9..[7] = 0xb9;
      final audio = PlaudContainer(_container(keys.publicKey, tocs))
          .decode(keys.privateKey);
      expect(audio.packets.length, 10);
      expect(audio.durationMs, 200);
      expect(audio.markMs, [80, 140]);
      // The mark unit is restored to the normal TOC, payload untouched.
      expect(audio.packets[4][0], 0xb8);
      expect(audio.packets[4][1], 4);
    });

    test('plain recordings have no marks and stop at the padding', () {
      final audio = PlaudContainer(_container(keys.publicKey, List.filled(5, 0xb8)))
          .decode(keys.privateKey);
      expect(audio.packets.length, 5);
      expect(audio.markMs, isEmpty);
    });
  });

  group('PlaudLiveScanner', () {
    test('finds marks as 80-byte frames stream in, out of order and twice', () {
      final tocs = List.filled(60, 0xb8)..[25] = 0xb9;
      final bytes = _container(keys.publicKey, tocs, padding: 0);
      final seen = <int>[];
      final s = PlaudLiveScanner(keys.privateKey, onMark: seen.add);

      final frames = <int>[for (var o = 0; o < bytes.length; o += 80) o];
      // Swap two frames and repeat one, like a lossy BLE stream.
      final a = frames[3];
      frames[3] = frames[4];
      frames[4] = a;
      frames.insert(10, frames[9]);
      for (final o in frames) {
        final end = min(o + 80, bytes.length);
        s.add(o, Uint8List.sublistView(bytes, o, end));
      }
      expect(seen, [500]);
      expect(s.marks, [500]);
      expect(s.contiguousBytes, bytes.length);
      expect(s.durationMs, 60 * 20);
      expect(s.bytes, bytes);
    });

    test('finds marks past the gap the live stream leaves after the header', () {
      // Like the recorder: header + first bytes, then live from the current
      // size; the gap is only filled by the re-read after stop.
      final tocs = List.filled(40, 0xb8)..[30] = 0xb9;
      final bytes = _container(keys.publicKey, tocs, padding: 0);
      final s = PlaudLiveScanner(keys.privateKey);
      const firstBlock = 640, liveFrom = 0x200 + 20 * 80;
      for (var o = 0; o < firstBlock; o += 80) {
        s.add(o, Uint8List.sublistView(bytes, o, o + 80));
      }
      for (var o = liveFrom; o < bytes.length; o += 80) {
        s.add(o, Uint8List.sublistView(bytes, o, o + 80));
      }
      expect(s.marks, [600]);
      expect(s.contiguousBytes, firstBlock);
      expect(s.durationMs, 40 * 20); // furthest audio received
      // The re-read after stop fills the gap.
      s.add(0, Uint8List.sublistView(bytes, 0, liveFrom));
      expect(s.contiguousBytes, bytes.length);
      expect(s.bytes, bytes);
      expect(s.marks, [600]);
    });
  });

  group('recorderMarkers', () {
    test('turns marks into flags and skips ones already flagged', () {
      final existing = [
        const RecordingMarker(id: 'a', atMs: 10200, type: MarkerType.flag),
        const RecordingMarker(id: 'b', atMs: 30000, type: MarkerType.note, text: 'x'),
      ];
      final out = recorderMarkers([10000, 30000, 46440], existing: existing);
      expect(out.map((m) => m.atMs), [30000, 46440]);
      expect(out.every((m) => m.type == MarkerType.flag), isTrue);
    });
  });

  test('recordings are titled by their start time, like the Plaud app', () {
    final t = DateTime.fromMillisecondsSinceEpoch(0x6afa1216 * 1000);
    String two(int v) => v.toString().padLeft(2, '0');
    expect(plaudTitle(0x6afa1216),
        '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}');
    expect(plaudTitle(1234), 'Plaud Note 4d2');
  });

  test('file ids are start times in unix seconds', () {
    expect(fileIdTime(0x6af9e31a)!.toUtc().year, 2026);
    expect(fileIdTime(1234), isNull);
  });
}
