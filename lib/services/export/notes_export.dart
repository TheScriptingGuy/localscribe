import 'dart:convert';
import 'dart:typed_data';

import '../../models/recording.dart';
import 'docx_writer.dart';
import 'export_types.dart';
import 'markdown_blocks.dart';
import 'pdf_writer.dart';

Future<ExportFile> exportNote(
  Recording rec,
  GeneratedNote note,
  NotesFormat format, {
  PdfFonts? fonts,
}) async {
  final name = '${exportBaseName(rec)}_notes.${format.ext}';
  final blocks = parseMarkdown(note.content);
  final Uint8List bytes;
  switch (format) {
    case NotesFormat.md:
      bytes = Uint8List.fromList(utf8.encode('${note.content.trimRight()}\n'));
    case NotesFormat.txt:
      bytes = Uint8List.fromList(utf8.encode(blocksToPlainText(blocks)));
    case NotesFormat.docx:
      bytes = blocksToDocx(blocks, title: rec.title);
    case NotesFormat.pdf:
      final f = fonts ?? PdfFonts.fallback();
      bytes = await blocksToPdf(blocks,
          regular: f.regular, bold: f.bold, title: rec.title);
  }
  return ExportFile(name, bytes, format.mime);
}
