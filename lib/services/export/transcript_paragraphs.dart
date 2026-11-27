import '../../models/recording.dart';
import '../ai/ai_types.dart';

/// Groups segments into readable paragraphs: break when the speaker
/// changes, on a pause of 2 s+, or once a paragraph is long and the last
/// segment ends a sentence. Used by the transcript view and the exporters.
List<List<TranscriptSegment>> groupTranscriptParagraphs(
    Recording rec, List<TranscriptSegment> segments) {
  String? nameOf(TranscriptSegment s) =>
      s.speaker == null ? null : rec.speakerName(s.speaker!);
  final sentenceEnd = RegExp(r'[.!?…]["”’)]?$');
  final out = <List<TranscriptSegment>>[];
  var current = <TranscriptSegment>[];
  var chars = 0;
  for (final s in segments) {
    if (current.isNotEmpty) {
      final gap = s.start - current.last.end;
      final endsSentence = sentenceEnd.hasMatch(current.last.text.trim());
      if (nameOf(s) != nameOf(current.last) ||
          gap >= 2 ||
          (chars > 280 && endsSentence)) {
        out.add(current);
        current = [];
        chars = 0;
      }
    }
    current.add(s);
    chars += s.text.length;
  }
  if (current.isNotEmpty) out.add(current);
  return out;
}
