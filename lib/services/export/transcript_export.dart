import 'dart:convert';
import 'dart:typed_data';

import '../../models/recording.dart';
import '../../ui/format.dart';
import '../ai/ai_types.dart';
import 'docx_writer.dart';
import 'export_types.dart';
import 'markdown_blocks.dart';
import 'pdf_writer.dart';
import '../notes/highlights.dart';
import 'transcript_paragraphs.dart';

class TranscriptExportOptions {
  final bool speakers;
  final bool timestamps;
  const TranscriptExportOptions({this.speakers = true, this.timestamps = true});
}

/// One exported paragraph: who said it, when it starts, and the text.
class ExportParagraph {
  final double start;
  final String? speaker;
  final String text;
  const ExportParagraph(this.start, this.speaker, this.text);
}

List<ExportParagraph> exportParagraphs(Recording rec) {
  final t = rec.transcript;
  if (t == null) return const [];
  if (t.segments.isEmpty) {
    final text = t.text.trim();
    return text.isEmpty ? const [] : [ExportParagraph(0, null, text)];
  }
  return [
    for (final group in groupTranscriptParagraphs(rec, t.segments))
      ExportParagraph(
        group.first.start,
        group.first.speaker == null
            ? null
            : rec.speakerName(group.first.speaker!),
        group.map((s) => s.text.trim()).where((s) => s.isNotEmpty).join(' '),
      ),
  ];
}

String _prefix(ExportParagraph p, TranscriptExportOptions o) {
  final b = StringBuffer();
  if (o.timestamps) b.write('[${formatSeconds(p.start)}] ');
  if (o.speakers && p.speaker != null) b.write('${p.speaker}: ');
  return b.toString();
}

String _metaLine(Recording rec) {
  final lang = rec.transcript?.language;
  return [
    formatDate(rec.createdAt),
    if (rec.durationMs > 0) formatShortDuration(rec.duration),
    if (lang != null && lang.isNotEmpty) lang.toUpperCase(),
  ].join('  ·  ');
}

String transcriptToTxt(Recording rec, TranscriptExportOptions o) {
  final b = StringBuffer()
    ..writeln(rec.title)
    ..writeln(_metaLine(rec))
    ..writeln();
  for (final p in exportParagraphs(rec)) {
    b
      ..writeln('${_prefix(p, o)}${p.text}')
      ..writeln();
  }
  final marks = highlightLines(rec);
  if (marks.isNotEmpty) {
    b.writeln('Highlights');
    for (final m in marks) {
      b.writeln('- $m');
    }
  }
  return '${b.toString().trimRight()}\n';
}

String srtTime(double seconds) {
  final ms = (seconds * 1000).round().clamp(0, 1 << 40).toInt();
  String two(int v) => v.toString().padLeft(2, '0');
  final h = ms ~/ 3600000;
  final m = (ms ~/ 60000) % 60;
  final s = (ms ~/ 1000) % 60;
  final milli = (ms % 1000).toString().padLeft(3, '0');
  return '${two(h)}:${two(m)}:${two(s)},$milli';
}

String transcriptToSrt(Recording rec, TranscriptExportOptions o) {
  final segments = rec.transcript?.segments ?? const <TranscriptSegment>[];
  final b = StringBuffer();
  var n = 0;
  for (final s in segments) {
    final text = s.text.trim();
    if (text.isEmpty) continue;
    n++;
    final end = s.end > s.start ? s.end : s.start + 0.5;
    final who =
        o.speakers && s.speaker != null ? '${rec.speakerName(s.speaker!)}: ' : '';
    b
      ..writeln(n)
      ..writeln('${srtTime(s.start)} --> ${srtTime(end)}')
      ..writeln('$who$text')
      ..writeln();
  }
  return b.toString();
}

List<MdBlock> transcriptBlocks(Recording rec, TranscriptExportOptions o) {
  return [
    MdHeading(1, [MdSpan(rec.title)]),
    MdParagraph([MdSpan(_metaLine(rec), italic: true)]),
    for (final p in exportParagraphs(rec))
      MdParagraph([
        if (_prefix(p, o).isNotEmpty) MdSpan(_prefix(p, o), bold: true),
        MdSpan(p.text),
      ]),
    if (highlightLines(rec).isNotEmpty) ...[
      MdHeading(2, [const MdSpan('Highlights')]),
      for (final m in highlightLines(rec)) MdListItem('•', 0, [MdSpan(m)]),
    ],
  ];
}

Future<ExportFile> exportTranscript(
  Recording rec,
  TranscriptFormat format,
  TranscriptExportOptions options, {
  PdfFonts? fonts,
}) async {
  final name = '${exportBaseName(rec)}_transcript.${format.ext}';
  final Uint8List bytes;
  switch (format) {
    case TranscriptFormat.txt:
      bytes = Uint8List.fromList(utf8.encode(transcriptToTxt(rec, options)));
    case TranscriptFormat.srt:
      bytes = Uint8List.fromList(utf8.encode(transcriptToSrt(rec, options)));
    case TranscriptFormat.docx:
      bytes = blocksToDocx(transcriptBlocks(rec, options), title: rec.title);
    case TranscriptFormat.pdf:
      final f = fonts ?? PdfFonts.fallback();
      bytes = await blocksToPdf(transcriptBlocks(rec, options),
          regular: f.regular, bold: f.bold, title: rec.title);
  }
  return ExportFile(name, bytes, format.mime);
}
