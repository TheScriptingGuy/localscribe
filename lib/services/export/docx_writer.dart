import 'dart:typed_data';

import 'markdown_blocks.dart';
import 'zip_writer.dart';

/// Writes [blocks] as a minimal but standards-conforming .docx (OOXML).
Uint8List blocksToDocx(List<MdBlock> blocks, {String title = ''}) {
  final body = StringBuffer();
  for (final block in blocks) {
    switch (block) {
      case MdHeading h:
        final level = h.level.clamp(1, 3).toInt();
        body.write(_p(h.spans, style: 'Heading$level'));
      case MdParagraph p:
        body.write(_p(p.spans));
      case MdListItem l:
        final left = 360 + l.indent * 360;
        body.write('<w:p><w:pPr><w:spacing w:after="60"/>'
            '<w:ind w:left="$left" w:hanging="300"/></w:pPr>'
            '${_run(l.marker, const MdSpan(''))}'
            '<w:r><w:tab/></w:r>${_runs(l.spans)}</w:p>');
      case MdQuote q:
        body.write(_p(q.spans, style: 'Quote'));
      case MdCode c:
        for (final line in c.text.split('\n')) {
          body.write(_p([MdSpan(line, code: true)], style: 'Code'));
        }
      case MdTable t:
        body.write(_table(t));
      case MdRule _:
        body.write('<w:p><w:pPr><w:pBdr><w:bottom w:val="single" w:sz="6" '
            'w:space="1" w:color="BBBBBB"/></w:pBdr></w:pPr></w:p>');
    }
  }

  final zip = ZipWriter()
    ..addText('[Content_Types].xml', _contentTypes)
    ..addText('_rels/.rels', _rootRels)
    ..addText('word/_rels/document.xml.rels', _docRels)
    ..addText('word/styles.xml', _styles)
    ..addText('word/document.xml', '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="$_w"><w:body>$body<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1304" w:right="1304" w:bottom="1304" w:left="1304" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>''');
  return zip.build();
}

const _w = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

String _p(List<MdSpan> spans, {String? style}) =>
    '<w:p>${style == null ? '' : '<w:pPr><w:pStyle w:val="$style"/></w:pPr>'}'
    '${_runs(spans)}</w:p>';

String _runs(List<MdSpan> spans) =>
    spans.map((s) => _run(s.text, s)).join();

String _run(String text, MdSpan s) {
  final props = StringBuffer();
  if (s.code) {
    props.write('<w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" '
        'w:cs="Courier New"/>');
  }
  if (s.bold) props.write('<w:b/>');
  if (s.italic) props.write('<w:i/>');
  final rPr = props.isEmpty ? '' : '<w:rPr>$props</w:rPr>';
  return '<w:r>$rPr<w:t xml:space="preserve">${xmlEscape(text)}</w:t></w:r>';
}

String _table(MdTable t) {
  final cols = t.rows.fold<int>(0, (m, r) => r.length > m ? r.length : m);
  if (cols == 0) return '';
  final grid = List.filled(cols, '<w:gridCol w:w="${9000 ~/ cols}"/>').join();
  final b = StringBuffer(
      '<w:tbl><w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>'
      '${['top', 'left', 'bottom', 'right', 'insideH', 'insideV'].map((e) => '<w:$e w:val="single" w:sz="4" w:space="0" w:color="BBBBBB"/>').join()}'
      '</w:tblBorders><w:tblCellMar><w:left w:w="100" w:type="dxa"/>'
      '<w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr>'
      '<w:tblGrid>$grid</w:tblGrid>');
  for (var r = 0; r < t.rows.length; r++) {
    final header = t.hasHeader && r == 0;
    b.write('<w:tr>');
    for (var c = 0; c < cols; c++) {
      final cell = c < t.rows[r].length ? t.rows[r][c] : const <MdSpan>[];
      final spans = header
          ? [for (final s in cell) MdSpan(s.text, bold: true, italic: s.italic, code: s.code)]
          : cell;
      b.write('<w:tc><w:tcPr><w:tcW w:w="${9000 ~/ cols}" w:type="dxa"/>'
          '${header ? '<w:shd w:val="clear" w:color="auto" w:fill="EEEEEE"/>' : ''}'
          '</w:tcPr>${_p(spans)}</w:tc>');
    }
    b.write('</w:tr>');
  }
  b.write('</w:tbl><w:p/>');
  return b.toString();
}

/// Escapes XML text and drops characters XML 1.0 cannot represent.
String xmlEscape(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final ok = r == 0x9 ||
        r == 0xA ||
        r == 0xD ||
        (r >= 0x20 && r <= 0xD7FF) ||
        (r >= 0xE000 && r <= 0xFFFD) ||
        (r >= 0x10000 && r <= 0x10FFFF);
    if (!ok) continue;
    switch (r) {
      case 0x26:
        b.write('&amp;');
      case 0x3C:
        b.write('&lt;');
      case 0x3E:
        b.write('&gt;');
      case 0x22:
        b.write('&quot;');
      default:
        b.writeCharCode(r);
    }
  }
  return b.toString();
}

const _contentTypes = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>''';

const _rootRels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>''';

const _docRels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>''';

const _styles = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="$_w"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="40"/><w:szCs w:val="40"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="60"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="25"/><w:szCs w:val="25"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="BBBBBB"/></w:pBdr><w:ind w:left="360"/></w:pPr><w:rPr><w:i/><w:color w:val="555555"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/><w:spacing w:after="0"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="20"/></w:rPr></w:style></w:styles>''';
