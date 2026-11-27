import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/recording.dart';
import '../../services/ai/ai_types.dart';
import '../../services/library/recording_store.dart';
import '../../services/notes/highlights.dart';
import '../format.dart';
import '../theme.dart';

/// The Notes > Highlights view, like the Plaud app's: each highlight, photo
/// and note marked while recording, with what was said just before it.
/// Tap one to play from there.
class MarkerList extends StatelessWidget {
  final Recording rec;
  final void Function(RecordingMarker marker) onSeek;
  const MarkerList({super.key, required this.rec, required this.onSeek});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final store = context.read<RecordingStore>();
    final markers = [...rec.markers]..sort((a, b) => a.atMs.compareTo(b.atMs));
    final segments = rec.transcript?.segments ?? const [];

    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      children: [
        for (final m in markers)
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onSeek(m),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(_icon(m.type), size: 22, color: c.text),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          // Rounded like the live timeline (29.7 s -> 00:00:30).
                          formatClock(
                              Duration(seconds: (m.atMs / 1000).round())),
                          style: TextStyle(
                            color: c.muted,
                            fontSize: 14,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 4),
                        ..._body(context, m, segments, store),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _body(BuildContext context, RecordingMarker m,
      List<TranscriptSegment> segments, RecordingStore store) {
    final c = context.colors;
    const main = TextStyle(fontSize: 17, height: 1.4);
    final note = m.text?.trim() ?? '';
    final excerpt = highlightExcerpt(segments, m.atMs);
    return [
      if (m.type == MarkerType.note && note.isNotEmpty)
        Text(note, style: main)
      else if (m.type != MarkerType.photo || excerpt.isEmpty)
        Text(_label(m.type), style: main),
      if (store.photoOf(rec, m) case final File photo)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: GestureDetector(
            onTap: () => _showPhoto(context, photo),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(photo,
                  height: 160,
                  fit: BoxFit.cover,
                  cacheHeight: 480,
                  errorBuilder: (_, __, ___) => Container(
                      width: 64,
                      height: 64,
                      color: c.fill,
                      child: Icon(Icons.broken_image_outlined,
                          color: c.muted))),
            ),
          ),
        ),
      if (excerpt.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('“$excerpt”',
              style: TextStyle(fontSize: 15, height: 1.45, color: c.muted)),
        )
      else if (rec.transcript == null && m.type == MarkerType.flag)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Transcribe the recording to see what was said here.',
              style: TextStyle(fontSize: 14, color: c.faint)),
        ),
    ];
  }

  static IconData _icon(MarkerType t) => switch (t) {
        MarkerType.flag => Icons.flag_outlined,
        MarkerType.photo => Icons.photo_camera_outlined,
        MarkerType.note => Icons.edit_outlined,
      };

  static String _label(MarkerType t) => switch (t) {
        MarkerType.flag => 'Highlighted',
        MarkerType.photo => 'Photo',
        MarkerType.note => 'Note',
      };

  void _showPhoto(BuildContext context, File photo) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
        ),
        body: Center(
          child: InteractiveViewer(child: Image.file(photo)),
        ),
      ),
    ));
  }
}
