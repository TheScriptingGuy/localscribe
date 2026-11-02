import '../ai/ai_types.dart';
import '../transcription/transcriber.dart' show CancelSignal;

export '../transcription/transcriber.dart' show CancelSignal;

/// A chat/notes LLM backend: [OpenAiChatGenerator] and
/// [AnthropicChatGenerator] (API URLs) or [LocalLlmGenerator] (llama.cpp on
/// the phone). Used for both note generation and Ask-AI chat.
///
/// [onProgress] (0.0–1.0) and [cancel] matter for the on-device model, which
/// can take minutes on a long transcript; the API clients may ignore them.
abstract class NoteGenerator {
  String get name;

  /// One-shot completion over [messages].
  Future<String> complete(List<ChatMessage> messages,
      {void Function(double progress)? onProgress, CancelSignal? cancel});

  /// Streaming completion — yields incremental text deltas (for chat typing).
  Stream<String> stream(List<ChatMessage> messages,
      {void Function(double progress)? onProgress, CancelSignal? cancel});
}
