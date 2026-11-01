import '../../models/note_template.dart';
import '../ai/ai_types.dart';
import 'note_generator.dart';

/// Local equivalent of Plaud's AUTO-SELECT: ask the note AI which template
/// fits the transcript best, then generate with that template.
class AutoTemplatePicker {
  /// Only the opening of the transcript is needed to judge its type.
  static const _excerptChars = 6000;

  static Future<NoteTemplate> pick({
    required NoteGenerator generator,
    required List<NoteTemplate> templates,
    required String transcript,
  }) async {
    if (templates.isEmpty) {
      throw AiException('No templates available.');
    }
    final catalog = templates
        .map((t) => '- ${t.id}: ${t.name} — ${t.description}')
        .join('\n');
    final excerpt = transcript.length > _excerptChars
        ? transcript.substring(0, _excerptChars)
        : transcript;

    final reply = await generator.complete([
      ChatMessage(
        ChatRole.system,
        'Choose the single best note template for the transcript the user '
        'provides. Reply with ONLY the template id, nothing else.\n\n'
        'Templates:\n$catalog',
      ),
      ChatMessage(ChatRole.user, excerpt),
    ]);

    final answer = reply.trim().toLowerCase();
    for (final t in templates) {
      if (answer == t.id.toLowerCase()) return t;
    }
    // Models sometimes wrap the id in prose or quotes.
    for (final t in templates) {
      if (answer.contains(t.id.toLowerCase())) return t;
    }
    return templates.firstWhere((t) => t.id == 'general_summary',
        orElse: () => templates.first);
  }
}
