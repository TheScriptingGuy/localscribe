import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localscribe_native/localscribe_native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ble/plaud_container.dart';

/// Feeds a [LiveCaptioner] from a recording on the Plaud recorder: every
/// second it takes the Opus audio that has streamed in since last time,
/// decodes it on the phone (MediaCodec, 16 kHz mono PCM) and hands it on.
///
/// The Plaud app does its live captions in the cloud; here nothing leaves
/// the phone. The live stream skips from the first block to the current
/// position (the gap is fetched after stop), so it starts at the live edge.
class RecorderCaptionFeed {
  /// The recording's bytes as they arrive; null before it has started.
  final PlaudLiveScanner? Function() audio;
  final void Function(Uint8List pcm) onPcm;
  RecorderCaptionFeed({required this.audio, required this.onPcm});

  /// Decode at least this much at a time (100 units = 2 s): fewer, larger
  /// chunks mean fewer decoder restarts at chunk edges.
  static const minPackets = 100;

  /// Never decode more than this in one go (30 s).
  static const maxPackets = 1500;

  Timer? _timer;
  int? _next;
  var _busy = false;
  var _stopped = false;

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
  }

  Future<void> _tick() async {
    if (_busy || _stopped) return;
    final s = audio();
    if (s == null) return;
    final batch = nextBatch(s, _next);
    if (batch == null) return;
    final (start, packets) = batch;
    if (packets.isEmpty) {
      _next = start; // already past the skipped piece
      return;
    }
    _next = start + packets.length;
    _busy = true;
    try {
      final pcm = await decodeOpusPackets(packets);
      _debugChunk(start, packets, pcm); // TEMP: captions diagnosis
      if (!_stopped && pcm.isNotEmpty) onPcm(pcm);
    } catch (e) {
      debugPrint('captions: decode failed: $e');
    } finally {
      _busy = false;
    }
  }

  // TEMP: captions diagnosis. Logs each chunk's level and appends the PCM
  // and the Ogg file to the app's external files dir for adb pull.
  Future<void> _debugChunk(
      int start, List<Uint8List> packets, Uint8List pcm) async {
    var sum = 0.0;
    final s16 = pcm.buffer.asInt16List(pcm.offsetInBytes, pcm.length ~/ 2);
    for (final v in s16) {
      sum += v * v;
    }
    final rms = s16.isEmpty ? 0 : math.sqrt(sum / s16.length);
    debugPrint('captions: units $start+${packets.length} -> '
        '${s16.length} samples, rms ${rms.toStringAsFixed(1)}');
    try {
      final dir = await getExternalStorageDirectory();
      if (dir == null) return;
      await File(p.join(dir.path, 'captions_debug.pcm'))
          .writeAsBytes(pcm, mode: FileMode.append);
      if (start < 2000) {
        await File(p.join(dir.path, 'captions_chunk_$start.opus'))
            .writeAsBytes(PlaudContainer.oggOpusOf(packets));
      }
    } catch (_) {}
  }

  /// What to decode next, from unit [next] (null: nothing taken yet).
  /// Returns (first unit, packets); empty packets means "skip to after
  /// them" (a stray piece before a gap), null means "wait for more".
  @visibleForTesting
  static (int, List<Uint8List>)? nextBatch(PlaudLiveScanner s, int? next) {
    if (next == null) {
      // Start at the live edge, not at the first block before the gap.
      final end = s.unitsEnd;
      var k = s.nextReceivedUnit(0);
      while (k < end) {
        final run = s.packetsFrom(k).length;
        if (k + run >= end) break; // reaches the furthest audio: live edge
        k = s.nextReceivedUnit(k + (run == 0 ? 1 : run));
      }
      next = k;
    }
    final start = s.nextReceivedUnit(next);
    final packets = s.packetsFrom(start, max: maxPackets);
    if (packets.length >= minPackets) return (start, packets);
    final reachesEdge = start + packets.length >= s.unitsEnd;
    if (reachesEdge) return null; // wait for more audio
    // A stray piece before a gap (or a unit that is not audio): skip it.
    final skip = packets.isEmpty ? 1 : packets.length;
    return (start + skip, const []);
  }
}

/// Decodes bare 20 ms Opus packets from the recorder to 16 kHz mono 16-bit
/// PCM, in a background isolate.
Future<Uint8List> decodeOpusPackets(List<Uint8List> packets) async {
  final tmp = await getTemporaryDirectory();
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final ogg = p.join(tmp.path, 'captions-$stamp.opus');
  final pcm = p.join(tmp.path, 'captions-$stamp.pcm');
  await File(ogg).writeAsBytes(PlaudContainer.oggOpusOf(packets), flush: true);
  final job = NativeJob();
  final address = job.address;
  try {
    await Isolate.run(() => LocalScribeNative.decodeToPcmSync(
        audioPath: ogg, pcmPath: pcm, jobAddress: address));
    return await File(pcm).readAsBytes();
  } finally {
    job.free();
    for (final f in [ogg, pcm]) {
      try {
        await File(f).delete();
      } catch (_) {}
    }
  }
}
