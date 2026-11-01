import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/recording.dart';
import '../services/ai/ai_factory.dart';
import '../services/ai/ai_types.dart';
import '../services/library/recording_store.dart';
import '../services/notes/auto_template.dart';
import '../services/templates/prompt_builder.dart';
import '../services/templates/template_repository.dart';
import '../settings/settings.dart';
import 'format.dart';

const _autoChoice = '__auto__';

/// One recording: playback, transcript, generated notes and Ask-AI chat.
class RecordingDetailScreen extends StatefulWidget {
  final String recordingId;
  const RecordingDetailScreen({super.key, required this.recordingId});

  @override
  State<RecordingDetailScreen> createState() => _RecordingDetailScreenState();
}

class _RecordingDetailScreenState extends State<RecordingDetailScreen> {
  final _player = AudioPlayer();
  bool _transcribing = false;
  bool _generating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final store = context.read<RecordingStore>();
    final rec = store.byId(widget.recordingId);
    if (rec != null) {
      _player.setFilePath(store.audioOf(rec).path).catchError((_) => null);
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  // --- actions -------------------------------------------------------------

  Future<void> _transcribe(Recording rec) async {
    final settings = context.read<Settings>();
    final store = context.read<RecordingStore>();
    setState(() {
      _transcribing = true;
      _error = null;
    });
    try {
      final transcriber = AiFactory.transcriber(settings.transcription);
      rec.transcript = await transcriber.transcribe(store.audioOf(rec));
      await store.save(rec);
    } on AiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _transcribing = false);
    }
  }

  Future<void> _generate(Recording rec, String choice) async {
    final settings = context.read<Settings>();
    final store = context.read<RecordingStore>();
    final templates = context.read<TemplateRepository>();
    final transcript = rec.transcript?.text ?? '';
    if (transcript.isEmpty) {
      setState(() => _error = 'Transcribe the recording first.');
      return;
    }
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final gen = AiFactory.noteGenerator(settings.noteAi);
      final auto = choice == _autoChoice;
      final template = auto
          ? await AutoTemplatePicker.pick(
              generator: gen, templates: templates.all, transcript: transcript)
          : templates.byId(choice);
      if (template == null) throw AiException('Template not found: $choice');

      final content = await gen.complete(PromptBuilder.forNote(
        template: template,
        transcript: transcript,
        languageHint: settings.noteLanguage,
      ));
      rec.notes.insert(
        0,
        GeneratedNote(
          id: const Uuid().v4(),
          templateId: template.id,
          templateName: template.name,
          content: content.trim(),
          createdAt: DateTime.now(),
          auto: auto,
        ),
      );
      // Adopt the note's title for recordings that still have a default name.
      if (rec.title.startsWith('Recording ')) {
        final heading = RegExp(r'^#\s+(.+)$', multiLine: true)
            .firstMatch(content)
            ?.group(1)
            ?.trim();
        if (heading != null && heading.isNotEmpty) rec.title = heading;
      }
      await store.save(rec);
    } on AiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _rename(Recording rec) async {
    final store = context.read<RecordingStore>();
    final ctrl = TextEditingController(text: rec.title);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    rec.title = name;
    await store.save(rec);
  }

  Future<void> _delete(Recording rec) async {
    final store = context.read<RecordingStore>();
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete recording?'),
        content: const Text(
            'The audio, transcript, notes and chat are removed from this phone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _player.stop();
    await store.delete(rec);
    navigator.pop();
  }

  Future<void> _pickTemplate(Recording rec) async {
    final templates = context.read<TemplateRepository>();
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Auto'),
              subtitle: const Text('Let the AI pick the best template'),
              onTap: () => Navigator.pop(ctx, _autoChoice),
            ),
            const Divider(),
            ...templates.all.map((t) => ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(t.name),
                  subtitle: Text(t.description,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.pop(ctx, t.id),
                )),
          ],
        ),
      ),
    );
    if (choice != null) await _generate(rec, choice);
  }

  // --- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RecordingStore>();
    final rec = store.byId(widget.recordingId);
    if (rec == null) {
      return const Scaffold(body: Center(child: Text('Recording not found')));
    }

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(rec.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            PopupMenuButton<String>(
              onSelected: (v) => switch (v) {
                'rename' => _rename(rec),
                'retranscribe' => _transcribe(rec),
                'delete' => _delete(rec),
                _ => null,
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                if (rec.transcript != null)
                  const PopupMenuItem(
                      value: 'retranscribe', child: Text('Transcribe again')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
          bottom: const TabBar(tabs: [
            Tab(text: 'Transcript'),
            Tab(text: 'Notes'),
            Tab(text: 'Ask AI'),
          ]),
        ),
        body: Column(
          children: [
            _PlayerBar(player: _player),
            if (_error != null)
              MaterialBanner(
                content: Text(_error!),
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
                actions: [
                  TextButton(
                      onPressed: () => setState(() => _error = null),
                      child: const Text('Dismiss')),
                ],
              ),
            Expanded(
              child: TabBarView(children: [
                _transcriptTab(rec),
                _notesTab(rec),
                _ChatTab(recording: rec),
              ]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _transcriptTab(Recording rec) {
    final t = rec.transcript;
    if (_transcribing) {
      return const _Busy(label: 'Transcribing…');
    }
    if (t == null) {
      final settings = context.read<Settings>();
      return _CallToAction(
        icon: Icons.subtitles_outlined,
        text: settings.transcription.onDevice
            ? 'On-device transcription arrives in Phase 3. Switch Transcription '
                'AI to a custom API URL in Options for now.'
            : 'Send the audio to your configured Whisper endpoint.',
        button: FilledButton.icon(
          onPressed: () => _transcribe(rec),
          icon: const Icon(Icons.subtitles),
          label: const Text('Transcribe'),
        ),
      );
    }
    if (t.segments.isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(t.text),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: t.segments.length,
      itemBuilder: (_, i) {
        final s = t.segments[i];
        return ListTile(
          dense: true,
          leading: Text(formatSeconds(s.start),
              style: TextStyle(color: Theme.of(context).colorScheme.primary)),
          title: Text(s.text),
          onTap: () {
            _player.seek(Duration(milliseconds: (s.start * 1000).round()));
            _player.play();
          },
        );
      },
    );
  }

  Widget _notesTab(Recording rec) {
    if (rec.transcript == null) {
      return const _CallToAction(
        icon: Icons.description_outlined,
        text: 'Transcribe the recording first, then generate notes from any '
            'template.',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FilledButton.icon(
          onPressed: _generating ? null : () => _pickTemplate(rec),
          icon: _generating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.auto_awesome),
          label: Text(_generating ? 'Generating…' : 'Generate note'),
        ),
        const SizedBox(height: 16),
        ...rec.notes.map((n) => _NoteCard(
              note: n,
              onDelete: () async {
                rec.notes.removeWhere((e) => e.id == n.id);
                await context.read<RecordingStore>().save(rec);
              },
            )),
      ],
    );
  }
}

class _PlayerBar extends StatelessWidget {
  final AudioPlayer player;
  const _PlayerBar({required this.player});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 4),
      child: Row(
        children: [
          StreamBuilder<PlayerState>(
            stream: player.playerStateStream,
            builder: (_, snap) {
              final playing = snap.data?.playing ?? false;
              final done =
                  snap.data?.processingState == ProcessingState.completed;
              return IconButton(
                icon: Icon(playing && !done ? Icons.pause : Icons.play_arrow),
                onPressed: () async {
                  if (done) await player.seek(Duration.zero);
                  playing && !done ? player.pause() : player.play();
                },
              );
            },
          ),
          Expanded(
            child: StreamBuilder<Duration>(
              stream: player.positionStream,
              builder: (_, snap) {
                final pos = snap.data ?? Duration.zero;
                final total = player.duration ?? Duration.zero;
                final max = total.inMilliseconds.toDouble();
                return Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: max <= 0
                            ? 0
                            : pos.inMilliseconds.toDouble().clamp(0, max),
                        max: max <= 0 ? 1 : max,
                        onChanged: max <= 0
                            ? null
                            : (v) => player
                                .seek(Duration(milliseconds: v.round())),
                      ),
                    ),
                    Text('${formatDuration(pos)} / ${formatDuration(total)}',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _NoteCard extends StatelessWidget {
  final GeneratedNote note;
  final VoidCallback onDelete;
  const _NoteCard({required this.note, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    note.auto
                        ? '${note.templateName} · Auto'
                        : note.templateName,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Copy',
                  icon: const Icon(Icons.copy, size: 20),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: note.content));
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Note copied')));
                  },
                ),
                IconButton(
                  tooltip: 'Delete',
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: onDelete,
                ),
              ],
            ),
            Text(formatDate(note.createdAt),
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            SelectableText(note.content),
          ],
        ),
      ),
    );
  }
}

/// Ask-AI: questions answered strictly from this recording's transcript.
class _ChatTab extends StatefulWidget {
  final Recording recording;
  const _ChatTab({required this.recording});

  @override
  State<_ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<_ChatTab> {
  /// Turns of history sent with each question, to bound prompt size.
  static const _historyTurns = 20;

  final _input = TextEditingController();
  String? _pending;
  String? _error;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final rec = widget.recording;
    final question = _input.text.trim();
    if (question.isEmpty || _pending != null) return;
    final settings = context.read<Settings>();
    final store = context.read<RecordingStore>();

    final history = rec.chat.length > _historyTurns
        ? rec.chat.sublist(rec.chat.length - _historyTurns)
        : List<ChatMessage>.from(rec.chat);
    _input.clear();
    setState(() {
      rec.chat.add(ChatMessage(ChatRole.user, question));
      _pending = '';
      _error = null;
    });

    final answer = StringBuffer();
    try {
      final gen = AiFactory.noteGenerator(settings.noteAi);
      final messages = PromptBuilder.forChat(
        transcript: rec.transcript!.text,
        history: history,
        question: question,
      );
      await for (final chunk in gen.stream(messages)) {
        answer.write(chunk);
        if (mounted) setState(() => _pending = answer.toString());
      }
      rec.chat.add(ChatMessage(ChatRole.assistant, answer.toString().trim()));
    } on AiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = e.toString();
    } finally {
      await store.save(rec);
      if (mounted) setState(() => _pending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rec = widget.recording;
    if (rec.transcript == null) {
      return const _CallToAction(
        icon: Icons.forum_outlined,
        text: 'Transcribe the recording first, then ask questions about it.',
      );
    }
    final bubbles = [
      ...rec.chat.map((m) => _Bubble(
          text: m.content, mine: m.role == ChatRole.user)),
      if (_pending != null)
        _Bubble(text: _pending!.isEmpty ? '…' : _pending!, mine: false),
    ];
    return Column(
      children: [
        Expanded(
          child: bubbles.isEmpty
              ? const _CallToAction(
                  icon: Icons.forum_outlined,
                  text: 'Ask anything about this recording — e.g. "What did '
                      'we decide?" or "List the action items."',
                )
              : ListView(
                  reverse: true,
                  padding: const EdgeInsets.all(12),
                  children: bubbles.reversed.toList(),
                ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(_error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: 'Ask about this recording…',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _pending == null ? _send : null,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Bubble extends StatelessWidget {
  final String text;
  final bool mine;
  const _Bubble({required this.text, required this.mine});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
        decoration: BoxDecoration(
          color: mine ? scheme.primaryContainer : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(text),
      ),
    );
  }
}

class _Busy extends StatelessWidget {
  final String label;
  const _Busy({required this.label});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(label),
          ],
        ),
      );
}

class _CallToAction extends StatelessWidget {
  final IconData icon;
  final String text;
  final Widget? button;
  const _CallToAction({required this.icon, required this.text, this.button});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: muted),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: TextStyle(color: muted)),
            if (button != null) ...[const SizedBox(height: 16), button!],
          ],
        ),
      ),
    );
  }
}
