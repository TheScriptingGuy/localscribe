import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../models/recording.dart';
import '../services/audio/recording_service.dart';
import '../services/library/recording_store.dart';
import 'format.dart';
import 'recording_detail_screen.dart';
import 'theme.dart';

/// Phone-mic recorder. Writes 16 kHz mono AAC: small enough for Whisper APIs
/// (~22 MB/hour, under the common 25 MB upload cap) and enough for speech.
class RecordScreen extends StatefulWidget {
  const RecordScreen({super.key});

  @override
  State<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends State<RecordScreen> {
  static const _config = RecordConfig(
    encoder: AudioEncoder.aacLc,
    sampleRate: 16000,
    numChannels: 1,
    bitRate: 48000,
  );

  final _recorder = AudioRecorder();
  final _elapsed = Stopwatch();
  Timer? _ticker;
  StreamSubscription<Amplitude>? _ampSub;

  bool _recording = false;
  bool _paused = false;
  /// Recent input levels (0..1), newest last, for the waveform.
  final _levels = <double>[];
  static const _maxLevels = 64;
  String? _error;

  @override
  void initState() {
    super.initState();
    FlutterForegroundTask.addTaskDataCallback(_onNotificationAction);
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onNotificationAction);
    _ticker?.cancel();
    _ampSub?.cancel();
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
    if (!await _recorder.hasPermission()) {
      setState(() => _error = 'Microphone permission was denied.');
      return;
    }
    final store = context.read<RecordingStore>();
    final path = await store.newTempAudioPath('m4a');
    // Start the foreground service first so the mic stays live with the
    // screen off. If it fails, record anyway — just foreground-only.
    String? serviceWarning;
    try {
      await RecordingService.start();
    } catch (e) {
      serviceWarning = 'Background recording unavailable ($e); keep the app open.';
    }
    try {
      await _recorder.start(_config, path: path);
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
    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 120))
        .listen((a) {
      // dBFS (-60..0) -> 0..1 for the level meter.
      final level = ((a.current + 60) / 60).clamp(0.0, 1.0);
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

  Future<void> _togglePause() async {
    if (_paused) {
      await _recorder.resume();
      _elapsed.start();
    } else {
      await _recorder.pause();
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
    await _ampSub?.cancel();
    final path = await _recorder.stop();
    await RecordingService.stop();
    if (path == null) {
      setState(() {
        _recording = false;
        _error = 'Recording produced no file.';
      });
      return;
    }
    final now = DateTime.now();
    final rec = await store.add(
      File(path),
      title: 'Recording ${formatDate(now)}',
      source: RecordingSource.mic,
      durationMs: _elapsed.elapsedMilliseconds,
      move: true,
    );
    navigator.pushReplacement(MaterialPageRoute(
        builder: (_) => RecordingDetailScreen(recordingId: rec.id)));
  }

  Future<void> _discard() async {
    _ticker?.cancel();
    await _ampSub?.cancel();
    await _recorder.cancel(); // stops and deletes the temp file
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
