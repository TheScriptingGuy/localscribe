/// A note template: metadata + an `outline` (the instruction bullets) + the
/// section headings it should produce. Mirrors the shape recovered from Plaud,
/// where the raw LLM prompt is server-side and only the outline ships.
class NoteTemplate {
  final String id;
  final String name;
  final String description;

  /// True when [outline] was recovered verbatim from Plaud; false = reconstructed.
  final bool verbatim;

  /// Provenance note (for transparency in the UI).
  final String source;

  /// Instruction bullets describing what the note should contain/do.
  final List<String> outline;

  /// Suggested section headings for the produced note.
  final List<String> sections;

  /// True for user-created templates (stored locally, editable).
  final bool custom;

  const NoteTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.outline,
    this.sections = const [],
    this.verbatim = false,
    this.source = '',
    this.custom = false,
  });

  factory NoteTemplate.fromJson(Map<String, dynamic> j, {bool custom = false}) =>
      NoteTemplate(
        id: j['id'] as String,
        name: j['name'] as String,
        description: (j['description'] ?? '') as String,
        verbatim: (j['verbatim'] ?? false) as bool,
        source: (j['source'] ?? '') as String,
        outline: (j['outline'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        sections: (j['sections'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        custom: custom,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'verbatim': verbatim,
        'source': source,
        'outline': outline,
        'sections': sections,
      };

  NoteTemplate copyWith({
    String? name,
    String? description,
    List<String>? outline,
    List<String>? sections,
  }) =>
      NoteTemplate(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        outline: outline ?? this.outline,
        sections: sections ?? this.sections,
        verbatim: verbatim,
        source: source,
        custom: custom,
      );
}
