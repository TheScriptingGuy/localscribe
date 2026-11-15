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
