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

  /// One of [templateCategoryIds]; groups the template in the browser.
  final String category;

  /// Key into the icon table in `ui/template_style.dart`.
  final String icon;

  /// Extra search terms ("standup", "scrum", ...).
  final List<String> tags;

  /// A short sample of what the finished note looks like (preview text).
  final String example;

  const NoteTemplate({
    required this.id,
    required this.name,
    required this.description,
    required this.outline,
    this.sections = const [],
    this.verbatim = false,
    this.source = '',
    this.custom = false,
    this.category = 'general',
    this.icon = 'description',
    this.tags = const [],
    this.example = '',
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
        category: (j['category'] ?? 'general') as String,
        icon: (j['icon'] ?? 'description') as String,
        tags: (j['tags'] as List? ?? const []).map((e) => e.toString()).toList(),
        example: (j['example'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'verbatim': verbatim,
        'source': source,
        'outline': outline,
        'sections': sections,
        'category': category,
        'icon': icon,
        'tags': tags,
        'example': example,
      };

  NoteTemplate copyWith({
    String? name,
    String? description,
    List<String>? outline,
    List<String>? sections,
    String? category,
    String? icon,
    List<String>? tags,
    String? example,
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
        category: category ?? this.category,
        icon: icon ?? this.icon,
        tags: tags ?? this.tags,
        example: example ?? this.example,
      );
}

/// Template categories, in display order.
const templateCategoryIds = [
  'general',
  'meeting',
  'call',
  'education',
  'interview',
  'personal',
  'work',
];
