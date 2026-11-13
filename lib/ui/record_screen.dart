import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:uuid/uuid.dart';

import '../models/recording.dart';
import '../services/audio/recording_service.dart';
import '../services/audio/wav_recorder.dart';
import '../services/library/recording_store.dart';
import '../services/models/whisper_models.dart';
import '../services/transcription/live_captioner.dart';
import '../settings/settings.dart';
import 'format.dart';
import 'recording_detail_screen.dart';
import 'theme.dart';

/// Phone-mic recorder. Writes 16 kHz mono WAV (~115 MB/hour, lossless, which
  /// whisper.cpp reads directly), with highlights, photos, notes and optional
  /// live captions while recording.
class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  final _recorder = AudioRecorder();
  late final _wav = WavRecorder(_recorder);
  final _elapsed = Stopwatch();
  Timer? _ticker;
  StreamSubscription<Uint8List>? _pcmSub;
  LiveCaptioner? _captions;
  var _captionsOpen = true;

  bool _recording = false;
  bool _paused = false;
  /// Recent input levels (0..1), newest last, for the waveform.
  final _levels = <double>[];
  static const _maxLevels = 64;
  String? _error;

  /// Highlights, photos and notes marked so far; photos wait in temp files
  /// until the recording is saved.
  final _markers = <RecordingMarker>[];
  final _photos = <String, File>{};

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onNotificationAction);
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onNotificationAction);
    _ticker?.cancel();
    _pcmSub?.cancel();
    _captions?.dispose();
    _recorder.dispose();
    RecordingService.stop();
    super.dispose();
  }

  /// Pause/Resume/Stop pressed on the recording notification.
  void _onNotificationAction(Object data) {
    if (!_recording) return;
    switch (data) {
      case RecordingAction.pause when !_paused:
      case RecordingAction.resume when _paused:
        _togglePause();
      case RecordingAction.stop:
        _stop();
    }
  }

  Future<void> _start() async {
    if (!await _wav.hasPermission()) {
      setState(() => _error = 'Microphone permission was denied.');
      return;
    }
    final store = context.read<RecordingStore>();
    final path = await store.newTempAudioPath('wav');
    // Start the foreground service first so the mic stays live with the
    // screen off. If it fails, record anyway — just foreground-only.
    String? serviceWarning;
    try {
      await RecordingService.start();
    } catch (e) {
      serviceWarning = 'Background recording unavailable ($e); keep the app open.';
    }
    try {
      await _wav.start(path);
    } catch (e) {
      await RecordingService.stop();
      setState(() => _error = 'Could not start recording: $e');
      return;
    }
    _error = serviceWarning;
    _elapsed
      ..reset()
      ..start();
    _ticker = Timer.periodic(
        const Duration(milliseconds: 250), (_) => setState(() {}));
    final settings = context.read<Settings>();
    final models = context.read<WhisperModelManager>();
    final captions = LiveCaptioner.tryCreate(settings, models);
    captions?.addListener(() {
      if (mounted) setState(() {});
    });
    _captions = captions;
    _pcmSub = _wav.pcm.listen((chunk) {
      captions?.feed(chunk);
      final level = WavRecorder.level(chunk);
      if (!mounted) return;
      setState(() {
        _levels.add(_paused ? 0 : level);
        if (_levels.length > _maxLevels) _levels.removeAt(0);
      });
    });
    setState(() {
      _recording = true;
      _paused = false;
    });
  }

  RecordingMarker _newMarker(MarkerType type, {String? text}) =>
      RecordingMarker(
        id: const Uuid().v4(),
        atMs: _wav.durationMs,
        type: type,
        text: text,
      );

  void _flag() {
    HapticFeedback.mediumImpact();
    setState(() => _markers.add(_newMarker(MarkerType.flag)));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 2),
          content: Text('Highlight marked at ${formatDuration(_elapsed.elapsed)}')));
  }

  Future<void> _photo() async {
    // The time is the moment the button was pressed, not when the camera closes.
    final marker = _newMarker(MarkerType.photo);
    try {
      final shot = await ImagePicker().pickImage(
          source: ImageSource.camera, imageQuality: 85, maxWidth: 1920);
      if (shot == null || !mounted) return;
      setState(() {
        _markers.add(marker);
        _photos[marker.id] = File(shot.path);
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not take a photo: $e');
    }
  }

  Future<void> _note() async {
    final marker = _newMarker(MarkerType.note);
    final ctrl = TextEditingController();
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 0, 24, 24 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add a note at ${formatDuration(Duration(milliseconds: marker.atMs))}',
                style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                  hintText: 'Key point, idea or reminder'),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('Add note'),
              ),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (text == null || text.isEmpty || !mounted) return;
    setState(() => _markers.add(RecordingMarker(
        id: marker.id, atMs: marker.atMs, type: MarkerType.note, text: text)));
  }

  Future<void> _togglePause() async {
    if (_paused) {
      await _wav.resume();
      _elapsed.start();
    } else {
      await _wav.pause();
      _elapsed.stop();
    }
    setState(() => _paused = !_paused);
    await RecordingService.setPaused(_paused);
  }

  Future<void> _stop() async {
    final store = context.read<RecordingStore>();
    final navigator = Navigator.of(context);
    _elapsed.stop();
    _ticker?.cancel();
    _captions?.stop();
    await _pcmSub?.cancel();
    final String path;
    try {
      path = await _wav.stop();
    } catch (e) {
      await RecordingService.stop();
      setState(() {
        _recording = false;
        _error = 'Recording produced no file: $e';
      });
      return;
    }
    await RecordingService.stop();
    final now = DateTime.now();
    final rec = await store.add(
      File(path),
      title: 'Recording ${formatDate(now)}',
      source: RecordingSource.mic,
      durationMs: _wav.durationMs,
      move: true,
      markers: List.of(_markers)..sort((a, b) => a.atMs.compareTo(b.atMs)),
      photos: Map.of(_photos),
    );
    navigator.pushReplacement(MaterialPageRoute(
        builder: (_) => RecordingDetailScreen(recordingId: rec.id)));
  }

  Future<void> _discard() async {
    _ticker?.cancel();
    _captions?.stop();
    await _pcmSub?.cancel();
    await _wav.cancel(); // stops and deletes the temp file
    for (final f in _photos.values) {
      try {
        await f.delete();
      } catch (_) {}
    }
    await RecordingService.stop();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_recording,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        appBar: AppBar(),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  !_recording
                      ? 'New recording'
                      : _paused
                          ? 'Paused'
                          : 'Recording',
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (_recording && !_paused) ...[
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                            color: context.colors.danger,
                            shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      !_recording
                          ? 'Phone microphone'
                          : 'Keeps recording with the screen off',
                      style: TextStyle(color: context.colors.muted, fontSize: 15),
                    ),
                  ],
                ),
                const Spacer(),
                Center(
                  child: Text(
                    formatDuration(_elapsed.elapsed),
                    style: Theme.of(context).textTheme.displayLarge?.copyWith(
                      fontWeight: FontWeight.w200,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  height: 96,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _WaveformPainter(
                      levels: _levels,
                      slots: _maxLevels,
                      color: _paused ? context.colors.faint : context.colors.text,
                    ),
                  ),
                ),
                if (_recording && _captions != null) ...[
                  const SizedBox(height: 16),
                  _CaptionsPanel(
                    lines: _captions!.recentLines(),
                    open: _captionsOpen,
                    error: _captions!.error,
                    onToggle: () =>
                        setState(() => _captionsOpen = !_captionsOpen),
                  ),
                ],
                if (_recording) ...[
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _MarkerButton(
                          icon: Icons.flag_outlined,
                          label: 'Highlight',
                          onPressed: _flag),
                      _MarkerButton(
                          icon: Icons.photo_camera_outlined,
                          label: 'Photo',
                          onPressed: _photo),
                      _MarkerButton(
                          icon: Icons.edit_note,
                          label: 'Note',
                          onPressed: _note),
                    ],
                  ),
                  if (_markers.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Center(
                        child: Text(
                          '${_markers.length} marked moment${_markers.length == 1 ? '' : 's'}',
                          style: TextStyle(
                              color: context.colors.muted, fontSize: 13),
                        ),
                      ),
                    ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!, style: TextStyle(color: scheme.error)),
                ],
                const Spacer(),
                if (!_recording)
                  Center(
                    child: _RoundButton(
                      tooltip: 'Start recording',
                      icon: Icons.mic,
                      onPressed: _start,
                    ),
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        tooltip: 'Discard',
                        iconSize: 28,
                        style: IconButton.styleFrom(
                          backgroundColor: context.colors.fill,
                          fixedSize: const Size(60, 60),
                        ),
                        onPressed: _confirmDiscard,
                        icon: const Icon(Icons.delete_outline),
                      ),
                      _RoundButton(
                        tooltip: 'Stop and save',
                        icon: Icons.stop_rounded,
                        onPressed: _stop,
                      ),
                      IconButton(
                        tooltip: _paused ? 'Resume' : 'Pause',
                        iconSize: 28,
                        style: IconButton.styleFrom(
                          backgroundColor: context.colors.fill,
                          fixedSize: const Size(60, 60),
                        ),
                        onPressed: _togglePause,
                        icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                      ),
                    ],
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDiscard() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard recording?'),
        content: const Text('The audio captured so far will be deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep recording')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    if (ok == true) await _discard();
  }
}

