import 'dart:convert';

import '../../models/note_template.dart';
import '../ai/ai_types.dart';
import '../notes/note_generator.dart';

/// Turns a plain-language description ("notes for my weekly football club
/// committee call") into a template draft using the configured note AI.
class TemplateDrafter {
  static Future<NoteTemplate> draft({
    required NoteGenerator generator,
    required String description,
    required List<String> iconNames,
  }) async {
    final reply = await generator.complete(messages(description, iconNames));
    final t = parse(reply);
    if (t == null) {
      throw AiException(
          'The AI did not return a usable template. Try rephrasing the description.');
    }
    return t;
  }

  static List<ChatMessage> messages(String description, List<String> iconNames) {
    final system = StringBuffer()
      ..writeln('You design note templates for an app that turns voice '
          'recording transcripts into structured notes.')
      ..writeln('From the user\'s description, reply with ONLY one JSON object, '
          'no prose and no code fences, with exactly these keys:')
      ..writeln('- "name": short title, at most 4 words')
      ..writeln('- "description": one sentence saying what the note contains')
      ..writeln('- "category": one of ${templateCategoryIds.join(', ')}')
      ..writeln('- "icon": one of ${iconNames.join(', ')}')
      ..writeln('- "tags": 3 to 6 lowercase search words')
      ..writeln('- "outline": 4 to 7 instructions for the writer, each one '
          'sentence, telling it what to extract and how to present it '
          '(lists, tables, checkboxes)')
      ..writeln('- "sections": 2 to 6 section headings the note should use')
      ..writeln('The instructions must tell the writer to stay grounded in the '
          'transcript and not invent facts.');
    return [
      ChatMessage(ChatRole.system, system.toString().trim()),
      ChatMessage(ChatRole.user, description.trim()),
    ];
  }

  /// Parses the model's reply; null when it holds no usable template.
  static NoteTemplate? parse(String reply) {
    final start = reply.indexOf('{');
    final end = reply.lastIndexOf('}');
    if (start < 0 || end <= start) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(reply.substring(start, end + 1));
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final j = Map<String, dynamic>.from(decoded);

    List<String> strings(Object? v) => v is List
        ? v.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    final name = (j['name'] ?? '').toString().trim();
    final outline = strings(j['outline']);
    if (name.isEmpty || outline.isEmpty) return null;
    final category = (j['category'] ?? '').toString().toLowerCase().trim();
    return NoteTemplate(
      id: 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      description: (j['description'] ?? '').toString().trim(),
      outline: outline,
      sections: strings(j['sections']),
      tags: strings(j['tags']).map((e) => e.toLowerCase()).toList(),
      category:
          templateCategoryIds.contains(category) ? category : 'general',
      icon: (j['icon'] ?? 'description').toString().trim(),
      source: 'Drafted by AI from your description.',
      custom: true,
    );
  }
}
