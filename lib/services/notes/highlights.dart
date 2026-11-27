import '../../models/recording.dart';
import '../ai/ai_types.dart';
import '../../ui/format.dart';

/// Marked moments plus what was being said around them, for the note prompt.
/// Null when the recording has no markers.
String? highlightsContext(Recording rec, {double windowSeconds = 30}) {
  if (rec.markers.isEmpty) return null;
  final segments = rec.transcript?.segments ?? const [];
  final markers = [...rec.markers]..sort((a, b) => a.atMs.compareTo(b.atMs));
  final b = StringBuffer();
  for (final m in markers) {
    final at = m.atMs / 1000;
    final kind = switch (m.type) {
      MarkerType.flag => 'Highlight',
      MarkerType.photo => 'Photo taken',
      MarkerType.note => 'Note',
    };
    b.write('- [${formatDuration(Duration(milliseconds: m.atMs))}] $kind');
    if (m.text != null && m.text!.trim().isNotEmpty) {
      b.write(': ${m.text!.trim()}');
    }
    b.writeln();
    final around = segments
        .where((s) => s.end >= at - windowSeconds && s.start <= at + windowSeconds)
        .map((s) => s.text.trim())
        .where((t) => t.isNotEmpty)
        .join(' ');
    if (around.isNotEmpty) {
      final clipped = around.length > 500 ? '${around.substring(0, 500)}…' : around;
      b.writeln('  Around then: $clipped');
    }
  }
  return b.toString().trimRight();
}

/// One line per marker for transcript exports.
List<String> highlightLines(Recording rec) {
  final markers = [...rec.markers]..sort((a, b) => a.atMs.compareTo(b.atMs));
  final lines = <String>[];
  for (final m in markers) {
    final time = formatDuration(Duration(milliseconds: m.atMs));
    final kind = switch (m.type) {
      MarkerType.flag => 'Highlight',
      MarkerType.photo => 'Photo',
      MarkerType.note => 'Note',
    };
    final text = m.text?.trim() ?? '';
    lines.add(text.isEmpty ? '[$time] $kind' : '[$time] $kind: $text');
  }
  return lines;
}

/// What was said in the [lookback] leading up to a marked moment: the Plaud
/// app analyses the audio before a highlight, so this shows that stretch of
/// the transcript (computed on the phone). Segments that only start after
/// the mark are left out; the last one may run a little past it. Empty when
/// nothing was said then or there is no transcript yet.
String highlightExcerpt(List<TranscriptSegment> segments, int atMs,
    {double lookback = 20, int maxChars = 280}) {
  final at = atMs / 1000;
  final text = segments
      .where((s) => s.end > at - lookback && s.start <= at)
      .map((s) => s.text.trim())
      .where((t) => t.isNotEmpty)
      .join(' ');
  if (text.length <= maxChars) return text;
  // Keep the end: the words right before the mark matter most.
  final cut = text.substring(text.length - maxChars);
  final space = cut.indexOf(' ');
  return '…${space > 0 && space < 40 ? cut.substring(space + 1) : cut}';
}
