import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:localscribe_native/localscribe_native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/recording.dart';
import '../library/recording_store.dart';
import 'export_types.dart';

enum AudioFormat { original, wav }

const _mimeByExt = {
  'm4a': 'audio/mp4',
  'mp4': 'audio/mp4',
  'aac': 'audio/aac',
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'opus': 'audio/ogg',
  'ogg': 'audio/ogg',
  'flac': 'audio/flac',
};

/// The audio exactly as stored, or decoded to a 16 kHz mono WAV.
Future<ExportFile> exportAudio(
    RecordingStore store, Recording rec, AudioFormat format) async {
  final file = store.audioOf(rec);
  if (format == AudioFormat.original) {
    final ext = p.extension(rec.audioFile).replaceFirst('.', '').toLowerCase();
    return ExportFile('${exportBaseName(rec)}.$ext', await file.readAsBytes(),
        _mimeByExt[ext] ?? 'application/octet-stream');
  }

  final tmp = await getTemporaryDirectory();
  final pcmPath =
      p.join(tmp.path, 'export_${DateTime.now().microsecondsSinceEpoch}.pcm');
  final job = NativeJob();
  final jobAddress = job.address;
  final audioPath = file.path;
  try {
    await Isolate.run(() => LocalScribeNative.decodeToPcmSync(
        audioPath: audioPath, pcmPath: pcmPath, jobAddress: jobAddress));
    final pcm = await File(pcmPath).readAsBytes();
    return ExportFile(
        '${exportBaseName(rec)}.wav', wavFromPcm16(pcm), 'audio/wav');
  } finally {
    job.free();
    try {
      await File(pcmPath).delete();
    } catch (_) {}
  }
}

/// Wraps 16-bit little-endian mono [pcm] in a 44-byte WAV header.
Uint8List wavFromPcm16(Uint8List pcm, {int sampleRate = 16000}) {
  final header = ByteData(44)
    ..setUint32(0, 0x52494646) // "RIFF"
    ..setUint32(4, 36 + pcm.length, Endian.little)
    ..setUint32(8, 0x57415645) // "WAVE"
    ..setUint32(12, 0x666d7420) // "fmt "
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little)
    ..setUint32(36, 0x64617461) // "data"
    ..setUint32(40, pcm.length, Endian.little);
  return (BytesBuilder(copy: false)
        ..add(header.buffer.asUint8List())
        ..add(pcm))
      .takeBytes();
}
