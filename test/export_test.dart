import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:localscribe/models/recording.dart';
import 'package:localscribe/services/ai/ai_types.dart';
import 'package:localscribe/services/export/audio_export.dart';
import 'package:localscribe/services/export/docx_writer.dart';
import 'package:localscribe/services/export/export_types.dart';
import 'package:localscribe/services/export/markdown_blocks.dart';
import 'package:localscribe/services/export/pdf_writer.dart';
import 'package:localscribe/services/export/transcript_export.dart';
import 'package:localscribe/services/export/zip_writer.dart';
import 'package:pdf/widgets.dart' as pw;

Recording makeRecording({String title = 'Team sync'}) => Recording(
      id: '1',
      title: title,
      createdAt: DateTime(2026, 11, 13, 20, 7),
      audioFile: 'audio.m4a',
      durationMs: 23000,
      speakerNames: {'S1': 'Anna'},
      transcript: const TranscriptResult(
        text: 'Hello there. Hi!',
        language: 'en',
        segments: [
          TranscriptSegment(
              start: 0, end: 3.5, text: ' Hello there.', speaker: 'S1'),
          TranscriptSegment(start: 3.6, end: 6, text: 'Hi!', speaker: 'S2'),
        ],
      ),
    );

/// Reads every entry of a stored (uncompressed) zip: name -> bytes + stored crc.
Map<String, (Uint8List, int)> readZip(Uint8List z) {
  final d = ByteData.sublistView(z);
  final eocd = z.length - 22;
  expect(d.getUint32(eocd, Endian.little), 0x06054b50, reason: 'EOCD signature');
  final count = d.getUint16(eocd + 10, Endian.little);
  var cd = d.getUint32(eocd + 16, Endian.little);
  final out = <String, (Uint8List, int)>{};
  for (var i = 0; i < count; i++) {
    expect(d.getUint32(cd, Endian.little), 0x02014b50);
    final crc = d.getUint32(cd + 16, Endian.little);
    final size = d.getUint32(cd + 24, Endian.little);
    final nameLen = d.getUint16(cd + 28, Endian.little);
    final extraLen = d.getUint16(cd + 30, Endian.little);
    final commentLen = d.getUint16(cd + 32, Endian.little);
    final local = d.getUint32(cd + 42, Endian.little);
    final name = utf8.decode(z.sublist(cd + 46, cd + 46 + nameLen));
    expect(d.getUint32(local, Endian.little), 0x04034b50);
    final lNameLen = d.getUint16(local + 26, Endian.little);
    final lExtraLen = d.getUint16(local + 28, Endian.little);
    final start = local + 30 + lNameLen + lExtraLen;
    out[name] = (Uint8List.sublistView(z, start, start + size), crc);
    cd += 46 + nameLen + extraLen + commentLen;
  }
  return out;
}

