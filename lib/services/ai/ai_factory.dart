import '../../models/ai_config.dart';
import '../notes/anthropic_generator.dart';
import '../notes/note_generator.dart';
import '../notes/openai_generator.dart';
import '../transcription/remote_whisper.dart';
import '../transcription/transcriber.dart';
import 'ai_types.dart';

/// Builds live AI backends from configuration. On-device backends arrive in
/// Phases 3-4; until then selecting "on-device" throws a clear message.
class AiFactory {
  static Transcriber transcriber(TranscriptionConfig c) {
    if (c.onDevice) {
      throw AiException(
          'On-device transcription (whisper.cpp) is not available yet — '
          'configure a Whisper API URL in Options, or wait for Phase 3.');
    }
    if (c.remote.baseUrl.trim().isEmpty) {
      throw AiException('No transcription API URL configured.');
    }
    return RemoteWhisperTranscriber(c.remote);
  }

  static NoteGenerator noteGenerator(NoteAiConfig c) {
    if (c.onDevice) {
      throw AiException(
          'On-device notes (llama.cpp) are not available yet — configure a '
          'chat API URL in Options, or wait for Phase 4.');
    }
    if (c.remote.baseUrl.trim().isEmpty) {
      throw AiException('No note AI API URL configured.');
    }
    return switch (c.remote.flavor) {
      ChatApiFlavor.openai => OpenAiChatGenerator(c.remote),
      ChatApiFlavor.anthropic => AnthropicChatGenerator(c.remote),
    };
  }
}
