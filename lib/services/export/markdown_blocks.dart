/// A tiny Markdown block model shared by the PDF, DOCX and plain-text
/// exporters. Covers what the note models produce: headings, paragraphs,
/// bullet / numbered / checkbox lists, quotes, rules, code blocks, tables and
/// inline **bold**, *italic* and `code`.
library;

class MdSpan {
  final String text;
  final bool bold;
  final bool italic;
  final bool code;
  const MdSpan(this.text,
      {this.bold = false, this.italic = false, this.code = false});
}

sealed class MdBlock {
  const MdBlock();
}

final class MdHeading extends MdBlock {
  final int level; // 1..6
  final List<MdSpan> spans;
  const MdHeading(this.level, this.spans);
}

final class MdParagraph extends MdBlock {
  final List<MdSpan> spans;
  const MdParagraph(this.spans);
}

/// A list line; [marker] is `•`, `1.`, `[ ]` or `[x]`.
final class MdListItem extends MdBlock {
  final String marker;
  final int indent;
  final List<MdSpan> spans;
  const MdListItem(this.marker, this.indent, this.spans);
}

final class MdQuote extends MdBlock {
  final List<MdSpan> spans;
  const MdQuote(this.spans);
}

final class MdCode extends MdBlock {
  final String text;
  const MdCode(this.text);
}

final class MdTable extends MdBlock {
  /// Rows of cells; the first row is a header when [hasHeader].
  final List<List<List<MdSpan>>> rows;
  final bool hasHeader;
  const MdTable(this.rows, {this.hasHeader = false});
}

final class MdRule extends MdBlock {
  const MdRule();
}

final _heading = RegExp(r'^(#{1,6})\s+(.*)$');
final _rule = RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$');
final _bullet = RegExp(r'^(\s*)[-*+•]\s+(.*)$');
final _numbered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$');
final _checkbox = RegExp(r'^\[([ xX])\]\s+(.*)$');
final _inlinePattern =
    RegExp(r'\*\*(.+?)\*\*|__(.+?)__|\*([^*\s][^*]*?)\*|`([^`]+)`');
final _tableSeparatorCell = RegExp(r'^:?-{2,}:?$');

List<MdBlock> parseMarkdown(String source) {
  final out = <MdBlock>[];
  final para = <String>[];
  final code = <String>[];
  var table = <String>[];
  var inCode = false;

  void flushPara() {
    if (para.isEmpty) return;
    out.add(MdParagraph(parseInline(para.join(' '))));
    para.clear();
  }

  void flushTable() {
    if (table.isEmpty) return;
    out.add(_buildTable(table));
    table = <String>[];
  }

  for (final raw in source.split('\n')) {
    final line = raw.trimRight();

    if (line.trimLeft().startsWith('```')) {
      flushPara();
      flushTable();
      if (inCode) {
        out.add(MdCode(code.join('\n')));
        code.clear();
      }
      inCode = !inCode;
      continue;
    }
    if (inCode) {
      code.add(raw);
      continue;
    }

    if (line.trimLeft().startsWith('|')) {
      flushPara();
      table.add(line);
      continue;
    }
    flushTable();

    if (line.trim().isEmpty) {
      flushPara();
      continue;
    }
    final heading = _heading.firstMatch(line);
    if (heading != null) {
      flushPara();
      out.add(MdHeading(heading.group(1)!.length, parseInline(heading.group(2)!)));
      continue;
    }
    if (_rule.hasMatch(line)) {
      flushPara();
      out.add(const MdRule());
      continue;
    }
    final bullet = _bullet.firstMatch(line);
    final numbered = _numbered.firstMatch(line);
    if (bullet != null || numbered != null) {
      flushPara();
      final m = (bullet ?? numbered)!;
      final indent = m.group(1)!.length ~/ 2;
      var marker = bullet != null ? '•' : '${numbered!.group(2)}.';
      var text = bullet != null ? bullet.group(2)! : numbered!.group(3)!;
      final box = _checkbox.firstMatch(text);
      if (box != null) {
        marker = box.group(1) == ' ' ? '[ ]' : '[x]';
        text = box.group(2)!;
      }
      out.add(MdListItem(marker, indent, parseInline(text)));
      continue;
    }
    if (line.startsWith('>')) {
      flushPara();
      out.add(MdQuote(parseInline(line.replaceFirst(RegExp(r'^>\s?'), ''))));
      continue;
    }
    para.add(line.trim());
  }
  if (inCode) out.add(MdCode(code.join('\n')));
  flushPara();
  flushTable();
  return out;
}

MdTable _buildTable(List<String> lines) {
  List<String> cells(String l) {
    var t = l.trim();
    if (t.startsWith('|')) t = t.substring(1);
    if (t.endsWith('|')) t = t.substring(0, t.length - 1);
    return t.split('|').map((c) => c.trim()).toList();
  }

  final rows = <List<List<MdSpan>>>[];
  var hasHeader = false;
  for (var i = 0; i < lines.length; i++) {
    final c = cells(lines[i]);
    if (c.isNotEmpty && c.every(_tableSeparatorCell.hasMatch)) {
      if (i == 1) hasHeader = true;
      continue;
    }
    rows.add([for (final cell in c) parseInline(cell)]);
  }
  return MdTable(rows, hasHeader: hasHeader);
}

List<MdSpan> parseInline(String text) {
  final spans = <MdSpan>[];
  var pos = 0;
  for (final m in _inlinePattern.allMatches(text)) {
    if (m.start > pos) spans.add(MdSpan(text.substring(pos, m.start)));
    if (m.group(1) != null || m.group(2) != null) {
      spans.add(MdSpan(m.group(1) ?? m.group(2)!, bold: true));
    } else if (m.group(3) != null) {
      spans.add(MdSpan(m.group(3)!, italic: true));
    } else {
      spans.add(MdSpan(m.group(4)!, code: true));
    }
    pos = m.end;
  }
  if (pos < text.length) spans.add(MdSpan(text.substring(pos)));
  return spans;
}

String spansToText(List<MdSpan> spans) => spans.map((s) => s.text).join();

/// Readable plain text for `.txt` exports.
String blocksToPlainText(List<MdBlock> blocks) {
  final b = StringBuffer();
  for (final block in blocks) {
    switch (block) {
      case MdHeading h:
        if (b.isNotEmpty) b.writeln();
        final t = spansToText(h.spans);
        b.writeln(h.level == 1 ? t.toUpperCase() : t);
        if (h.level == 1) b.writeln('=' * t.length.clamp(3, 60).toInt());
      case MdParagraph p:
        b.writeln(spansToText(p.spans));
        b.writeln();
      case MdListItem l:
        b.writeln('${'  ' * l.indent}${l.marker == '•' ? '-' : l.marker} '
            '${spansToText(l.spans)}');
      case MdQuote q:
        b.writeln('> ${spansToText(q.spans)}');
      case MdCode c:
        b.writeln(c.text);
        b.writeln();
      case MdTable t:
        for (final row in t.rows) {
          b.writeln(row.map(spansToText).join('  |  '));
        }
        b.writeln();
      case MdRule _:
        b.writeln('-' * 24);
    }
  }
  return '${b.toString().trimRight()}\n';
}
