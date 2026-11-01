import '../services/ai/ai_types.dart';

/// Where a recording's audio came from.
enum RecordingSource { mic, import, plaud }

/// A note generated from a recording's transcript with one template.
class GeneratedNote {
  final String id;
  final String templateId;
  final String templateName;
  final String content;
  final DateTime createdAt;

  /// True when the template was chosen by the AI ("Auto"), mirroring Plaud's
  /// AUTO-SELECT vs. manual template distinction.
  final bool auto;

  const GeneratedNote({
    required this.id,
    required this.templateId,
    required this.templateName,
    required this.content,
    required this.createdAt,
    this.auto = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'templateId': templateId,
        'templateName': templateName,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
        'auto': auto,
      };

  factory GeneratedNote.fromJson(Map<String, dynamic> j) => GeneratedNote(
        id: j['id'],
        templateId: j['templateId'] ?? '',
        templateName: j['templateName'] ?? '',
        content: j['content'] ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
        auto: j['auto'] ?? false,
      );
}

/// One entry in the local library: audio file + transcript + notes + chat.
/// Persisted as `recordings/<id>/meta.json` next to the audio file.
class Recording {
  final String id;
  String title;
  final DateTime createdAt;

  /// Audio file name inside the recording's folder (e.g. `audio.m4a`).
  final String audioFile;
  int durationMs;
  final RecordingSource source;
  TranscriptResult? transcript;
  final List<GeneratedNote> notes;
  final List<ChatMessage> chat;

  Recording({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.audioFile,
    this.durationMs = 0,
    this.source = RecordingSource.mic,
    this.transcript,
    List<GeneratedNote>? notes,
    List<ChatMessage>? chat,
  })  : notes = notes ?? [],
        chat = chat ?? [];

  Duration get duration => Duration(milliseconds: durationMs);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt.toIso8601String(),
        'audioFile': audioFile,
        'durationMs': durationMs,
        'source': source.name,
        'transcript': transcript?.toJson(),
        'notes': notes.map((n) => n.toJson()).toList(),
        'chat': chat.map((m) => m.toJson()).toList(),
      };

  factory Recording.fromJson(Map<String, dynamic> j) => Recording(
        id: j['id'],
        title: j['title'] ?? 'Recording',
        createdAt: DateTime.tryParse(j['createdAt'] ?? '') ?? DateTime.now(),
        audioFile: j['audioFile'] ?? 'audio.m4a',
        durationMs: j['durationMs'] ?? 0,
        source: RecordingSource.values.firstWhere((s) => s.name == j['source'],
            orElse: () => RecordingSource.mic),
        transcript: j['transcript'] == null
            ? null
            : TranscriptResult.fromJson(
                Map<String, dynamic>.from(j['transcript'])),
        notes: ((j['notes'] as List?) ?? const [])
            .map((e) => GeneratedNote.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        chat: ((j['chat'] as List?) ?? const [])
            .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}
