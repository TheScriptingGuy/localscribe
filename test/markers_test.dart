import 'package:flutter_test/flutter_test.dart';
import 'package:localscribe/models/recording.dart';
import 'package:localscribe/services/ai/ai_types.dart';
import 'package:localscribe/services/export/transcript_export.dart';
import 'package:localscribe/services/notes/highlights.dart';
import 'package:localscribe/services/templates/prompt_builder.dart';
import 'package:localscribe/models/note_template.dart';

Recording recordingWithMarkers() => Recording(
      id: 'r1',
      title: 'Standup',
      createdAt: DateTime(2026, 11, 13, 9),
      audioFile: 'audio.m4a',
      durationMs: 120000,
      transcript: const TranscriptResult(
        text: 'a b c',
        segments: [
          TranscriptSegment(start: 5, end: 9, text: 'We pick vendor B.'),
          TranscriptSegment(start: 80, end: 85, text: 'Unrelated chatter.'),
        ],
      ),
      markers: const [
        RecordingMarker(
            id: 'm2', atMs: 70000, type: MarkerType.note, text: 'Ask legal'),
        RecordingMarker(id: 'm1', atMs: 6000, type: MarkerType.flag),
        RecordingMarker(
            id: 'm3',
            atMs: 90000,
            type: MarkerType.photo,
            photoFile: 'photos/m3.jpg'),
      ],
    );

void main() {
  test('markers survive a JSON round trip', () {
    final back = Recording.fromJson(recordingWithMarkers().toJson());
    expect(back.markers.length, 3);
    final photo = back.markers.firstWhere((m) => m.id == 'm3');
    expect(photo.type, MarkerType.photo);
    expect(photo.photoFile, 'photos/m3.jpg');
    expect(back.markers.firstWhere((m) => m.id == 'm2').text, 'Ask legal');
  });

  test('recordings without markers omit the key and load as empty', () {
    final rec = Recording(
        id: 'x', title: 't', createdAt: DateTime(2026), audioFile: 'a.m4a');
    expect(rec.toJson().containsKey('markers'), isFalse);
    expect(Recording.fromJson(rec.toJson()).markers, isEmpty);
  });

  test('highlight lines are sorted by time', () {
    expect(highlightLines(recordingWithMarkers()), [
      '[00:06] Highlight',
      '[01:10] Note: Ask legal',
      '[01:30] Photo',
    ]);
  });

  test('highlight context includes the transcript around each moment', () {
    final ctx = highlightsContext(recordingWithMarkers())!;
    expect(ctx, contains('[00:06] Highlight'));
    expect(ctx, contains('Around then: We pick vendor B.'));
    // The note at 70s is within 30s of the chatter at 80s, not of 5-9s.
    expect(ctx, contains('Ask legal'));
    expect(ctx, contains('Unrelated chatter.'));
    expect(highlightsContext(Recording(
        id: 'x', title: 't', createdAt: DateTime(2026), audioFile: 'a')),
        isNull);
  });

  test('transcript text export lists highlights at the end', () {
    final txt = transcriptToTxt(
        recordingWithMarkers(), const TranscriptExportOptions());
    expect(txt, contains('\nHighlights\n- [00:06] Highlight\n'));
  });

  test('note prompt carries the highlights and asks for a title', () {
    const template = NoteTemplate(
        id: 't', name: 'T', description: 'd', outline: ['Do things.']);
    final messages = PromptBuilder.forNote(
        template: template,
        transcript: 'x',
        highlights: highlightsContext(recordingWithMarkers()));
    final system = messages.first.content;
    expect(system, contains('HIGHLIGHTS'));
    expect(system, contains('## Highlights'));
    expect(system, contains('[01:10] Note: Ask legal'));
    expect(system, contains('at most 8 words'));

    final plain = PromptBuilder.forNote(template: template, transcript: 'x');
    expect(plain.first.content, isNot(contains('HIGHLIGHTS')));
  });
}
