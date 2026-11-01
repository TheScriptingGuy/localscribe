import '../ai/ai_types.dart';
import 'diarizer.dart';

/// Puts speakers from [turns] on the transcript. Each segment (or, when the
/// transcript has word timings, each word) gets the voice that overlaps it
/// most; a segment whose words change voice is split there. Speakers are
/// renamed S1, S2, … in order of first appearance.
TranscriptResult assignSpeakers(TranscriptResult t, List<SpeakerTurn> turns) {
  final sorted = [...turns]..sort((a, b) => a.start.compareTo(b.start));
  if (sorted.isEmpty) {
    return _withSegments(t, [for (final s in t.segments) s.withSpeaker(null)]);
  }

  final out = <TranscriptSegment>[];
  for (final seg in t.segments) {
    if (seg.words.length < 2) {
      out.add(seg.withSpeaker(_speakerAt(sorted, seg.start, seg.end)));
      continue;
    }
    final labels = [
      for (final w in seg.words) _speakerAt(sorted, w.start, w.end),
    ];
    _smooth(seg.words, labels);
    if (labels.every((l) => l == labels.first)) {
      out.add(seg.withSpeaker(labels.first));
      continue;
    }
    // Split into runs of the same voice.
    var from = 0;
    for (var i = 1; i <= labels.length; i++) {
      if (i < labels.length && labels[i] == labels[from]) continue;
      final words = seg.words.sublist(from, i);
      out.add(TranscriptSegment(
        start: words.first.start,
        end: words.last.end,
        text: words.map((w) => w.text).join(' '),
        speaker: labels[from],
        words: words,
      ));
      from = i;
    }
  }

  // Number speakers by first appearance in the transcript.
  final ids = <String, String>{};
  final renamed = [
    for (final s in out)
      s.speaker == null
          ? s
          : s.withSpeaker(ids.putIfAbsent(s.speaker!, () => 'S${ids.length + 1}')),
  ];
  return _withSegments(t, renamed);
}

TranscriptResult _withSegments(TranscriptResult t, List<TranscriptSegment> s) =>
    TranscriptResult(text: t.text, segments: s, language: t.language);

/// The voice overlapping [start, end] most, or the nearest one when the
/// span falls in a gap between turns.
String? _speakerAt(List<SpeakerTurn> turns, double start, double end) {
  final overlap = <String, double>{};
  SpeakerTurn? nearest;
  var nearestGap = double.infinity;
  for (final t in turns) {
    if (t.start >= end) {
      final gap = t.start - end;
      if (gap < nearestGap) {
        nearestGap = gap;
        nearest = t;
      }
      break; // sorted by start: nothing later overlaps
    }
    final o = (t.end < end ? t.end : end) - (t.start > start ? t.start : start);
    if (o > 0) {
      overlap[t.speaker] = (overlap[t.speaker] ?? 0) + o;
    } else {
      final gap = start - t.end;
      if (gap < nearestGap) {
        nearestGap = gap;
        nearest = t;
      }
    }
  }
  if (overlap.isNotEmpty) {
    return overlap.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }
  return nearest?.speaker;
}

/// A single short word between two runs of the same voice is almost always
/// a timing wobble, not a real interjection: give it to its neighbours.
void _smooth(List<TranscriptWord> words, List<String?> labels) {
  for (var i = 1; i < labels.length - 1; i++) {
    if (labels[i] != labels[i - 1] &&
        labels[i - 1] == labels[i + 1] &&
        words[i].end - words[i].start < 0.6) {
      labels[i] = labels[i - 1];
    }
  }
}
