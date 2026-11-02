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

/// Turns diarization [turns] into pieces to transcribe one by one: a turn
/// is joined to the previous one when it's the same voice less than
/// [maxGap] s later, a short turn inside another voice's turn ("mm-hm") is
/// dropped, and overlapping turns are cut halfway through the overlap.
/// Pieces get [pad] s of context where there's room. Speakers are numbered
/// S1, S2, … in order of first appearance.
List<SpeakerPiece> speakerPieces(List<SpeakerTurn> turns,
    {double maxGap = 1.5, double pad = 0.2}) {
  final sorted = [...turns]..sort((a, b) => a.start.compareTo(b.start));
  final merged = <SpeakerTurn>[];
  for (final t in sorted) {
    if (t.end <= t.start) continue;
    if (merged.isEmpty) {
      merged.add(t);
      continue;
    }
    final last = merged.last;
    if (t.end <= last.end && t.speaker != last.speaker) continue;
    if (t.speaker == last.speaker && t.start - last.end < maxGap) {
      merged[merged.length - 1] = SpeakerTurn(
          last.start, t.end > last.end ? t.end : last.end, last.speaker);
    } else {
      merged.add(t);
    }
  }

  final ids = <String, String>{};
  final pieces = <SpeakerPiece>[];
  for (var i = 0; i < merged.length; i++) {
    final t = merged[i];
    final prev = i > 0 ? merged[i - 1] : null;
    final next = i + 1 < merged.length ? merged[i + 1] : null;
    // Halfway to the neighbour, but at most `pad` beyond the turn.
    var start = t.start - pad;
    if (start < 0) start = 0;
    if (prev != null) {
      final mid = (prev.end + t.start) / 2;
      if (start < mid) start = mid;
    }
    var end = t.end + pad;
    if (next != null) {
      final mid = (t.end + next.start) / 2;
      if (end > mid) end = mid;
    }
    if (end <= start) continue;
    pieces.add(SpeakerPiece(start, end,
        ids.putIfAbsent(t.speaker, () => 'S${ids.length + 1}')));
  }
  return pieces;
}

/// Joins per-piece transcripts into one. Each segment takes its piece's
/// speaker; [TranscriptResult.language] lists the languages heard, most
/// spoken first ("en, de").
TranscriptResult joinPieces(List<SpeakerPiece> pieces,
    List<({String? language, List<TranscriptSegment> segments})> results) {
  final segments = <TranscriptSegment>[];
  final spoken = <String, double>{};
  for (var i = 0; i < pieces.length && i < results.length; i++) {
    final r = results[i];
    if (r.segments.isEmpty) continue;
    if (r.language != null) {
      spoken[r.language!] = (spoken[r.language!] ?? 0) + pieces[i].duration;
    }
    segments.addAll(r.segments.map((s) => s.withSpeaker(pieces[i].speaker)));
  }
  segments.sort((a, b) => a.start.compareTo(b.start));
  final languages = spoken.keys.toList()
    ..sort((a, b) => spoken[b]!.compareTo(spoken[a]!));
  return TranscriptResult(
    text: segments.map((s) => s.text).join(' '),
    segments: segments,
    language: languages.isEmpty ? null : languages.join(', '),
  );
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
