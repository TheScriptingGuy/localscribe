import 'package:flutter_test/flutter_test.dart';
import 'package:localscribe/models/note_template.dart';
import 'package:localscribe/services/templates/template_repository.dart';

NoteTemplate t(String id, String name,
        {String description = '',
        String category = 'general',
        List<String> tags = const []}) =>
    NoteTemplate(
      id: id,
      name: name,
      description: description,
      outline: const ['x'],
      category: category,
      tags: tags,
    );

void main() {
  final repo = TemplateRepository.withTemplates([
    t('standup', 'Daily Stand-up',
        category: 'meeting', tags: ['scrum', 'agile'], description: 'Updates'),
    t('minutes', 'Meeting Minutes', category: 'meeting'),
    t('sales', 'Sales Call',
        category: 'call', description: 'Notes from a meeting with a prospect'),
    t('journal', 'Journal Entry', category: 'personal', tags: ['diary']),
  ]);

  List<String> ids(String q) => repo.search(q).map((e) => e.id).toList();

  test('empty query returns everything', () {
    expect(repo.search('  ').length, 4);
  });

  test('name matches rank above tag/category and description matches', () {
    // "Meeting Minutes" matches by name; "Daily Stand-up" via category;
    // "Sales Call" only via its description.
    expect(ids('meeting'), ['minutes', 'standup', 'sales']);
  });

  test('prefix of a word in the name matches', () {
    expect(ids('stand'), ['standup']);
    expect(ids('min'), ['minutes']);
  });

  test('tags are searchable', () {
    expect(ids('scrum'), ['standup']);
    expect(ids('diary'), ['journal']);
  });

  test('every word must match', () {
    expect(ids('meeting minutes'), ['minutes']);
    expect(ids('meeting banana'), isEmpty);
  });

  test('matching is case-insensitive', () {
    expect(ids('JOURNAL'), ['journal']);
  });
}
