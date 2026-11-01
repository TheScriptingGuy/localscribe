import '../../models/ai_config.dart';
import '../models/whisper_models.dart';
import '../notes/anthropic_generator.dart';
import '../notes/note_generator.dart';
import '../notes/openai_generator.dart';
import '../transcription/local_whisper.dart';
import '../transcription/remote_whisper.dart';
import '../transcription/transcriber.dart';
import 'ai_types.dart';

/// Builds live AI backends from configuration. On-device notes arrive in
/// Phase 4; until then selecting it throws a clear message.
class AiFactory {
  static Transcriber transcriber(TranscriptionConfig c,
      {required WhisperModelManager models}) {
    if (c.onDevice) {
      final model = whisperModelByFile(c.localModel);
      if (model == null || !models.isInstalled(model)) {
        throw AiException('No on-device model downloaded yet. Open Options '
            '> Transcription AI > Models to download one.');
      }
      return LocalWhisperTranscriber(model, models.fileOf(model));
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
