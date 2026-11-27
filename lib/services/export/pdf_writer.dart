import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'markdown_blocks.dart';

/// Renders [blocks] as an A4 PDF using [regular] and [bold] for all text.
/// Pass a font with the glyphs your content needs (Noto Sans covers Latin,
/// Greek and Cyrillic, with all diacritics).
Future<Uint8List> blocksToPdf(
  List<MdBlock> blocks, {
  required pw.Font regular,
  required pw.Font bold,
  String title = '',
}) async {
  final doc = pw.Document(
    title: title,
    creator: 'LocalScribe',
    theme: pw.ThemeData.withFont(
      base: regular,
      bold: bold,
      italic: regular,
      boldItalic: bold,
    ),
  );

  final widgets = <pw.Widget>[];
  for (final block in blocks) {
    switch (block) {
      case MdHeading h:
        final size = switch (h.level) { 1 => 22.0, 2 => 16.0, _ => 13.0 };
        widgets.add(pw.Padding(
          padding: pw.EdgeInsets.only(top: h.level == 1 ? 0.0 : 12.0, bottom: 6),
          child: _rich(h.spans, size: size, forceBold: true),
        ));
      case MdParagraph p:
        widgets.add(pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 8),
          child: _rich(p.spans),
        ));
      case MdListItem l:
        widgets.add(pw.Padding(
          padding: pw.EdgeInsets.only(left: 6.0 + l.indent * 14, bottom: 3),
          child: pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(
                width: l.marker.length > 2 ? 22.0 : 14.0,
                child: pw.Text(l.marker, style: const pw.TextStyle(fontSize: 11)),
              ),
              pw.Expanded(child: _rich(l.spans)),
            ],
          ),
        ));
      case MdQuote q:
        widgets.add(pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 8),
          padding: const pw.EdgeInsets.only(left: 10),
          decoration: const pw.BoxDecoration(
            border: pw.Border(
                left: pw.BorderSide(color: PdfColors.grey500, width: 2)),
          ),
          child: _rich(q.spans, color: PdfColors.grey700),
        ));
      case MdCode c:
        widgets.add(pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 8),
          padding: const pw.EdgeInsets.all(8),
          width: double.infinity,
          color: PdfColors.grey200,
          child: pw.Text(c.text, style: const pw.TextStyle(fontSize: 9.5)),
        ));
      case MdTable t:
        widgets.add(_table(t));
      case MdRule _:
        widgets.add(pw.Divider(color: PdfColors.grey400, height: 16));
    }
  }

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.fromLTRB(48, 48, 48, 48),
    footer: (ctx) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text('${ctx.pageNumber} / ${ctx.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
    ),
    build: (_) => widgets.isEmpty ? [pw.SizedBox()] : widgets,
  ));
  return doc.save();
}

pw.Widget _rich(List<MdSpan> spans,
    {double size = 11, bool forceBold = false, PdfColor? color}) {
  return pw.RichText(
    text: pw.TextSpan(
      style: pw.TextStyle(
        fontSize: size,
        lineSpacing: 2,
        color: color,
        fontWeight: forceBold ? pw.FontWeight.bold : null,
      ),
      children: [
        for (final s in spans)
          pw.TextSpan(
            text: s.text,
            style: pw.TextStyle(
              fontWeight: s.bold ? pw.FontWeight.bold : null,
              background: s.code
                  ? const pw.BoxDecoration(color: PdfColors.grey200)
                  : null,
            ),
          ),
      ],
    ),
  );
}

pw.Widget _table(MdTable t) {
  final cols = t.rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
  if (cols == 0) return pw.SizedBox();
  return pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 10),
    child: pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
      children: [
        for (var r = 0; r < t.rows.length; r++)
          pw.TableRow(
            decoration: t.hasHeader && r == 0
                ? const pw.BoxDecoration(color: PdfColors.grey200)
                : null,
            children: [
              for (var c = 0; c < cols; c++)
                pw.Padding(
                  padding: const pw.EdgeInsets.all(4),
                  child: _rich(
                    c < t.rows[r].length ? t.rows[r][c] : const <MdSpan>[],
                    size: 10,
                    forceBold: t.hasHeader && r == 0,
                  ),
                ),
            ],
          ),
      ],
    ),
  );
}
