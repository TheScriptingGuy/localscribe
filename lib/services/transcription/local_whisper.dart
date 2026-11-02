import 'dart:io';
import 'dart:math';

import 'package:localscribe_native/localscribe_native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../ai/ai_types.dart';
import '../diarization/speaker_merge.dart';
import '../models/whisper_models.dart';
import 'transcriber.dart';

/// Transcribes on the phone with whisper.cpp. Audio never leaves the device.
class LocalWhisperTranscriber implements Transcriber {
  final WhisperModel model;
  final File modelFile;

  LocalWhisperTranscriber(this.model, this.modelFile);

  @override
  String get name => 'whisper.cpp (${model.label})';

  @override
  Future<TranscriptResult> transcribe(
    File audio, {
    String? language,
    void Function(double progress)? onProgress,
    CancelSignal? cancel,
  }) async {
    final result = await _run(audio,
        language: (language == null || language.isEmpty) ? 'auto' : language,
        onProgress: onProgress,
        cancel: cancel);
    final segments = _segments(result['segments']);
    return TranscriptResult(
      text: segments.map((s) => s.text).join(' '),
      segments: segments,
      language: result['language'] as String?,
    );
  }

  @override
  Future<TranscriptResult> transcribePieces(
    File audio,
    List<SpeakerPiece> pieces, {
    void Function(double progress)? onProgress,
    CancelSignal? cancel,
  }) async {
    if (pieces.isEmpty) return const TranscriptResult(text: '');
    final result = await _run(audio,
        language: 'auto',
        ranges: [for (final x in pieces) (x.start, x.end, x.speakerIndex)],
        onProgress: onProgress,
        cancel: cancel);
    final out = ((result['pieces'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map((m) => (
              language: m['language'] as String?,
              segments: _segments(m['segments']),
            ))
        .toList();
    return joinPieces(pieces, out);
  }

  Future<Map<String, dynamic>> _run(
    File audio, {
    required String language,
    List<(double, double, int)>? ranges,
    void Function(double progress)? onProgress,
    CancelSignal? cancel,
  }) async {
    final unsupported = LocalScribeNative.unsupportedReason;
    if (unsupported != null) throw AiException(unsupported);
    if (!await audio.exists()) {
      throw AiException('Audio file not found: ${audio.path}');
    }

    final tmp = await getTemporaryDirectory();
    final scratch = p.join(
        tmp.path, 'decode-${DateTime.now().microsecondsSinceEpoch}.pcm');
    final job = LocalScribeNative.transcribe(
      modelPath: modelFile.path,
      audioPath: audio.path,
      scratchPath: scratch,
      language: language,
      // More threads than big cores slows whisper down on big.LITTLE phones.
      threads: min(4, Platform.numberOfProcessors),
      ranges: ranges,
      onProgress: onProgress,
    );
    cancel?.onCancel(job.cancel);

    try {
      return await job.result;
    } on WhisperException catch (e) {
      throw AiException(e.cancelled ? 'Cancelled' : e.message,
          cancelled: e.cancelled);
    }
  }

  static List<TranscriptSegment> _segments(Object? json) =>
      ((json as List?) ?? const [])
          .map((e) => TranscriptSegment.fromJson(Map<String, dynamic>.from(e)))
          .map((s) => TranscriptSegment(
              start: s.start, end: s.end, text: s.text.trim(), words: s.words))
          .where((s) => s.text.isNotEmpty)
          .toList();
}
