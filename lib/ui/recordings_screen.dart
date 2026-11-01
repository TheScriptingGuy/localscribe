import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../models/recording.dart';
import '../services/library/recording_store.dart';
import 'format.dart';
import 'record_screen.dart';
import 'recording_detail_screen.dart';

/// The library: every recording on this phone, newest first.
class RecordingsScreen extends StatelessWidget {
  const RecordingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RecordingStore>();
    final items = store.all;

    return Scaffold(
      appBar: AppBar(
        title: const Text('LocalScribe'),
        actions: [
          IconButton(
            tooltip: 'Import audio file',
            icon: const Icon(Icons.file_open_outlined),
            onPressed: () => _import(context),
          ),
        ],
      ),
      body: items.isEmpty
          ? const _EmptyState()
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => _RecordingTile(recording: items[i]),
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const RecordScreen())),
        icon: const Icon(Icons.mic),
        label: const Text('Record'),
      ),
    );
  }

  Future<void> _import(BuildContext context) async {
    final store = context.read<RecordingStore>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    final picked = await FilePicker.pickFile(type: FileType.audio);
    final path = picked?.path;
    if (path == null) return;

    // Read the duration up front so the library list can show it.
    var durationMs = 0;
    final probe = AudioPlayer();
    try {
      durationMs = (await probe.setFilePath(path))?.inMilliseconds ?? 0;
    } catch (_) {
      // Unknown format for the player; still importable for transcription.
    } finally {
      await probe.dispose();
    }

    try {
      final rec = await store.add(
        File(path),
        title: p.basenameWithoutExtension(path),
        source: RecordingSource.import,
        durationMs: durationMs,
      );
      navigator.push(MaterialPageRoute(
          builder: (_) => RecordingDetailScreen(recordingId: rec.id)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }
}

class _RecordingTile extends StatelessWidget {
  final Recording recording;
  const _RecordingTile({required this.recording});

  @override
  Widget build(BuildContext context) {
    final r = recording;
    final badges = <String>[
      if (r.transcript != null) 'Transcript',
      if (r.notes.isNotEmpty)
        '${r.notes.length} note${r.notes.length == 1 ? '' : 's'}',
    ];
    return ListTile(
      leading: CircleAvatar(
        child: Icon(switch (r.source) {
          RecordingSource.mic => Icons.mic_none,
          RecordingSource.import => Icons.audio_file_outlined,
          RecordingSource.plaud => Icons.bluetooth_audio,
        }),
      ),
      title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        formatDate(r.createdAt),
        if (r.durationMs > 0) formatDuration(r.duration),
        ...badges,
      ].join(' · ')),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => RecordingDetailScreen(recordingId: r.id))),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.graphic_eq, size: 64, color: muted),
            const SizedBox(height: 16),
            const Text('No recordings yet', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'Tap Record to capture with the phone mic, or import an audio '
              'file from the top bar.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}
