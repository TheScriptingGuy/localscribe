import 'dart:io';
import '../ai/ai_types.dart';
import '../diarization/diarizer.dart';

export '../diarization/diarizer.dart' show SpeakerPiece;

/// Lets the caller stop a running transcription.
class CancelSignal {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in _listeners) {
      l();
    }
  }

  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }
}

/// A transcription backend: [RemoteWhisperTranscriber] (API URL) or
/// [LocalWhisperTranscriber] (whisper.cpp on the phone).
abstract class Transcriber {
  /// Human label for UI/logging.
  String get name;

  /// Transcribe [audio]; [language] is an optional ISO code (null = auto).
  /// [onProgress] receives 0.0–1.0 where the backend can measure it.
  Future<TranscriptResult> transcribe(
    File audio, {
    String? language,
    void Function(double progress)? onProgress,
    CancelSignal? cancel,
  });

  /// Transcribes each of [pieces] (speaker turns) on its own so each detects
  /// its own language. Segments come back labelled with the piece's speaker.
  Future<TranscriptResult> transcribePieces(
    File audio,
    List<SpeakerPiece> pieces, {
    void Function(double progress)? onProgress,
    CancelSignal? cancel,
  });
}
