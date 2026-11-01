import '../ai/ai_types.dart';

/// A chat/notes LLM backend. Implemented by [OpenAiChatGenerator] and
/// [AnthropicChatGenerator] (API URLs) and, in Phase 4, a llama.cpp on-device
/// generator. Used for both note generation and Ask-AI chat.
abstract class NoteGenerator {
  String get name;

  /// One-shot completion over [messages].
  Future<String> complete(List<ChatMessage> messages);

  /// Streaming completion — yields incremental text deltas (for chat typing).
  Stream<String> stream(List<ChatMessage> messages);
}
