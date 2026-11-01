import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../models/recording.dart';
import '../services/ai/ai_types.dart';
import '../services/library/recording_store.dart';
import '../services/transcription/transcription_jobs.dart';
import 'format.dart';
import 'options_screen.dart';
import 'recording_detail_screen.dart';
import 'theme.dart';

/// Picks an audio file, adds it to the library and opens it.
Future<void> importAudio(BuildContext context) async {
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

/// Top-bar button that opens Options, shared by the main pages.
class OptionsButton extends StatelessWidget {
  const OptionsButton({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: IconButton(
        tooltip: 'Options',
        style: IconButton.styleFrom(backgroundColor: Palette.fill),
        icon: const Icon(Icons.tune),
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const OptionsScreen())),
      ),
    );
  }
}

/// The library: every recording on this phone, newest first.
class RecordingsScreen extends StatelessWidget {
  const RecordingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RecordingStore>();
    final jobs = context.watch<TranscriptionJobs>();
    final items = store.all;

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        titleSpacing: 24,
        title: const Text('LocalScribe'),
        actions: const [OptionsButton()],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.only(bottom: 120),
        itemCount: items.length + 2,
        itemBuilder: (_, i) {
          if (i == 0) return const PageHeader('All files');
          if (i == 1) {
            return items.isEmpty
                ? const _EmptyState()
                : const Divider(height: 1, indent: 24, endIndent: 24);
          }
          final r = items[i - 2];
          return Column(
            children: [
              _RecordingRow(
                recording: r,
                transcribing:
                    jobs.isRunning(r.id) ? (jobs.progressOf(r.id) ?? 0) : null,
                phase: jobs.phaseOf(r.id)?.label,
              ),
              const Divider(height: 1, indent: 24, endIndent: 24),
            ],
          );
        },
      ),
    );
  }
}

class _RecordingRow extends StatelessWidget {
  final Recording recording;

  /// Transcription progress 0..1 while a job runs, else null.
  final double? transcribing;
  final String? phase;
  const _RecordingRow(
      {required this.recording, this.transcribing, this.phase});

  @override
  Widget build(BuildContext context) {
    final r = recording;
    const meta = TextStyle(color: Palette.muted, fontSize: 15);
    final t = transcribing;
    return InkWell(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => RecordingDetailScreen(recordingId: r.id))),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 22, 24, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(r.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 18, height: 1.35)),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(formatRelativeDate(r.createdAt), style: meta),
                if (r.durationMs > 0) ...[
                  const _MetaSeparator(),
                  Text(formatShortDuration(r.duration), style: meta),
                ],
              ],
            ),
            if (t != null || r.transcript != null || r.notes.isNotEmpty) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (t != null) ...[
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                    const SizedBox(width: 8),
                    Text('${phase ?? 'Transcribing'} ${(t * 100).floor()}%',
                        style: meta),
                  ] else ...[
                    if (r.transcript != null)
                      const _Badge(icon: Icons.subject, label: 'Transcript'),
                    if (_speakerCount(r) > 0)
                      _Badge(
                        icon: Icons.people_outline,
                        label: '${_speakerCount(r)} speakers',
                      ),
                    if (r.notes.isNotEmpty)
                      _Badge(
                        icon: Icons.edit_note,
                        label:
                            '${r.notes.length} note${r.notes.length == 1 ? '' : 's'}',
                      ),
                  ],
                  const Spacer(),
                  Icon(
                    switch (r.source) {
                      RecordingSource.mic => Icons.mic_none,
                      RecordingSource.import => Icons.audio_file_outlined,
                      RecordingSource.plaud => Icons.bluetooth_audio,
                    },
                    size: 18,
                    color: Palette.faint,
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Distinct speakers (by display name, so merged ones count once).
int _speakerCount(Recording r) => {
      for (final s in r.transcript?.segments ?? const <TranscriptSegment>[])
        if (s.speaker != null) r.speakerName(s.speaker!),
    }.length;

class _MetaSeparator extends StatelessWidget {
  const _MetaSeparator();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 14,
        margin: const EdgeInsets.symmetric(horizontal: 12),
        color: Palette.line,
      );
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final String label;
  const _Badge({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: Palette.muted),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(color: Palette.muted, fontSize: 13)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('No recordings yet', style: TextStyle(fontSize: 18)),
          SizedBox(height: 8),
          Text(
            'Tap + to record with the phone mic or import an audio file.',
            style: TextStyle(color: Palette.muted, fontSize: 15),
          ),
        ],
      ),
    );
  }
}
