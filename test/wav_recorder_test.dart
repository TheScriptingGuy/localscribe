import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localscribe/services/audio/wav_recorder.dart';

Uint8List pcm(List<int> samples) {
  final d = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    d.setInt16(i * 2, samples[i], Endian.little);
  }
  return d.buffer.asUint8List();
}

void main() {
  test('16 kHz 16-bit mono is 32 bytes per millisecond', () {
    expect(WavRecorder.bytesPerMs, 32);
  });

  group('level', () {
    test('silence and empty chunks are 0', () {
      expect(WavRecorder.level(Uint8List(0)), 0);
      expect(WavRecorder.level(pcm(List.filled(64, 0))), 0);
    });

    test('full scale is 1', () {
      expect(WavRecorder.level(pcm(List.filled(64, 32767))), closeTo(1, 0.001));
    });

    test('half amplitude is about -6 dBFS', () {
      // 20*log10(0.5) = -6.02 dB -> (60 - 6.02) / 60 = 0.90
      expect(WavRecorder.level(pcm(List.filled(64, 16384))), closeTo(0.9, 0.01));
    });

    test('quiet noise stays low', () {
      expect(WavRecorder.level(pcm(List.filled(64, 33))), lessThan(0.2));
    });
  });
}
