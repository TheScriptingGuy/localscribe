import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:localscribe_native/localscribe_native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/ai_config.dart';
import '../models/whisper_models.dart';
import '../../settings/settings.dart';
import '../audio/wav_recorder.dart';

/// Rolling captions while recording: every few seconds the audio since the
/// last settled sentence goes through whisper.cpp. All but the last segment
/// are settled (kept); the last is shown as tentative and re-heard next time.
/// Display only: the final transcript is still made from the saved audio.
class LiveCaptioner extends ChangeNotifier {
  static const _bytesPerSecond = WavRecorder.bytesPerMs * 1000;

  /// Run again once this much new audio has arrived.
  static const _hop = Duration(seconds: 4);

  /// Settle everything once the open buffer grows past this.
  static const _maxBufferSeconds = 24;

  final File modelFile;
  final String language;
  final int threads;
  LiveCaptioner(
      {required this.modelFile, required this.language, required this.threads});

  /// Null when live captions can't run (off, remote transcription, no model,
  /// unsupported CPU).
  static LiveCaptioner? tryCreate(
      Settings settings, WhisperModelManager models) {
    if (!settings.liveCaptions || !settings.transcription.onDevice) return null;
    if (LocalScribeNative.unsupportedReason != null) return null;
    final model = whisperModelByFile(settings.transcription.localModel);
    if (model == null || !models.isInstalled(model)) return null;
    final lang = settings.transcription.language;
    return LiveCaptioner(
      modelFile: models.fileOf(model),
      language: (lang.isEmpty || lang == mixedLanguages) ? 'auto' : lang,
      threads: math.max(1, math.min(3, Platform.numberOfProcessors - 2)),
    );
  }

  final _settled = <String>[];
  String _tentative = '';
  String? error;

  var _buffer = BytesBuilder(copy: false);
  var _bytesAtLastRun = 0;
  var _busy = false;
  var _stopped = false;
  WhisperJob? _job;

  /// Everything heard so far, settled and tentative.
  String get text => [..._settled, if (_tentative.isNotEmpty) _tentative].join(' ');

  /// The last few lines, for a small captions panel.
  List<String> recentLines({int max = 3}) {
    final all = [..._settled, if (_tentative.isNotEmpty) _tentative];
    return all.length <= max ? all : all.sublist(all.length - max);
  }

  void feed(Uint8List pcm) {
    if (_stopped) return;
    _buffer.add(pcm);
    _maybeRun();
  }

  void _maybeRun() {
    if (_busy || _stopped) return;
    final length = _buffer.length;
    if (length - _bytesAtLastRun < _hop.inSeconds * _bytesPerSecond) return;
    _run();
  }

  Future<void> _run() async {
    _busy = true;
    final snapshot = _buffer.toBytes();
    _bytesAtLastRun = snapshot.length;
    final tmp = await getTemporaryDirectory();
    final path =
        p.join(tmp.path, 'live-${DateTime.now().microsecondsSinceEpoch}.pcm');
    try {
      await File(path).writeAsBytes(snapshot, flush: true);
      final job = LocalScribeNative.transcribe(
        modelPath: modelFile.path,
        audioPath: '', // empty: `path` already is raw 16 kHz mono PCM
        scratchPath: path,
        language: language,
        threads: threads,
      );
      _job = job;
      final result = await job.result;
      if (_stopped) return;
      _apply(result, snapshot);
      error = null;
    } on WhisperException catch (e) {
      if (!e.cancelled) error = e.message;
    } catch (e) {
      error = e.toString();
    } finally {
      _job = null;
      try {
        await File(path).delete();
      } catch (_) {}
      _busy = false;
      if (!_stopped) {
        notifyListeners();
        _maybeRun();
      }
    }
  }

  void _apply(Map<String, dynamic> result, Uint8List snapshot) {
    final segments = ((result['segments'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((s) => (s['text'] as String? ?? '').trim().isNotEmpty)
        .toList();
    final seconds = snapshot.length / _bytesPerSecond;

    if (segments.isEmpty) {
      // Silence: keep only the last couple of seconds of context.
      if (seconds > 8) _dropFront(snapshot, seconds - 2);
      _tentative = '';
      return;
    }

    final settleAll = seconds > _maxBufferSeconds;
    final settleCount = settleAll ? segments.length : segments.length - 1;
    for (var i = 0; i < settleCount; i++) {
      _settled.add((segments[i]['text'] as String).trim());
    }
    _tentative = settleAll ? '' : (segments.last['text'] as String).trim();
    if (settleCount > 0) {
      final until = settleAll
          ? seconds
          : (segments[settleCount - 1]['end'] as num).toDouble();
      _dropFront(snapshot, until);
    }
  }

  /// Removes the first [seconds] of audio from the open buffer.
  void _dropFront(Uint8List snapshot, double seconds) {
    var cut = (seconds * _bytesPerSecond).round();
    cut -= cut % 2; // whole samples
    cut = cut.clamp(0, snapshot.length).toInt();
    // Audio that arrived while whisper was running is kept too.
    final current = _buffer.toBytes();
    _buffer = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(current, math.min(cut, current.length)));
    _bytesAtLastRun = math.max(0, _bytesAtLastRun - cut);
  }

  /// Stops captioning; a running pass is cancelled.
  void stop() {
    _stopped = true;
    _job?.cancel();
  }
}