void main() {
  group('transcript export', () {
    test('srtTime formats hours, minutes, seconds and milliseconds', () {
      expect(srtTime(0), '00:00:00,000');
      expect(srtTime(3723.456), '01:02:03,456');
    });

    test('SRT numbers cues and prefixes speaker names', () {
      final srt =
          transcriptToSrt(makeRecording(), const TranscriptExportOptions());
      expect(
          srt,
          '1\n00:00:00,000 --> 00:00:03,500\nAnna: Hello there.\n\n'
          '2\n00:00:03,600 --> 00:00:06,000\nSpeaker 2: Hi!\n\n');
    });

    test('SRT without speakers has only text', () {
      final srt = transcriptToSrt(makeRecording(),
          const TranscriptExportOptions(speakers: false));
      expect(srt, contains('\nHello there.\n'));
      expect(srt, isNot(contains('Anna')));
    });

    test('TXT includes timestamps and speakers by default', () {
      final txt =
          transcriptToTxt(makeRecording(), const TranscriptExportOptions());
      expect(txt, startsWith('Team sync\n'));
      expect(txt, contains('[00:00] Anna: Hello there.'));
      expect(txt, contains('[00:03] Speaker 2: Hi!'));
    });

    test('TXT can drop timestamps and speakers', () {
      final txt = transcriptToTxt(makeRecording(),
          const TranscriptExportOptions(speakers: false, timestamps: false));
      expect(txt, contains('\nHello there.\n'));
      expect(txt, isNot(contains('[00:')));
      expect(txt, isNot(contains('Anna')));
    });

    test('file names are filesystem-safe and dated', () {
      expect(exportBaseName(makeRecording(title: 'Team: sync/notes?')),
          'Team_sync_notes_2026-11-13');
      expect(exportBaseName(makeRecording(title: '???')), 'Recording_2026-11-13');
    });
  });

  group('markdown blocks', () {
    test('headings, lists, checkboxes and inline styles', () {
      final blocks = parseMarkdown('# Title\n\nSome **bold** and *it* text.\n\n'
          '- one\n- [ ] todo\n- [x] done\n1. first\n');
      expect(blocks[0], isA<MdHeading>());
      final para = blocks[1] as MdParagraph;
      expect(para.spans.where((s) => s.bold).single.text, 'bold');
      expect(para.spans.where((s) => s.italic).single.text, 'it');
      final items = blocks.whereType<MdListItem>().toList();
      expect(items.map((e) => e.marker), ['•', '[ ]', '[x]', '1.']);
      expect(spansToText(items[1].spans), 'todo');
    });

    test('tables keep their header row and skip the separator', () {
      final t = parseMarkdown('| A | B |\n|---|---|\n| 1 | 2 |\n')
          .whereType<MdTable>()
          .single;
      expect(t.hasHeader, isTrue);
      expect(t.rows.length, 2);
      expect(spansToText(t.rows[1][1]), '2');
    });

    test('plain text rendering', () {
      final txt = blocksToPlainText(parseMarkdown('## Plan\n- a\n- b'));
      expect(txt, contains('Plan'));
      expect(txt, contains('- a'));
    });
  });

  group('file formats', () {
    test('crc32 matches the standard check value', () {
      expect(crc32(utf8.encode('123456789')), 0xCBF43926);
    });

    test('docx is a valid zip with the required parts and escaped text', () {
      final bytes = blocksToDocx(parseMarkdown('# A & B\n\nx < y\n\n'
          '| H1 | H2 |\n|--|--|\n| 1 | 2 |'));
      final zip = readZip(bytes);
      expect(
          zip.keys,
          containsAll([
            '[Content_Types].xml',
            '_rels/.rels',
            'word/document.xml',
            'word/styles.xml',
            'word/_rels/document.xml.rels',
          ]));
      for (final e in zip.entries) {
        expect(crc32(e.value.$1), e.value.$2, reason: 'crc of ${e.key}');
      }
      final doc = utf8.decode(zip['word/document.xml']!.$1);
      expect(doc, contains('A &amp; B'));
      expect(doc, contains('x &lt; y'));
      expect(doc, contains('<w:tbl>'));
    });

    test('xmlEscape drops characters XML cannot hold', () {
      expect(xmlEscape('a\u0000b\u0008c&'), 'abc&amp;');
    });

    test('pdf output starts with the PDF header', () async {
      final bytes = await blocksToPdf(
        parseMarkdown('# Notes\n\n- one\n- two\n\nSome text.'),
        regular: pw.Font.helvetica(),
        bold: pw.Font.helveticaBold(),
        title: 'Notes',
      );
      expect(utf8.decode(bytes.sublist(0, 5)), '%PDF-');
    });

    test('wav header describes 16 kHz mono 16-bit PCM', () {
      final pcm = Uint8List(32000);
      final wav = wavFromPcm16(pcm);
      expect(wav.length, 44 + 32000);
      expect(utf8.decode(wav.sublist(0, 4)), 'RIFF');
      expect(utf8.decode(wav.sublist(8, 12)), 'WAVE');
      final d = ByteData.sublistView(wav);
      expect(d.getUint32(24, Endian.little), 16000);
      expect(d.getUint16(22, Endian.little), 1);
      expect(d.getUint16(34, Endian.little), 16);
      expect(d.getUint32(40, Endian.little), 32000);
    });
  });
}
