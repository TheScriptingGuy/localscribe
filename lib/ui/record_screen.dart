import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';

import '../models/recording.dart';
import '../services/library/recording_store.dart';
import 'format.dart';
import 'recording_detail_screen.dart';

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
  double _level = 0; // 0..1
  String? _error;

  @override
  void dispose() {
    _ticker?.cancel();
    _ampSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!await _recorder.hasPermission()) {
      setState(() => _error = 'Microphone permission was denied.');
      return;
    }
    final store = context.read<RecordingStore>();
    final path = await store.newTempAudioPath('m4a');
    try {
      await _recorder.start(_config, path: path);
    } catch (e) {
      setState(() => _error = 'Could not start recording: $e');
      return;
    }
    _elapsed
      ..reset()
      ..start();
    _ticker = Timer.periodic(
        const Duration(milliseconds: 250), (_) => setState(() {}));
    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 120))
        .listen((a) {
      // dBFS (-60..0) -> 0..1 for the level meter.
      setState(() => _level = ((a.current + 60) / 60).clamp(0.0, 1.0));
    });
    setState(() {
      _recording = true;
      _paused = false;
      _error = null;
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
  }

  Future<void> _stop() async {
    final store = context.read<RecordingStore>();
    final navigator = Navigator.of(context);
    _elapsed.stop();
    _ticker?.cancel();
    await _ampSub?.cancel();
    final path = await _recorder.stop();
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
        appBar: AppBar(title: const Text('Record')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Spacer(),
                Text(
                  formatDuration(_elapsed.elapsed),
                  style: Theme.of(context)
                      .textTheme
                      .displayMedium
                      ?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
                const SizedBox(height: 24),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _recording && !_paused ? _level : 0,
                    minHeight: 12,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  !_recording
                      ? 'Ready'
                      : _paused
                          ? 'Paused'
                          : 'Recording… keep the app open',
                  style: TextStyle(color: scheme.outline),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!, style: TextStyle(color: scheme.error)),
                ],
                const Spacer(),
                if (!_recording)
                  SizedBox(
                    width: 96,
                    height: 96,
                    child: FilledButton(
                      style: FilledButton.styleFrom(shape: const CircleBorder()),
                      onPressed: _start,
                      child: const Icon(Icons.mic, size: 40),
                    ),
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton.outlined(
                        tooltip: 'Discard',
                        iconSize: 32,
                        onPressed: _confirmDiscard,
                        icon: const Icon(Icons.delete_outline),
                      ),
                      SizedBox(
                        width: 96,
                        height: 96,
                        child: FilledButton(
                          style:
                              FilledButton.styleFrom(shape: const CircleBorder()),
                          onPressed: _stop,
                          child: const Icon(Icons.stop, size: 40),
                        ),
                      ),
                      IconButton.outlined(
                        tooltip: _paused ? 'Resume' : 'Pause',
                        iconSize: 32,
                        onPressed: _togglePause,
                        icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                      ),
                    ],
                  ),
                const SizedBox(height: 32),
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
