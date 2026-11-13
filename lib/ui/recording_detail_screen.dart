import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:provider/provider.dart';

import '../models/recording.dart';
import '../services/ai/ai_factory.dart';
import '../services/ai/ai_types.dart';
import '../services/library/recording_store.dart';
import '../services/models/llm_models.dart';
import '../services/notes/note_jobs.dart';
import '../services/templates/prompt_builder.dart';
import '../services/transcription/transcription_jobs.dart';
import '../services/transcription/transcriber.dart' show CancelSignal;
import '../settings/settings.dart';
import '../services/export/transcript_paragraphs.dart';
import 'detail/marker_list.dart';
import 'detail/share_sheet.dart';
import 'format.dart';
import 'markdown_view.dart';
import 'template_picker.dart';
import 'theme.dart';

/// One recording: playback, transcript, generated notes and Ask-AI chat.
class RecordingDetailScreen extends StatefulWidget {
  final String recordingId;
  const RecordingDetailScreen({super.key, required this.recordingId});

  @override
  State<RecordingDetailScreen> createState() => _RecordingDetailScreenState();
}

class _RecordingDetailScreenState extends State<RecordingDetailScreen> {
  final _player = AudioPlayer();
  String? _error;

  /// Which generated note the Notes tab shows (index into rec.notes).
  int _noteIndex = 0;

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

  Future<void> _transcribe(Recording rec) {
    setState(() => _error = null);
    return context.read<TranscriptionJobs>().start(rec);
  }

  void _generate(Recording rec, String choice) {
    setState(() {
      _error = null;
      _noteIndex = 0; // the new note goes first
    });
    context.read<NoteJobs>().generate(rec, choice);
  }

