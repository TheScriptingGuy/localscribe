import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:localscribe_native/localscribe_native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
// The public process() copies the samples into a second native buffer; going
// through the bindings lets a long recording live in memory only once.
// ignore: implementation_imports
import 'package:sherpa_onnx/src/sherpa_onnx_bindings.dart';

import '../ai/ai_types.dart';
import '../transcription/transcriber.dart';
import 'diarizer.dart';

/// Speaker recognition on the phone: MediaCodec decode (localscribe_native),
/// then sherpa-onnx (pyannote segmentation + WeSpeaker embeddings +
/// clustering). Audio never leaves the device.
class LocalDiarizer implements Diarizer {
  final File segmentationModel;
  final File embeddingModel;

  LocalDiarizer(
      {required this.segmentationModel, required this.embeddingModel});

  @override
  String get name => 'sherpa-onnx';

  @override
  Future<List<SpeakerTurn>> diarize(
    File audio, {
    int numSpeakers = 0,
    void Function(double progress)? onProgress,
    CancelSignal? cancel,
  }) async {
    if (!await audio.exists()) {
      throw AiException('Audio file not found: ${audio.path}');
    }
    final tmp = await getTemporaryDirectory();
    final pcm = p.join(
        tmp.path, 'speakers-${DateTime.now().microsecondsSinceEpoch}.pcm');
    final job = NativeJob();
    // sherpa-onnx can't be interrupted once it runs; cancelling stops the
    // decode, and otherwise the result is discarded.
    cancel?.onCancel(job.cancel);
    final timer = onProgress == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 400),
            (_) => onProgress(job.progress));
    try {
      final rows = await _runInIsolate(
        segmentationModel.path,
        embeddingModel.path,
        audio.path,
        pcm,
        numSpeakers,
        min(4, Platform.numberOfProcessors),
        job.address,
      );
      if (cancel?.isCancelled ?? false) {
        throw AiException('Cancelled', cancelled: true);
      }
      return [for (final r in rows) SpeakerTurn(r[0], r[1], 'v${r[2].toInt()}')];
    } on WhisperException catch (e) {
      throw AiException(e.cancelled ? 'Cancelled' : e.message,
          cancelled: e.cancelled);
    } finally {
      timer?.cancel();
      job.free();
      final f = File(pcm);
      if (await f.exists()) await f.delete();
    }
  }
}

// Top-level so the isolate closure captures only sendable values.
Future<List<List<double>>> _runInIsolate(String seg, String emb, String audio,
        String pcm, int numSpeakers, int threads, int job) =>
    Isolate.run(
        () => _diarizeSync(seg, emb, audio, pcm, numSpeakers, threads, job));

/// Runs in a background isolate. Returns `[start, end, speaker]` rows.
List<List<double>> _diarizeSync(String seg, String emb, String audio,
    String pcm, int numSpeakers, int threads, int job) {
  // Progress: decode 0–0.1 (native), loading 0.12, embeddings 0.15–1.0.
  final samples = LocalScribeNative.decodeToPcmSync(
      audioPath: audio, pcmPath: pcm, jobAddress: job);
  if (NativeJob.isCancelled(job)) throw WhisperException('cancelled');
  if (samples < 16000) return const [];
  NativeJob.setProgress(job, 0.12);

  sherpa.initBindings();
  final sd = sherpa.OfflineSpeakerDiarization(
    sherpa.OfflineSpeakerDiarizationConfig(
      segmentation: sherpa.OfflineSpeakerSegmentationModelConfig(
        pyannote: sherpa.OfflineSpeakerSegmentationPyannoteModelConfig(model: seg),
        numThreads: threads,
        debug: false,
      ),
      embedding: sherpa.SpeakerEmbeddingExtractorConfig(
          model: emb, numThreads: threads, debug: false),
      clustering: sherpa.FastClusteringConfig(
          numClusters: numSpeakers > 0 ? numSpeakers : -1, threshold: 0.5),
      minDurationOn: 0.3,
      minDurationOff: 0.5,
    ),
  );

  final buf = calloc<Float>(samples);
  final callback = NativeCallable<
          SherpaOnnxOfflineSpeakerDiarizationProgressCallbackNoArgNative>.isolateLocal(
      (int done, int total) {
    if (total > 0) NativeJob.setProgress(job, 0.15 + 0.85 * done / total);
    return 0;
  }, exceptionalReturn: 0);
  try {
    _readPcm(pcm, buf.asTypedList(samples));
    final r = SherpaOnnxBindings
        .sherpaOnnxOfflineSpeakerDiarizationProcessWithCallbackNoArg!(
            sd.ptr, buf, samples, callback.nativeFunction);
    if (r == nullptr) throw WhisperException('Speaker recognition failed.');
    try {
      final n = SherpaOnnxBindings
          .sherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments!(r);
      final segs = SherpaOnnxBindings
          .sherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime!(r);
      if (segs == nullptr) return const [];
      try {
        return [
          for (var i = 0; i < n; i++)
            [
              (segs + i).ref.start,
              (segs + i).ref.end,
              (segs + i).ref.speaker.toDouble(),
            ],
        ];
      } finally {
        SherpaOnnxBindings.sherpaOnnxOfflineSpeakerDiarizationDestroySegment!(
            segs);
      }
    } finally {
      SherpaOnnxBindings.sherpaOnnxOfflineSpeakerDiarizationDestroyResult!(r);
    }
  } finally {
    callback.close();
    calloc.free(buf);
    sd.free();
  }
}

/// Reads 16-bit PCM into [out] as floats, a block at a time.
void _readPcm(String path, Float32List out) {
  final f = File(path).openSync();
  try {
    const block = 1 << 20; // bytes
    var pos = 0;
    while (pos < out.length) {
      final bytes = f.readSync(min(block, (out.length - pos) * 2));
      if (bytes.isEmpty) break;
      final pcm = bytes.buffer.asInt16List(bytes.offsetInBytes, bytes.length ~/ 2);
      for (var i = 0; i < pcm.length; i++) {
        out[pos + i] = pcm[i] / 32768.0;
      }
      pos += pcm.length;
    }
  } finally {
    f.closeSync();
  }
}
