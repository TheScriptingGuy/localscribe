import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

/// Records the phone mic as 16 kHz mono 16-bit PCM and writes it to a WAV
/// file, while also publishing the raw PCM so live captions and the level
/// meter can use the same audio. Pausing releases the microphone.
class WavRecorder {
  static const sampleRate = 16000;
  static const bytesPerMs = sampleRate * 2 ~/ 1000; // 32

  static const _config = RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: sampleRate,
    numChannels: 1,
  );

  final AudioRecorder _recorder;
  WavRecorder(this._recorder);

  RandomAccessFile? _file;
  String? _path;
  StreamSubscription<Uint8List>? _sub;
  int _bytes = 0;
  int? _leftover;
  final _pcm = StreamController<Uint8List>.broadcast();

  /// Each chunk of captured PCM, in order (even length).
  Stream<Uint8List> get pcm => _pcm.stream;

  /// Audio recorded so far, excluding paused time.
  int get durationMs => _bytes ~/ bytesPerMs;

  Future<bool> hasPermission() => _recorder.hasPermission();

  Future<void> start(String path) async {
    _path = path;
    _bytes = 0;
    _leftover = null;
    final file = await File(path).open(mode: FileMode.write);
    _file = file;
    file.writeFromSync(_header(0));
    await _listen();
  }

  Future<void> _listen() async {
    final stream = await _recorder.startStream(_config);
    _sub = stream.listen(_onData);
  }

  void _onData(Uint8List data) {
    final file = _file;
    if (file == null || data.isEmpty) return;
    var chunk = data;
    // Keep samples whole when a chunk ends mid-sample.
    if (_leftover != null) {
      final joined = Uint8List(chunk.length + 1)
        ..[0] = _leftover!
        ..setRange(1, chunk.length + 1, chunk);
      chunk = joined;
      _leftover = null;
    }
    if (chunk.length.isOdd) {
      _leftover = chunk.last;
      chunk = Uint8List.sublistView(chunk, 0, chunk.length - 1);
    }
    if (chunk.isEmpty) return;
    file.writeFromSync(chunk);
    _bytes += chunk.length;
    if (!_pcm.isClosed) _pcm.add(chunk);
  }

  Future<void> pause() async {
    await _sub?.cancel();
    _sub = null;
    await _recorder.stop();
  }

  Future<void> resume() => _listen();

  /// Finishes the file and returns its path.
  Future<String> stop() async {
    await _sub?.cancel();
    _sub = null;
    await _recorder.stop();
    final file = _file;
    _file = null;
    if (file != null) {
      file.setPositionSync(0);
      file.writeFromSync(_header(_bytes));
      await file.close();
    }
    await _pcm.close();
    return _path!;
  }

  /// Stops and deletes the file.
  Future<void> cancel() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder.stop();
    } catch (_) {}
    final file = _file;
    _file = null;
    await file?.close();
    if (_path != null) {
      try {
        await File(_path!).delete();
      } catch (_) {}
    }
    await _pcm.close();
  }

  /// Input level 0..1 of a PCM chunk (-60..0 dBFS), for the waveform.
  static double level(Uint8List chunk) {
    final n = chunk.length ~/ 2;
    if (n == 0) return 0;
    final data = ByteData.sublistView(chunk);
    var sum = 0.0;
    var count = 0;
    for (var i = 0; i < n; i += 4) {
      final v = data.getInt16(i * 2, Endian.little) / 32768.0;
      sum += v * v;
      count++;
    }
    final rms = math.sqrt(sum / count);
    if (rms <= 0) return 0;
    final db = 20 * math.log(rms) / math.ln10;
    return ((db + 60) / 60).clamp(0.0, 1.0).toDouble();
  }

  static Uint8List _header(int dataBytes) {
    final h = ByteData(44)
      ..setUint32(0, 0x52494646) // "RIFF"
      ..setUint32(4, 36 + dataBytes, Endian.little)
      ..setUint32(8, 0x57415645) // "WAVE"
      ..setUint32(12, 0x666d7420) // "fmt "
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, sampleRate, Endian.little)
      ..setUint32(28, sampleRate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little)
      ..setUint32(36, 0x64617461) // "data"
      ..setUint32(40, dataBytes, Endian.little);
    return h.buffer.asUint8List();
  }
}
