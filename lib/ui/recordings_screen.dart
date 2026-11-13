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
        style: IconButton.styleFrom(backgroundColor: context.colors.fill),
        icon: const Icon(Icons.tune),
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const OptionsScreen())),
      ),
    );
  }
}

/// The library: every recording on this phone, newest first, searchable.
class RecordingsScreen extends StatefulWidget {
  const RecordingsScreen({super.key});

  @override
  State<RecordingsScreen> createState() => _RecordingsScreenState();
}

class _RecordingsScreenState extends State<RecordingsScreen> {
  final _search = TextEditingController();
  RecordingSource? _source; // null = all

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(Recording r, String q) {
    if (q.isEmpty) return true;
    if (r.title.toLowerCase().contains(q)) return true;
    if (r.transcript?.text.toLowerCase().contains(q) == true) return true;
    return r.notes.any((n) => n.content.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RecordingStore>();
    final jobs = context.watch<TranscriptionJobs>();
    final q = _search.text.trim().toLowerCase();
    final all = store.all;
    final items = all
        .where((r) => _source == null || r.source == _source)
        .where((r) => _matches(r, q))
        .toList();
    final filtering = q.isNotEmpty || _source != null;

    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        titleSpacing: 24,
        title: const Text('LocalScribe'),
        actions: const [OptionsButton()],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.only(bottom: 120),
        itemCount: items.length + 4,
        itemBuilder: (_, i) {
          if (i == 0) return const PageHeader('All files');
          if (i == 1) {
            if (all.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search titles, transcripts and notes',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: q.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(_search.clear),
                        ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            );
          }
          if (i == 2) {
            if (all.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _filterChip('All', null),
                  _filterChip('Phone', RecordingSource.mic),
                  _filterChip('Imported', RecordingSource.import),
                  _filterChip('Plaud', RecordingSource.plaud),
                ],
              ),
            );
          }
          if (i == 3) {
            if (all.isEmpty) return const _EmptyState();
            if (items.isEmpty && filtering) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                child: Text('No recordings match.',
                    style: TextStyle(color: context.colors.muted)),
              );
            }
            return const Divider(height: 1, indent: 24, endIndent: 24);
          }
          final r = items[i - 4];
          return Column(
            children: [
              _RecordingRow(
                recording: r,
                transcribing:
                    jobs.isRunning(r.id) ? (jobs.progressOf(r.id) ?? 0) : null,
                phase: jobs.phaseOf(r.id)?.label,
                preview: _preview(r),
              ),
              const Divider(height: 1, indent: 24, endIndent: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _filterChip(String label, RecordingSource? source) => ChoiceChip(
        label: Text(label),
        selected: _source == source,
        showCheckmark: false,
        onSelected: (_) => setState(() => _source = source),
      );

  /// One line of what the recording says: the newest note's first text line,
  /// else the start of the transcript.
  static String? _preview(Recording r) {
    for (final n in r.notes) {
      for (final line in n.content.split('\n')) {
        final t = line.trim();
        if (t.isEmpty || t.startsWith('#')) continue;
        return t.replaceAll('*', '').replaceAll('`', '');
      }
    }
    final text = r.transcript?.text.trim() ?? '';
    return text.isEmpty ? null : text;
  }
}

class _RecordingRow extends StatelessWidget {
  final Recording recording;

  /// Transcription progress 0..1 while a job runs, else null.
  final double? transcribing;
  final String? phase;
  final String? preview;
  const _RecordingRow(
      {required this.recording, this.transcribing, this.phase, this.preview});

  @override
  Widget build(BuildContext context) {
    final r = recording;
    final meta = TextStyle(color: context.colors.muted, fontSize: 15);
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
            if (preview != null && t == null) ...[
              const SizedBox(height: 8),
              Text(preview!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: context.colors.muted, fontSize: 14, height: 1.3)),
            ],
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
                        label: _speakerCount(r) == 1
                            ? '1 speaker'
                            : '${_speakerCount(r)} speakers',
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
                    color: context.colors.faint,
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
        color: context.colors.line,
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
          Icon(icon, size: 18, color: context.colors.muted),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(color: context.colors.muted, fontSize: 13)),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('No recordings yet', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 8),
          Text(
            'Tap + to record with the phone mic or import an audio file.',
            style: TextStyle(color: context.colors.muted, fontSize: 15),
          ),
        ],
      ),
    );
  }
}
