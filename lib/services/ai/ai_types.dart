// Shared value types across the AI services.

class TranscriptSegment {
  final double start; // seconds
  final double end;
  final String text;
  final String? speaker;

  const TranscriptSegment({
    required this.start,
    required this.end,
    required this.text,
    this.speaker,
  });

  Map<String, dynamic> toJson() =>
      {'start': start, 'end': end, 'text': text, 'speaker': speaker};

  factory TranscriptSegment.fromJson(Map<String, dynamic> j) =>
      TranscriptSegment(
        start: (j['start'] ?? 0).toDouble(),
        end: (j['end'] ?? 0).toDouble(),
        text: j['text'] ?? '',
        speaker: j['speaker'],
      );
}

class TranscriptResult {
  final String text;
  final List<TranscriptSegment> segments;
  final String? language;

  const TranscriptResult({
    required this.text,
    this.segments = const [],
    this.language,
  });
}

enum ChatRole { system, user, assistant }

class ChatMessage {
  final ChatRole role;
  final String content;
  const ChatMessage(this.role, this.content);
}

/// Thrown by remote AI clients with a human-readable reason.
class AiException implements Exception {
  final String message;
  final int? statusCode;
  AiException(this.message, {this.statusCode});
  @override
  String toString() =>
      'AiException($message${statusCode != null ? ', HTTP $statusCode' : ''})';
}
