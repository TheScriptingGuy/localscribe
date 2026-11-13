import '../../models/note_template.dart';
import '../ai/ai_types.dart';

/// Synthesizes the LLM prompt for a template locally.
///
/// Plaud never ships the raw server-side prompt — only the template `outline`.
/// So LocalScribe reconstructs an equivalent instruction prompt from that
/// outline plus the section headings, and feeds the transcript as the user turn.
class PromptBuilder {
  /// Builds the [system, user] message pair for generating a note.
  static List<ChatMessage> forNote({
    required NoteTemplate template,
    required String transcript,
    String? languageHint,
  }) {
    final b = StringBuffer();
    b.writeln(
        'You are a meticulous note-taker. Produce a well-structured note in '
        'Markdown from the transcript the user provides, following the '
        'template instructions below exactly.');
    b.writeln();
    b.writeln('TEMPLATE: ${template.name}');
    if (template.description.isNotEmpty) {
      b.writeln('PURPOSE: ${template.description}');
    }
    b.writeln();
    b.writeln('INSTRUCTIONS:');
    for (final line in template.outline) {
      b.writeln('- $line');
    }
    if (template.sections.isNotEmpty) {
      b.writeln();
      b.writeln('Use these section headings (## in Markdown) where applicable, '
          'omitting any that have no content:');
      for (final s in template.sections) {
        b.writeln('- $s');
      }
    }
    b.writeln();
    b.writeln('RULES:');
    b.writeln('- Stay strictly grounded in the transcript; never invent facts.');
    b.writeln('- Start the note with a single # title line: a short, specific '
        'title (at most 8 words) saying what this recording is about, '
        'not the name of the template.');
    if (languageHint != null && languageHint.isNotEmpty && languageHint != 'auto') {
      b.writeln('- Write the note in: $languageHint.');
    } else {
      b.writeln('- Write the note in the same language as the transcript.');
    }

    return [
      ChatMessage(ChatRole.system, b.toString().trim()),
      ChatMessage(ChatRole.user, 'TRANSCRIPT:\n\n$transcript'),
    ];
  }

  /// Builds messages for an Ask-AI chat turn grounded in a transcript.
  static List<ChatMessage> forChat({
    required String transcript,
    required List<ChatMessage> history,
    required String question,
  }) {
    final sys = ChatMessage(
      ChatRole.system,
      'You answer questions about a recording using ONLY the transcript below. '
      'If the answer is not in the transcript, say so. Be concise.\n\n'
      'TRANSCRIPT:\n$transcript',
    );
    return [sys, ...history, ChatMessage(ChatRole.user, question)];
  }
}
