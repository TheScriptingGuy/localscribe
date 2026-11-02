import '../../models/ai_config.dart';
import '../diarization/diarizer.dart';
import '../diarization/local_diarizer.dart';
import '../diarization/remote_diarizer.dart';
import '../models/llm_models.dart';
import '../models/speaker_models.dart';
import '../models/whisper_models.dart';
import '../notes/anthropic_generator.dart';
import '../notes/local_llm_generator.dart';
import '../notes/note_generator.dart';
import '../notes/openai_generator.dart';
import '../transcription/local_whisper.dart';
import '../transcription/remote_whisper.dart';
import '../transcription/transcriber.dart';
import 'ai_types.dart';

/// Builds live AI backends from configuration.
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

  static Diarizer diarizer(SpeakerConfig c,
      {required SpeakerModelManager models}) {
    if (c.onDevice) {
      if (!models.ready) {
        throw AiException('Speaker models are not downloaded yet. Open '
            'Options > Speaker recognition to download them.');
      }
      return LocalDiarizer(
        segmentationModel: models.fileOf(speakerSegmentationModel),
        embeddingModel: models.fileOf(speakerEmbeddingModel),
      );
    }
    if (c.remote.baseUrl.trim().isEmpty) {
      throw AiException('No speaker recognition API URL configured.');
    }
    return RemoteDiarizer(c.remote);
  }

  static NoteGenerator noteGenerator(NoteAiConfig c,
      {required LlmModelManager models}) {
    if (c.onDevice) {
      final model = models.byFile(c.localModel);
      if (model == null || !models.isInstalled(model)) {
        throw AiException('No on-device AI model downloaded yet. Open '
            'Options > Note AI to download one.');
      }
      return LocalLlmGenerator(model, models.fileOf(model));
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
