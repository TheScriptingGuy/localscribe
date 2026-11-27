import 'package:flutter_test/flutter_test.dart';
import 'package:localscribe/services/templates/template_drafter.dart';

void main() {
  test('parses a bare JSON reply', () {
    final t = TemplateDrafter.parse('''
{"name":"Club Call","description":"Committee notes","category":"work",
 "icon":"groups","tags":["Club","Committee"],
 "outline":["List decisions.","List actions."],"sections":["Decisions","Actions"]}''');
    expect(t, isNotNull);
    expect(t!.name, 'Club Call');
    expect(t.category, 'work');
    expect(t.icon, 'groups');
    expect(t.tags, ['club', 'committee']);
    expect(t.outline.length, 2);
    expect(t.sections, ['Decisions', 'Actions']);
    expect(t.custom, isTrue);
    expect(t.id, startsWith('custom_'));
  });

  test('tolerates prose and code fences around the JSON', () {
    final t = TemplateDrafter.parse(
        'Sure! Here you go:\n```json\n{"name":"A","outline":["Do it."]}\n```');
    expect(t, isNotNull);
    expect(t!.name, 'A');
  });

  test('unknown category falls back to general', () {
    final t = TemplateDrafter.parse(
        '{"name":"A","category":"nonsense","outline":["x"]}');
    expect(t!.category, 'general');
  });

  test('rejects replies without a name or instructions', () {
    expect(TemplateDrafter.parse('no json here'), isNull);
    expect(TemplateDrafter.parse('{"name":"A","outline":[]}'), isNull);
    expect(TemplateDrafter.parse('{"outline":["x"]}'), isNull);
    expect(TemplateDrafter.parse('{broken'), isNull);
  });
}
