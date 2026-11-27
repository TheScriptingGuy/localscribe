import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/recording.dart';
import '../../services/export/audio_export.dart';
import '../../services/export/export_types.dart';
import '../../services/export/notes_export.dart';
import '../../services/export/transcript_export.dart';
import '../../services/library/recording_store.dart';
import '../theme.dart';

/// Share / copy / export menu for one recording, like Plaud's share sheet.
/// [noteIndex] is the note currently shown, used for the Notes actions.
Future<void> showShareSheet(BuildContext context, Recording rec,
    {int noteIndex = 0}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ShareSheet(host: context, rec: rec, noteIndex: noteIndex),
  );
}


class PdfFontsCache {
  static Future<PdfFonts> load() async {
    try {
      final regular = pw.Font.ttf(
          await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'));
      final bold =
          pw.Font.ttf(await rootBundle.load('assets/fonts/NotoSans-Bold.ttf'));
      return PdfFonts(regular, bold);
    } catch (_) {
      return PdfFonts.fallback();
    }
  }
}

Future<PdfFonts>? _fonts;
Future<PdfFonts> _pdfFonts() => _fonts ??= PdfFontsCache.load();

enum _Kind { audio, transcript, notes }

class _ShareSheet extends StatelessWidget {
  final BuildContext host;
  final Recording rec;
  final int noteIndex;
  const _ShareSheet(
      {required this.host, required this.rec, required this.noteIndex});

  GeneratedNote? get _note => rec.notes.isEmpty
      ? null
      : rec.notes[math.min(math.max(noteIndex, 0), rec.notes.length - 1)];

