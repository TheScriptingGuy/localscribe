// Shared value types across the AI services.

/// A word with timings (on-device transcripts only), used to split a segment
/// where the speaker changes.
class TranscriptWord {
  final double start;
  final double end;
  final String text;

  const TranscriptWord(this.start, this.end, this.text);

  /// Stored compactly as `[start, end, "text"]`.
  List<Object> toJson() => [start, end, text];

  factory TranscriptWord.fromJson(List j) => TranscriptWord(
      (j[0] as num).toDouble(), (j[1] as num).toDouble(), j[2].toString());
}

class TranscriptSegment {
  final double start; // seconds
  final double end;
  final String text;

  /// Speaker id ("S1", "S2", …) after speaker recognition, else null.
  final String? speaker;
  final List<TranscriptWord> words;

  const TranscriptSegment({
    required this.start,
    required this.end,
    required this.text,
    this.speaker,
    this.words = const [],
  });

  TranscriptSegment withSpeaker(String? speaker) => TranscriptSegment(
      start: start, end: end, text: text, speaker: speaker, words: words);

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'text': text,
        'speaker': speaker,
        if (words.isNotEmpty) 'words': words.map((w) => w.toJson()).toList(),
      };

  factory TranscriptSegment.fromJson(Map<String, dynamic> j) =>
      TranscriptSegment(
        start: (j['start'] ?? 0).toDouble(),
        end: (j['end'] ?? 0).toDouble(),
        text: j['text'] ?? '',
        speaker: j['speaker'],
        words: ((j['words'] as List?) ?? const [])
            .map((w) => TranscriptWord.fromJson(w as List))
            .toList(),
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

  bool get hasSpeakers => segments.any((s) => s.speaker != null);

  Map<String, dynamic> toJson() => {
        'text': text,
        'segments': segments.map((s) => s.toJson()).toList(),
        'language': language,
      };

  factory TranscriptResult.fromJson(Map<String, dynamic> j) => TranscriptResult(
        text: j['text'] ?? '',
        segments: ((j['segments'] as List?) ?? const [])
            .map((e) => TranscriptSegment.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        language: j['language'],
      );
}

enum ChatRole { system, user, assistant }

class ChatMessage {
  final ChatRole role;
  final String content;
  const ChatMessage(this.role, this.content);

  Map<String, dynamic> toJson() => {'role': role.name, 'content': content};

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
        ChatRole.values.firstWhere((r) => r.name == j['role'],
            orElse: () => ChatRole.user),
        j['content'] ?? '',
      );
}

/// Thrown by remote AI clients with a human-readable reason.
class AiException implements Exception {
  final String message;
  final int? statusCode;

  /// The user stopped the job; not an error worth showing.
  final bool cancelled;
  AiException(this.message, {this.statusCode, this.cancelled = false});
  @override
  String toString() =>
      'AiException($message${statusCode != null ? ', HTTP $statusCode' : ''})';
}
