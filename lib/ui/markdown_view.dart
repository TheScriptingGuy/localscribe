import 'package:flutter/material.dart';

import 'theme.dart';

/// Renders the Markdown subset the note/chat models produce: headings,
/// bullet and numbered lists, quotes, rules, code blocks, and inline
/// **bold**, *italic* and `code`. Unknown syntax falls through as text.
class MarkdownView extends StatelessWidget {
  final String source;

  /// Use smaller headings (chat answers).
  final bool compact;
  const MarkdownView(this.source, {super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyLarge!;
    final c = context.colors;
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _blocks(body, c),
      ),
    );
  }

  List<Widget> _blocks(TextStyle body, AppColors c) {
    final out = <Widget>[];
    final para = <String>[];
    final code = <String>[];
    var inCode = false;

    void flush() {
      if (para.isEmpty) return;
      out.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text.rich(_inline(para.join(' '), body, c)),
      ));
      para.clear();
    }

    for (final raw in source.split('\n')) {
      final line = raw.trimRight();
      if (line.trimLeft().startsWith('```')) {
        if (inCode) {
          out.add(_codeBlock(code.join('\n'), body, c));
          code.clear();
        } else {
          flush();
        }
        inCode = !inCode;
        continue;
      }
      if (inCode) {
        code.add(raw);
        continue;
      }
      if (line.trim().isEmpty) {
        flush();
        continue;
      }

      final heading = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
      if (heading != null) {
        flush();
        out.add(_heading(
            heading.group(1)!.length, heading.group(2)!, body, c));
        continue;
      }
      if (RegExp(r'^\s*([-*_])(\s*\1){2,}\s*$').hasMatch(line)) {
        flush();
        out.add(const Divider(height: 32));
        continue;
      }
      final bullet = RegExp(r'^(\s*)[-*+•]\s+(.*)$').firstMatch(line);
      final numbered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)$').firstMatch(line);
      if (bullet != null || numbered != null) {
        flush();
        final indent = (bullet ?? numbered)!.group(1)!.length ~/ 2;
        out.add(_listItem(
          marker: bullet != null ? '•' : '${numbered!.group(2)}.',
          text: bullet != null ? bullet.group(2)! : numbered!.group(3)!,
          indent: indent,
          body: body,
          c: c,
        ));
        continue;
      }
      if (line.startsWith('>')) {
        flush();
        out.add(_quote(line.replaceFirst(RegExp(r'^>\s?'), ''), body, c));
        continue;
      }
      if (line.trimLeft().startsWith('|')) {
        // Tables: keep them legible as monospace rows.
        flush();
        out.add(Text(line,
            style: body.copyWith(fontFamily: 'monospace', fontSize: 13)));
        continue;
      }
      para.add(line.trim());
    }
    if (inCode) out.add(_codeBlock(code.join('\n'), body, c));
    flush();
    return out;
  }

  Widget _heading(int level, String text, TextStyle body, AppColors c) {
    final (size, top) = switch (level) {
      1 => compact ? (22.0, 8.0) : (30.0, 8.0),
      2 => compact ? (19.0, 12.0) : (24.0, 24.0),
      _ => compact ? (17.0, 10.0) : (19.0, 16.0),
    };
    final style = body.copyWith(
        fontSize: size,
        fontWeight: level == 1 ? FontWeight.w800 : FontWeight.w700,
        height: 1.25);
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: 10),
      child: Text.rich(_inline(text, style, c)),
    );
  }

  Widget _listItem({
    required String marker,
    required String text,
    required int indent,
    required TextStyle body,
    required AppColors c,
  }) {
    return Padding(
      padding: EdgeInsets.only(left: 4.0 + indent * 20, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: marker == '•' ? 18 : 26,
            child: Text(marker, style: body.copyWith(color: c.muted)),
          ),
          Expanded(child: Text.rich(_inline(text, body, c))),
        ],
      ),
    );
  }

  Widget _quote(String text, TextStyle body, AppColors c) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.only(left: 14),
        decoration: BoxDecoration(
            border: Border(left: BorderSide(color: c.line, width: 3))),
        child: Text.rich(_inline(text, body.copyWith(color: c.muted), c)),
      );

  Widget _codeBlock(String text, TextStyle body, AppColors c) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: c.fill,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(text,
            style: body.copyWith(fontFamily: 'monospace', fontSize: 13)),
      );

  static final _inlinePattern =
      RegExp(r'\*\*(.+?)\*\*|__(.+?)__|\*([^*\s][^*]*?)\*|`([^`]+)`');

  TextSpan _inline(String text, TextStyle style, AppColors c) {
    final spans = <InlineSpan>[];
    var pos = 0;
    for (final m in _inlinePattern.allMatches(text)) {
      if (m.start > pos) spans.add(TextSpan(text: text.substring(pos, m.start)));
      if (m.group(1) != null || m.group(2) != null) {
        spans.add(TextSpan(
            text: m.group(1) ?? m.group(2),
            style: const TextStyle(fontWeight: FontWeight.w700)));
      } else if (m.group(3) != null) {
        spans.add(TextSpan(
            text: m.group(3),
            style: const TextStyle(fontStyle: FontStyle.italic)));
      } else {
        spans.add(TextSpan(
            text: m.group(4),
            style: TextStyle(
                fontFamily: 'monospace', backgroundColor: c.fill)));
      }
      pos = m.end;
    }
    if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
    return TextSpan(style: style, children: spans);
  }
}
