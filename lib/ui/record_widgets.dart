import 'package:flutter/material.dart';

import 'theme.dart';

/// Small labelled button for marking a moment while recording.
class MarkerButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  const MarkerButton(
      {required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.outlined(
          tooltip: label,
          iconSize: 26,
          style: IconButton.styleFrom(fixedSize: const Size(56, 56)),
          onPressed: onPressed,
          icon: Icon(icon),
        ),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(color: context.colors.muted, fontSize: 12)),
      ],
    );
  }
}

class RoundButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  const RoundButton(
      {required this.tooltip, required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: context.colors.text,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: 88,
            height: 88,
            child: Icon(icon, color: context.colors.inverse, size: 40),
          ),
        ),
      ),
    );
  }
}

/// Rolling live captions, collapsible.
class CaptionsPanel extends StatelessWidget {
  final List<String> lines;
  final bool open;
  final String? error;
  final VoidCallback onToggle;
  const CaptionsPanel(
      {super.key,
      required this.lines,
      required this.open,
      required this.error,
      required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.closed_caption_outlined, size: 18, color: c.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Live captions',
                    style: TextStyle(color: c.muted, fontSize: 13)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: open ? 'Hide captions' : 'Show captions',
                onPressed: onToggle,
                icon: Icon(open ? Icons.expand_less : Icons.expand_more),
              ),
            ],
          ),
          if (open)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                error != null
                    ? 'Captions paused: $error'
                    : lines.isEmpty
                        ? 'Listening…'
                        : lines.join(' '),
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 16,
                    height: 1.4,
                    color: error != null ? c.danger : c.text),
              ),
            ),
        ],
      ),
    );
  }
}
