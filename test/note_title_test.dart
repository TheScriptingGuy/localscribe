import 'package:flutter_test/flutter_test.dart';
import 'package:localscribe/services/notes/note_title.dart';

void main() {
  group('isAutoTitle', () {
    test('recognises generated names', () {
      for (final t in [
        'Recording 13 Nov',
        'Plaud Note 6af71e15',
        '2026-11-13 15:17:06',
        '2026-11-13T15.17',
        'audio_12',
        '',
      ]) {
        expect(isAutoTitle(t), isTrue, reason: t);
      }
    });

    test('keeps names a person chose', () {
      for (final t in ['Budget review', 'Notes for Anna', 'Plaudits for the team']) {
        expect(isAutoTitle(t), isFalse, reason: t);
      }
    });
  });

  group('titleFromNote', () {
    test('takes the first heading and strips formatting', () {
      expect(titleFromNote('Intro\n# **Q3 budget** review:\n\n## Summary'),
          'Q3 budget review');
    });

    test('ignores lower-level headings and missing headings', () {
      expect(titleFromNote('## Only a section\ntext'), isNull);
      expect(titleFromNote('no heading'), isNull);
    });

    test('caps very long titles', () {
      final t = titleFromNote('# ${'word ' * 40}')!;
      expect(t.length, lessThanOrEqualTo(80));
      expect(t, endsWith('…'));
    });
  });
}