  @override
  Widget build(BuildContext context) {
    final hasTranscript = rec.transcript != null;
    final note = _note;
    final maxHeight = MediaQuery.sizeOf(context).height * 0.9;

    void closeThen(void Function() action) {
      Navigator.pop(context);
      action();
    }

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 12),
          children: [
            _section(context, 'Share as text'),
            _tile(
              context,
              icon: Icons.subject,
              title: 'Transcript',
              enabled: hasTranscript,
              hint: 'Generate the transcript first',
              onTap: () => closeThen(() => _shareText(
                  transcriptToTxt(rec, const TranscriptExportOptions()))),
            ),
            _tile(
              context,
              icon: Icons.edit_note,
              title: 'Notes',
              enabled: note != null,
              hint: 'Generate notes first',
              onTap: () => closeThen(() => _shareText(note!.content)),
            ),
            _section(context, 'Copy to clipboard'),
            _tile(
              context,
              icon: Icons.copy_outlined,
              title: 'Transcript',
              enabled: hasTranscript,
              hint: 'Generate the transcript first',
              onTap: () => closeThen(() => _copy(
                  transcriptToTxt(rec, const TranscriptExportOptions()),
                  'Transcript copied')),
            ),
            _tile(
              context,
              icon: Icons.copy_outlined,
              title: 'Notes',
              enabled: note != null,
              hint: 'Generate notes first',
              onTap: () =>
                  closeThen(() => _copy(note!.content, 'Notes copied')),
            ),
            _section(context, 'Export as file'),
            _tile(
              context,
              icon: Icons.graphic_eq,
              title: 'Audio',
              onTap: () => closeThen(() => _openExport(_Kind.audio)),
            ),
            _tile(
              context,
              icon: Icons.subject,
              title: 'Transcript',
              enabled: hasTranscript,
              hint: 'Generate the transcript first',
              onTap: () => closeThen(() => _openExport(_Kind.transcript)),
            ),
            _tile(
              context,
              icon: Icons.edit_note,
              title: 'Notes',
              enabled: note != null,
              hint: 'Generate notes first',
              onTap: () => closeThen(() => _openExport(_Kind.notes)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String label) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
        child: Text(label,
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(fontWeight: FontWeight.w300)),
      );

  Widget _tile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
    bool enabled = true,
    String? hint,
  }) {
    final c = context.colors;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: Icon(icon, color: enabled ? c.text : c.faint),
      title: Text(title, style: TextStyle(color: enabled ? c.text : c.faint)),
      subtitle: !enabled && hint != null ? Text(hint) : null,
      trailing: Icon(Icons.chevron_right, color: enabled ? c.muted : c.faint),
      enabled: enabled,
      onTap: onTap,
    );
  }

  void _shareText(String text) {
    SharePlus.instance.share(ShareParams(text: text, subject: rec.title));
  }

  void _copy(String text, String message) {
    Clipboard.setData(ClipboardData(text: text));
    if (host.mounted) {
      ScaffoldMessenger.of(host)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _openExport(_Kind kind) {
    if (!host.mounted) return;
    showModalBottomSheet<void>(
      context: host,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _ExportSheet(host: host, rec: rec, kind: kind, noteIndex: noteIndex),
    );
  }
}

class _ExportSheet extends StatefulWidget {
  final BuildContext host;
  final Recording rec;
  final _Kind kind;
  final int noteIndex;
  const _ExportSheet(
      {required this.host,
      required this.rec,
      required this.kind,
      required this.noteIndex});

  @override
  State<_ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<_ExportSheet> {
  var _transcriptFormat = TranscriptFormat.txt;
  var _notesFormat = NotesFormat.pdf;
  var _audioFormat = AudioFormat.original;
  var _speakers = true;
  var _timestamps = true;
  late int _noteIdx;
  var _busy = false;
  String? _error;

  Recording get rec => widget.rec;

  @override
  void initState() {
    super.initState();
    _noteIdx = rec.notes.isEmpty
        ? 0
        : math.min(math.max(widget.noteIndex, 0), rec.notes.length - 1);
  }

  Future<ExportFile> _build() async {
    switch (widget.kind) {
      case _Kind.audio:
        return exportAudio(context.read<RecordingStore>(), rec, _audioFormat);
      case _Kind.transcript:
        return exportTranscript(
          rec,
          _transcriptFormat,
          TranscriptExportOptions(speakers: _speakers, timestamps: _timestamps),
          fonts: _transcriptFormat == TranscriptFormat.pdf
              ? await _pdfFonts()
              : null,
        );
      case _Kind.notes:
        return exportNote(
          rec,
          rec.notes[_noteIdx],
          _notesFormat,
          fonts:
              _notesFormat == NotesFormat.pdf ? await _pdfFonts() : null,
        );
    }
  }

  Future<void> _run({required bool save}) async {
    final host = widget.host;
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final file = await _build();
      if (save) {
        final uri = await FilePicker.saveFile(
          fileName: file.name,
          bytes: file.bytes,
          mimeType: file.mime,
          dialogTitle: 'Save to phone',
        );
        if (uri == null) {
          if (mounted) setState(() => _busy = false);
          return; // dialog cancelled
        }
        navigator.pop();
        if (host.mounted) {
          ScaffoldMessenger.of(host).showSnackBar(
              SnackBar(content: Text('Saved ${file.name}')));
        }
      } else {
        final tmp = await getTemporaryDirectory();
        final path = p.join(tmp.path, file.name);
        await File(path).writeAsBytes(file.bytes, flush: true);
        navigator.pop();
        await SharePlus.instance.share(ShareParams(
          files: [XFile(path, mimeType: file.mime, name: file.name)],
          subject: rec.title,
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Export failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final title = switch (widget.kind) {
      _Kind.audio => 'Export audio',
      _Kind.transcript => 'Export transcript',
      _Kind.notes => 'Export notes',
    };
    final originalExt =
        p.extension(rec.audioFile).replaceFirst('.', '').toUpperCase();

    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
            24, 0, 24, 16 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: Theme.of(context)
                    .textTheme
                    .headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w300)),
            const SizedBox(height: 20),
            Text('Format', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: switch (widget.kind) {
                _Kind.audio => [
                    _chip('Original ($originalExt)',
                        _audioFormat == AudioFormat.original,
                        () => setState(() => _audioFormat = AudioFormat.original)),
                    _chip('WAV', _audioFormat == AudioFormat.wav,
                        () => setState(() => _audioFormat = AudioFormat.wav)),
                  ],
                _Kind.transcript => [
                    for (final f in TranscriptFormat.values)
                      _chip(f.label, _transcriptFormat == f,
                          () => setState(() => _transcriptFormat = f)),
                  ],
                _Kind.notes => [
                    for (final f in NotesFormat.values)
                      _chip(f.label, _notesFormat == f,
                          () => setState(() => _notesFormat = f)),
                  ],
              },
            ),
            if (widget.kind == _Kind.audio && _audioFormat == AudioFormat.wav)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    'WAV is converted to 16 kHz mono, the quality used for transcription.',
                    style: TextStyle(color: c.muted, fontSize: 13)),
              ),
            if (widget.kind == _Kind.notes && rec.notes.length > 1) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: _noteIdx,
                decoration: const InputDecoration(labelText: 'Note'),
                items: [
                  for (var i = 0; i < rec.notes.length; i++)
                    DropdownMenuItem(
                        value: i, child: Text(rec.notes[i].templateName)),
                ],
                onChanged: (v) => setState(() => _noteIdx = v ?? 0),
              ),
            ],
            if (widget.kind == _Kind.transcript) ...[
              const SizedBox(height: 8),
              if (rec.transcript?.hasSpeakers == true)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include speaker names'),
                  value: _speakers,
                  onChanged: (v) => setState(() => _speakers = v),
                ),
              if (_transcriptFormat != TranscriptFormat.srt)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Include timestamps'),
                  value: _timestamps,
                  onChanged: (v) => setState(() => _timestamps = v),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: c.danger)),
            ],
            const SizedBox(height: 20),
            if (_busy)
              const Center(
                  child: Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(),
              ))
            else
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _run(save: false),
                      child: const Text('Share'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => _run(save: true),
                      child: const Text('Save to phone'),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) => ChoiceChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => onTap(),
      );
}
