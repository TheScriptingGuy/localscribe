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

enum MarkerType { flag, photo, note }

/// A moment the user marked while recording: a highlight flag, a photo or a
/// typed note, at [atMs] from the start of the audio.
class RecordingMarker {
  final String id;
  final int atMs;
  final MarkerType type;
  final String? text;

  /// Path of the photo relative to the recording's folder, e.g. `photos/<id>.jpg`.
  final String? photoFile;

  const RecordingMarker({
    required this.id,
    required this.atMs,
    required this.type,
    this.text,
    this.photoFile,
  });

  RecordingMarker withPhotoFile(String? file) => RecordingMarker(
      id: id, atMs: atMs, type: type, text: text, photoFile: file);

  Map<String, dynamic> toJson() => {
        'id': id,
        'atMs': atMs,
        'type': type.name,
        if (text != null) 'text': text,
        if (photoFile != null) 'photoFile': photoFile,
      };

  factory RecordingMarker.fromJson(Map<String, dynamic> j) => RecordingMarker(
        id: j['id'] as String,
        atMs: (j['atMs'] as num?)?.toInt() ?? 0,
        type: MarkerType.values.firstWhere((t) => t.name == j['type'],
            orElse: () => MarkerType.flag),
        text: j['text'] as String?,
        photoFile: j['photoFile'] as String?,
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

  /// Highlights, photos and notes marked while recording, by time.
  final List<RecordingMarker> markers;

  /// Names given to recognised speakers, by speaker id ("S1" -> "Anna").
  final Map<String, String> speakerNames;

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
    List<RecordingMarker>? markers,
    Map<String, String>? speakerNames,
  })  : notes = notes ?? [],
        chat = chat ?? [],
        markers = markers ?? [],
        speakerNames = speakerNames ?? {};

  Duration get duration => Duration(milliseconds: durationMs);

  /// Display name for a speaker id: the given name, else "Speaker N".
  String speakerName(String id) =>
      speakerNames[id] ?? 'Speaker ${id.replaceFirst('S', '')}';

  /// The transcript as fed to note generation and Ask-AI: "Name: text" lines
  /// when speakers are known, plain text otherwise.
  String get transcriptForAi {
    final t = transcript;
    if (t == null) return '';
    if (!t.hasSpeakers) return t.text;
    final b = StringBuffer();
    String? current;
    for (final s in t.segments) {
      final name = s.speaker == null ? null : speakerName(s.speaker!);
      if (name != current || b.isEmpty) {
        if (b.isNotEmpty) b.write('\n\n');
        b.write(name == null ? s.text : '$name: ${s.text}');
        current = name;
      } else {
        b.write(' ${s.text}');
      }
    }
    return b.toString();
  }

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
        if (markers.isNotEmpty) 'markers': markers.map((m) => m.toJson()).toList(),
        if (speakerNames.isNotEmpty) 'speakerNames': speakerNames,
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
        markers: ((j['markers'] as List?) ?? const [])
            .map((e) => RecordingMarker.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        speakerNames: Map<String, String>.from(j['speakerNames'] ?? const {}),
      );
}