  void _copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$what copied')));
  }

  Future<void> _deleteNote(Recording rec, GeneratedNote note) async {
    final store = context.read<RecordingStore>();
    setState(() {
      rec.notes.removeWhere((e) => e.id == note.id);
      _noteIndex = 0;
    });
    await store.save(rec);
  }

  /// Names a recognised speaker everywhere in this recording. Picking another
  /// speaker's name merges the two.
  Future<void> _renameSpeaker(Recording rec, String id) async {
    final store = context.read<RecordingStore>();
    final ctrl = TextEditingController(text: rec.speakerNames[id] ?? '');
    final current = rec.speakerName(id);
    final others = {
      for (final s in rec.transcript?.segments ?? const <TranscriptSegment>[])
        if (s.speaker != null) rec.speakerName(s.speaker!),
    }.where((n) => n != current).toList();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rename $current'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(hintText: 'Name, e.g. Anna'),
              onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
            ),
            if (others.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Or the same person as:',
                  style: TextStyle(color: context.colors.muted)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final o in others)
                    ActionChip(
                        label: Text(o), onPressed: () => Navigator.pop(ctx, o)),
                ],
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    if (name == null) return;
    setState(() {
      if (name.isEmpty) {
        rec.speakerNames.remove(id);
      } else {
        rec.speakerNames[id] = name;
      }
    });
    await store.save(rec);
  }

  void _openChat(Recording rec) => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => _ChatScreen(recordingId: rec.id)));

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
    final choice = await pickTemplate(context);
    if (choice != null && mounted) _generate(rec, choice);
  }

  // --- UI ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final store = context.watch<RecordingStore>();
    final jobs = context.watch<TranscriptionJobs>();
    final notes = context.watch<NoteJobs>();
    final rec = store.byId(widget.recordingId);
    if (rec == null) {
      return const Scaffold(body: Center(child: Text('Recording not found')));
    }
    final error = _error ?? jobs.errorOf(rec.id) ?? notes.errorOf(rec.id);
    final transcript = rec.transcript;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const TabBar(
            isScrollable: true,
            labelPadding: EdgeInsets.symmetric(horizontal: 12),
            tabs: [Tab(text: 'Transcript'), Tab(text: 'Notes')],
          ),
          actions: [
            IconButton(
              tooltip: 'Share & export',
              icon: const Icon(Icons.ios_share),
              onPressed: () =>
                  showShareSheet(context, rec, noteIndex: _noteIndex),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz),
              onSelected: (v) {
                switch (v) {
                  case 'rename':
                    _rename(rec);
                  case 'retranscribe':
                    _transcribe(rec);
                  case 'speakers':
                    setState(() => _error = null);
                    jobs.identifySpeakers(rec);
                  case 'delete':
                    _delete(rec);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
                if (transcript != null && !jobs.isRunning(rec.id)) ...[
                  const PopupMenuItem(
                      value: 'retranscribe', child: Text('Transcribe again')),
                  PopupMenuItem(
                      value: 'speakers',
                      child: Text(transcript.hasSpeakers
                          ? 'Identify speakers again'
                          : 'Identify speakers')),
                ],
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: Column(
          children: [
            if (error != null)
              MaterialBanner(
                content: Text(error),
                backgroundColor: Theme.of(context).colorScheme.errorContainer,
                actions: [
                  TextButton(
                      onPressed: () {
                        jobs.clearError(rec.id);
                        notes.clearError(rec.id);
                        setState(() => _error = null);
                      },
                      child: const Text('Dismiss')),
                ],
              ),
            Expanded(
              child: TabBarView(children: [
                _transcriptTab(rec, jobs),
                _notesTab(rec, notes),
              ]),
            ),
            if (transcript != null) _AskBar(onTap: () => _openChat(rec)),
          ],
        ),
      ),
    );
  }

  Widget _transcriptTab(Recording rec, TranscriptionJobs jobs) {
    final t = rec.transcript;
    final Widget content;
    if (jobs.isRunning(rec.id)) {
      content = _TranscribeProgress(
        label: jobs.phaseOf(rec.id)?.label ?? 'Transcribing',
        progress: jobs.progressOf(rec.id),
        onCancel: () => jobs.cancel(rec.id),
      );
    } else if (t == null) {
      final settings = context.read<Settings>();
      content = _CallToAction(
        padding: const EdgeInsets.symmetric(vertical: 12),
        text: settings.transcription.onDevice
            ? 'Transcribe on this phone with whisper.cpp. The audio never '
                'leaves the device.'
            : 'Send the audio to your configured Whisper endpoint.',
        button: FilledButton(
          onPressed: () => _transcribe(rec),
          child: const Text('Transcribe'),
        ),
      );
    } else if (t.segments.isEmpty) {
      content = SelectableText(t.text,
          style: Theme.of(context).textTheme.bodyLarge);
    } else {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final para in _paragraphs(rec, t.segments))
            _TranscriptParagraph(
              start: para.first.start,
              speaker: para.first.speaker == null
                  ? null
                  : rec.speakerName(para.first.speaker!),
              onSpeakerTap: para.first.speaker == null
                  ? null
                  : () => _renameSpeaker(rec, para.first.speaker!),
              text: para.map((s) => s.text.trim()).join(' '),
              onTap: () {
                _player.seek(
                    Duration(milliseconds: (para.first.start * 1000).round()));
                _player.play();
              },
            ),
        ],
      );
    }

    final language = t?.language;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      children: [
        Text(rec.title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(
          [
            formatRelativeDate(rec.createdAt),
            if (rec.durationMs > 0) formatShortDuration(rec.duration),
            if (language != null && language.isNotEmpty)
              language.toUpperCase(),
          ].join('  |  '),
          style: TextStyle(color: context.colors.muted, fontSize: 15),
        ),
        const SizedBox(height: 20),
        const Divider(height: 1),
        _PlayerBar(player: _player, fallbackDuration: rec.duration),
        const Divider(height: 1),
        MarkerList(
          rec: rec,
          onSeek: (m) {
            _player.seek(Duration(milliseconds: m.atMs));
            _player.play();
          },
        ),
        const SizedBox(height: 12),
        content,
      ],
    );
  }

  /// Groups segments into readable paragraphs: break when the speaker
  /// changes, on a pause of 2 s+, or once a paragraph is long and the last
  /// segment ends a sentence.
  static List<List<TranscriptSegment>> _paragraphs(
          Recording rec, List<TranscriptSegment> segments) =>
      groupTranscriptParagraphs(rec, segments);

  Widget _notesTab(Recording rec, NoteJobs notes) {
    if (rec.transcript == null) {
      return const _CallToAction(
        text: 'Transcribe the recording first, then generate notes from any '
            'template.',
      );
    }
    final generating = notes.isRunning(rec.id);
    final progress = generating
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: _TranscribeProgress(
              label: 'Writing note',
              progress: notes.progressOf(rec.id),
              onCancel: () => notes.cancel(rec.id),
            ),
          )
        : null;
    if (rec.notes.isEmpty) {
      return progress != null
          ? ListView(children: [progress])
          : _CallToAction(
              text: 'Turn the transcript into a summary, meeting minutes or '
                  'any other template.',
              button: FilledButton.icon(
                onPressed: () => _pickTemplate(rec),
                icon: const Icon(Icons.auto_awesome, size: 20),
                label: const Text('Generate note'),
              ),
            );
    }

    final index = _noteIndex < rec.notes.length ? _noteIndex : 0;
    final note = rec.notes[index];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 56,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            children: [
              for (var i = 0; i < rec.notes.length; i++)
                _NoteTab(
                  label: rec.notes[i].templateName,
                  selected: i == index,
                  onTap: () => setState(() => _noteIndex = i),
                ),
              Center(
                child: Material(
                  color: context.colors.fill,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: generating ? null : () => _pickTemplate(rec),
                    child: SizedBox(
                      width: 48,
                      height: 32,
                      child: generating
                          ? const Center(
                              child: SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)))
                          : const Icon(Icons.add, size: 22),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (progress != null) progress,
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            children: [
              MarkdownView(note.content),
              const SizedBox(height: 16),
              const Divider(height: 1),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      (note.auto ? 'Auto · ' : '') +
                          formatRelativeDate(note.createdAt),
                      style: TextStyle(color: context.colors.muted),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy_outlined, size: 20),
                    onPressed: () => _copy(note.content, 'Note'),
                  ),
                  IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => _deleteNote(rec, note),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NoteTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _NoteTab(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 17,
              color: selected ? context.colors.text : context.colors.muted,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _TranscriptParagraph extends StatelessWidget {
  final double start;
  final String? speaker;
  final VoidCallback? onSpeakerTap;
  final String text;
  final VoidCallback onTap;
  const _TranscriptParagraph({
    required this.start,
    required this.text,
    required this.onTap,
    this.speaker,
    this.onSpeakerTap,
  });

  @override
  Widget build(BuildContext context) {
    final name = speaker;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  formatSeconds(start),
                  style: TextStyle(
                    color: context.colors.muted,
                    fontSize: 14,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (name != null) ...[
                  const SizedBox(width: 16),
                  InkWell(
                    onTap: onSpeakerTap,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        name,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(text, style: Theme.of(context).textTheme.bodyLarge),
          ],
        ),
      ),
    );
  }
}

/// Bottom entry point to the Ask-AI chat, outlined with the AI gradient.
class _AskBar extends StatelessWidget {
  final VoidCallback onTap;
  const _AskBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
        child: GradientBorder(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome,
                      size: 20, color: context.colors.muted),
                  const SizedBox(width: 12),
                  Text('Ask AI about this recording',
                      style: TextStyle(
                          color: context.colors.muted, fontSize: 16)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayerBar extends StatelessWidget {
  final AudioPlayer player;

  /// Shown until the player has loaded the file and knows the real length.
  final Duration fallbackDuration;
  const _PlayerBar({required this.player, required this.fallbackDuration});

  static const _speeds = [1.0, 1.25, 1.5, 2.0, 0.75];

  Future<void> _skip(Duration by) async {
    final total = player.duration ?? fallbackDuration;
    var to = player.position + by;
    if (to < Duration.zero) to = Duration.zero;
    if (to > total) to = total;
    await player.seek(to);
  }

  static String _speedLabel(double v) =>
      v == v.roundToDouble() ? '${v.toInt()}×' : '$v×';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Column(children: [
        _mainRow(context),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              tooltip: 'Back 10 seconds',
              icon: const Icon(Icons.replay_10),
              onPressed: () => _skip(const Duration(seconds: -10)),
            ),
            const SizedBox(width: 16),
            IconButton(
              tooltip: 'Forward 10 seconds',
              icon: const Icon(Icons.forward_10),
              onPressed: () => _skip(const Duration(seconds: 10)),
            ),
            const SizedBox(width: 16),
            StreamBuilder<double>(
              stream: player.speedStream,
              initialData: player.speed,
              builder: (_, snap) {
                final speed = snap.data ?? 1.0;
                return TextButton(
                  onPressed: () {
                    final i = _speeds.indexOf(speed);
                    player.setSpeed(_speeds[(i + 1) % _speeds.length]);
                  },
                  child: Text('Speed ${_speedLabel(speed)}'),
                );
              },
            ),
          ],
        ),
      ]),
    );
  }

  Widget _mainRow(BuildContext context) {
    return Row(
        children: [
          StreamBuilder<PlayerState>(
            stream: player.playerStateStream,
            builder: (_, snap) {
              final playing = snap.data?.playing ?? false;
              final done =
                  snap.data?.processingState == ProcessingState.completed;
              return IconButton(
                style: IconButton.styleFrom(
                  backgroundColor: context.colors.fill,
                  fixedSize: const Size(56, 56),
                ),
                iconSize: 30,
                icon: Icon(playing && !done
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded),
                onPressed: () async {
                  if (done) await player.seek(Duration.zero);
                  playing && !done ? player.pause() : player.play();
                },
              );
            },
          ),
          const SizedBox(width: 4),
          Expanded(
            child: StreamBuilder<Duration?>(
              stream: player.durationStream,
              builder: (_, durationSnap) => StreamBuilder<Duration>(
                stream: player.positionStream,
                builder: (_, snap) => _progress(
                  snap.data ?? Duration.zero,
                  durationSnap.data ?? player.duration,
                ),
              ),
            ),
          ),
        ],
    );
  }

  /// Seek bar and "position / length"; [loaded] is null until the file loads.
  Widget _progress(Duration pos, Duration? loaded) {
    final total = loaded ?? fallbackDuration;
    final max = total.inMilliseconds.toDouble();
    return Row(
      children: [
        Expanded(
          child: Slider(
            value: max <= 0 ? 0 : pos.inMilliseconds.toDouble().clamp(0, max),
            max: max <= 0 ? 1 : max,
            onChanged: max <= 0 || loaded == null
                ? null
                : (v) => player.seek(Duration(milliseconds: v.round())),
          ),
        ),
        Text(
          '${formatDuration(pos)} / ${formatDuration(total)}',
          style: const TextStyle(
            fontSize: 15,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// Ask-AI: questions answered strictly from this recording's transcript.
class _ChatScreen extends StatefulWidget {
  final String recordingId;
  const _ChatScreen({required this.recordingId});

  @override
  State<_ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<_ChatScreen> {
  /// Turns of history sent with each question, to bound prompt size.
  static const _historyTurns = 20;

  final _input = TextEditingController();
  String? _pending;
  String? _error;

  /// The on-device model reading the transcript before it answers, 0–1.
  double? _reading;
  CancelSignal? _cancel;

  @override
  void dispose() {
    _cancel?.cancel();
    _input.dispose();
    super.dispose();
  }

  Future<void> _send(Recording rec) async {
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
      _reading = null;
      _error = null;
      _cancel = CancelSignal();
    });

    final answer = StringBuffer();
    try {
      final gen = AiFactory.noteGenerator(settings.noteAi,
          models: context.read<LlmModelManager>());
      final messages = PromptBuilder.forChat(
        transcript: rec.transcriptForAi,
        history: history,
        question: question,
      );
      await for (final chunk in gen.stream(messages,
          cancel: _cancel,
          onProgress: (p) {
            if (mounted && answer.isEmpty) setState(() => _reading = p);
          })) {
        answer.write(chunk);
        if (mounted) setState(() => _pending = answer.toString());
      }
      rec.chat.add(ChatMessage(ChatRole.assistant, answer.toString().trim()));
    } on AiException catch (e) {
      if (!e.cancelled) _error = e.message;
    } catch (e) {
      _error = e.toString();
    } finally {
      await store.save(rec);
      _cancel = null;
      if (mounted) setState(() => _pending = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rec = context.watch<RecordingStore>().byId(widget.recordingId);
    if (rec == null || rec.transcript == null) {
      return const Scaffold(body: Center(child: Text('Recording not found')));
    }
    final bubbles = [
      ...rec.chat.map(
          (m) => _Bubble(text: m.content, mine: m.role == ChatRole.user)),
      if (_pending != null)
        _Bubble(
            text: _pending!.isNotEmpty
                ? _pending!
                : _reading != null && _reading! < 0.9
                    ? 'Reading the transcript… ${(_reading! / 0.9 * 100).floor()}%'
                    : '…',
            mine: false),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Ask AI')),
      body: Column(
        children: [
          Expanded(
            child: bubbles.isEmpty
                ? _CallToAction(
                    text: 'Ask anything about "${rec.title}", e.g. "What did '
                        'we decide?" or "List the action items."',
                  )
                : ListView(
                    reverse: true,
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                    children: bubbles.reversed.toList(),
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: GradientBorder(
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _input,
                        minLines: 1,
                        maxLines: 4,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(rec),
                        decoration: const InputDecoration(
                          hintText: 'Ask about this recording',
                          filled: false,
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 18, vertical: 16),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: IconButton.filled(
                        style: IconButton.styleFrom(
                          backgroundColor: context.colors.text,
                          foregroundColor: context.colors.inverse,
                        ),
                        icon: const Icon(Icons.arrow_upward, size: 20),
                        onPressed: _pending == null ? () => _send(rec) : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final String text;
  final bool mine;
  const _Bubble({required this.text, required this.mine});

  @override
  Widget build(BuildContext context) {
    if (!mine) {
      // Answers read like a note, not a chat bubble.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: MarkdownView(text, compact: true),
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
        decoration: BoxDecoration(
          color: context.colors.fill,
          borderRadius: BorderRadius.circular(18),
        ),
        child: SelectableText(text, style: const TextStyle(fontSize: 16)),
      ),
    );
  }
}

class _TranscribeProgress extends StatelessWidget {
  final String label;
  final double? progress;
  final VoidCallback onCancel;
  const _TranscribeProgress(
      {required this.label, required this.progress, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final p = progress;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            p == null ? '$label…' : '$label… ${(p * 100).floor()}%',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(value: p, minHeight: 4),
          ),
          const SizedBox(height: 12),
          Text('You can leave this screen; it keeps going.',
              style: TextStyle(color: context.colors.muted)),
          const SizedBox(height: 20),
          OutlinedButton(onPressed: onCancel, child: const Text('Cancel')),
        ],
      ),
    );
  }
}

class _CallToAction extends StatelessWidget {
  final String text;
  final Widget? button;
  final EdgeInsets padding;
  const _CallToAction(
      {required this.text, this.button, this.padding = const EdgeInsets.all(24)});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(text,
              style: TextStyle(
                  color: context.colors.muted, fontSize: 16, height: 1.5)),
          if (button != null) ...[const SizedBox(height: 20), button!],
        ],
      ),
    );
  }
}
