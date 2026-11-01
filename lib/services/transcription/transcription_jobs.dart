import 'package:flutter/foundation.dart';

import '../../models/recording.dart';
import '../../settings/settings.dart';
import '../ai/ai_factory.dart';
import '../ai/ai_types.dart';
import '../audio/recording_service.dart';
import '../library/recording_store.dart';
import '../models/whisper_models.dart';
import 'transcriber.dart';

class _Job {
  double? progress; // null until the backend reports any
  final cancel = CancelSignal();
}

/// Runs transcriptions independently of any screen, so leaving a recording
/// doesn't lose the work. On-device jobs hold a foreground service so they
/// keep running with the screen off.
class TranscriptionJobs extends ChangeNotifier {
  final RecordingStore store;
  final Settings settings;
  final WhisperModelManager models;

  TranscriptionJobs(
      {required this.store, required this.settings, required this.models});

  final _jobs = <String, _Job>{};
  final _errors = <String, String>{};

  bool isRunning(String recordingId) => _jobs.containsKey(recordingId);
  double? progressOf(String recordingId) => _jobs[recordingId]?.progress;
  String? errorOf(String recordingId) => _errors[recordingId];

  void clearError(String recordingId) {
    if (_errors.remove(recordingId) != null) notifyListeners();
  }

  void cancel(String recordingId) => _jobs[recordingId]?.cancel.cancel();

  Future<void> start(Recording rec) async {
    if (isRunning(rec.id)) return;
    final job = _Job();
    _jobs[rec.id] = job;
    _errors.remove(rec.id);
    notifyListeners();

    final config = settings.transcription;
    var lastPercent = -1;
    try {
      final transcriber = AiFactory.transcriber(config, models: models);
      if (config.onDevice) {
        // Best effort: without the service it still runs while the app is open.
        await RecordingService.startTranscribing(rec.title).catchError((_) {});
      }
      final result = await transcriber.transcribe(
        store.audioOf(rec),
        language: config.language == 'auto' ? null : config.language,
        cancel: job.cancel,
        onProgress: (p) {
          job.progress = p;
          notifyListeners();
          final percent = (p * 100).floor();
          if (config.onDevice && percent != lastPercent) {
            lastPercent = percent;
            RecordingService.updateTranscribing('${rec.title} · $percent%')
                .catchError((_) {});
          }
        },
      );
      // The recording may have been deleted meanwhile.
      if (store.byId(rec.id) != null) {
        rec.transcript = result;
        await store.save(rec);
      }
    } on AiException catch (e) {
      if (!e.cancelled) _errors[rec.id] = e.message;
    } catch (e) {
      _errors[rec.id] = e.toString();
    } finally {
      _jobs.remove(rec.id);
      if (_jobs.isEmpty) {
        await RecordingService.stopTranscribing().catchError((_) {});
      }
      notifyListeners();
    }
  }
}