/// Rolling live captions, collapsible.
class _CaptionsPanel extends StatelessWidget {
  final List<String> lines;
  final bool open;
  final String? error;
  final VoidCallback onToggle;
  const _CaptionsPanel(
      {required this.lines,
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

/// Small labelled button for marking a moment while recording.
class _MarkerButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  const _MarkerButton(
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

class _RoundButton extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  const _RoundButton(
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

/// Vertical bars for recent input levels, newest on the right.
class _WaveformPainter extends CustomPainter {
  final List<double> levels;
  final int slots;
  final Color color;
  _WaveformPainter(
      {required List<double> levels, required this.slots, required this.color})
      : levels = List.of(levels);

  @override
  void paint(Canvas canvas, Size size) {
    final step = size.width / slots;
    final barWidth = step * 0.5;
    final paint = Paint()
      ..color = color
      ..strokeWidth = barWidth
      ..strokeCap = StrokeCap.round;
    final mid = size.height / 2;
    final offset = slots - levels.length;
    for (var i = 0; i < slots; i++) {
      final level = i < offset ? 0.0 : levels[i - offset];
      final h = (size.height - barWidth) * level / 2;
      final x = step * i + step / 2;
      canvas.drawLine(Offset(x, mid - h), Offset(x, mid + h), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.color != color || old.levels.length != levels.length ||
      !_sameLevels(old.levels);

  bool _sameLevels(List<double> other) {
    for (var i = 0; i < levels.length; i++) {
      if (levels[i] != other[i]) return false;
    }
    return true;
  }
}
