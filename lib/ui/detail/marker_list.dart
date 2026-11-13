import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/recording.dart';
import '../../services/library/recording_store.dart';
import '../format.dart';
import '../theme.dart';

/// Highlights, photos and notes marked while recording; tap one to jump there.
class MarkerList extends StatelessWidget {
  final Recording rec;
  final void Function(RecordingMarker marker) onSeek;
  const MarkerList({super.key, required this.rec, required this.onSeek});

  @override
  Widget build(BuildContext context) {
    if (rec.markers.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    final store = context.read<RecordingStore>();
    final markers = [...rec.markers]..sort((a, b) => a.atMs.compareTo(b.atMs));

    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Highlights', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          for (final m in markers)
            InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => onSeek(m),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(_icon(m.type), size: 20, color: c.muted),
                    const SizedBox(width: 10),
                    Text(
                      formatDuration(Duration(milliseconds: m.atMs)),
                      style: TextStyle(
                        color: c.muted,
                        fontSize: 14,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        m.text ?? _label(m.type),
                        style: const TextStyle(fontSize: 15, height: 1.35),
                      ),
                    ),
                    if (store.photoOf(rec, m) case final File photo)
                      Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: GestureDetector(
                          onTap: () => _showPhoto(context, photo),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.file(photo,
                                width: 64,
                                height: 64,
                                fit: BoxFit.cover,
                                cacheWidth: 200,
                                errorBuilder: (_, __, ___) => Container(
                                    width: 64,
                                    height: 64,
                                    color: c.fill,
                                    child: Icon(Icons.broken_image_outlined,
                                        color: c.muted))),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          const Divider(height: 1),
        ],
      ),
    );
  }

  static IconData _icon(MarkerType t) => switch (t) {
        MarkerType.flag => Icons.flag_outlined,
        MarkerType.photo => Icons.photo_camera_outlined,
        MarkerType.note => Icons.edit_note,
      };

  static String _label(MarkerType t) => switch (t) {
        MarkerType.flag => 'Highlight',
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
