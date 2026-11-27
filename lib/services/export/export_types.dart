import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../models/recording.dart';

/// A generated file, ready to save or share.
class ExportFile {
  final String name;
  final Uint8List bytes;
  final String mime;
  const ExportFile(this.name, this.bytes, this.mime);
}

/// Fonts for PDF export (they decide which characters can be drawn).
class PdfFonts {
  final pw.Font regular;
  final pw.Font bold;
  const PdfFonts(this.regular, this.bold);

  /// Built-in Helvetica: Latin-1 only. Used when no font asset was loaded.
  factory PdfFonts.fallback() =>
      PdfFonts(pw.Font.helvetica(), pw.Font.helveticaBold());
}

const _docxMime =
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document';

enum TranscriptFormat {
  txt('TXT', 'txt', 'text/plain'),
  docx('DOCX', 'docx', _docxMime),
  pdf('PDF', 'pdf', 'application/pdf'),
  srt('SRT', 'srt', 'application/x-subrip');

  final String label;
  final String ext;
  final String mime;
  const TranscriptFormat(this.label, this.ext, this.mime);
}

enum NotesFormat {
  txt('TXT', 'txt', 'text/plain'),
  docx('DOCX', 'docx', _docxMime),
  pdf('PDF', 'pdf', 'application/pdf'),
  md('MD', 'md', 'text/markdown');

  final String label;
  final String ext;
  final String mime;
  const NotesFormat(this.label, this.ext, this.mime);
}

/// File name stem for a recording: "<title>_<yyyy-MM-dd>", filesystem-safe.
String exportBaseName(Recording rec) {
  var title = rec.title
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (title.isEmpty) title = 'Recording';
  if (title.length > 60) title = title.substring(0, 60).trim();
  final date = DateFormat('yyyy-MM-dd').format(rec.createdAt);
  return '${title.replaceAll(' ', '_')}_$date';
}
