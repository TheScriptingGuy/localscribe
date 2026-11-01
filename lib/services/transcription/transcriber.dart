import 'dart:io';
import '../ai/ai_types.dart';

/// A transcription backend. Implemented by [RemoteWhisperTranscriber] (API URL)
/// and, in Phase 3, a whisper.cpp on-device transcriber.
abstract class Transcriber {
  /// Human label for UI/logging.
  String get name;

  /// Transcribe [audio]; [language] is an optional ISO code (null = auto).
  Future<TranscriptResult> transcribe(File audio, {String? language});
}
