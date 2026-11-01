import 'package:flutter/foundation.dart';

import '../../models/recording.dart';
import '../../settings/settings.dart';
import '../ai/ai_factory.dart';
import '../ai/ai_types.dart';
import '../audio/recording_service.dart';
import '../diarization/speaker_merge.dart';
import '../library/recording_store.dart';
import '../models/speaker_models.dart';
import '../models/whisper_models.dart';
import 'transcriber.dart';

/// What a running job is doing right now.
enum JobPhase {
  transcribing('Transcribing'),
  speakers('Identifying speakers');

  final String label;
  const JobPhase(this.label);
}

class _Job {
  JobPhase phase;
  double? progress; // null until the backend reports any
  final cancel = CancelSignal();
  _Job(this.phase);
}

/// Runs transcription and speaker recognition independently of any screen,
/// so leaving a recording doesn't lose the work. On-device jobs hold a
/// foreground service so they keep running with the screen off.
class TranscriptionJobs extends ChangeNotifier {
  final RecordingStore store;
  final Settings settings;
  final WhisperModelManager models;
  final SpeakerModelManager speakerModels;

  TranscriptionJobs({
    required this.store,
    required this.settings,
    required this.models,
    required this.speakerModels,
  });

  final _jobs = <String, _Job>{};
  final _errors = <String, String>{};

  bool isRunning(String recordingId) => _jobs.containsKey(recordingId);
  double? progressOf(String recordingId) => _jobs[recordingId]?.progress;
  JobPhase? phaseOf(String recordingId) => _jobs[recordingId]?.phase;
  String? errorOf(String recordingId) => _errors[recordingId];

  void clearError(String recordingId) {
    if (_errors.remove(recordingId) != null) notifyListeners();
  }

  void cancel(String recordingId) => _jobs[recordingId]?.cancel.cancel();

  /// Transcribes, then identifies speakers if that's switched on.
  Future<void> start(Recording rec) =>
      _run(rec, transcribe: true, speakers: settings.speakers.enabled);

  /// Identifies speakers on the existing transcript.
  Future<void> identifySpeakers(Recording rec) =>
      _run(rec, transcribe: false, speakers: true);

  Future<void> _run(Recording rec,
      {required bool transcribe, required bool speakers}) async {
    if (isRunning(rec.id)) return;
    final job = _Job(transcribe ? JobPhase.transcribing : JobPhase.speakers);
    _jobs[rec.id] = job;
    _errors.remove(rec.id);
    notifyListeners();

    final tConfig = settings.transcription;
    final sConfig = settings.speakers;
    final onDevice = (transcribe && tConfig.onDevice) ||
        (speakers && sConfig.onDevice);
    var lastPercent = -1;

    void report(double p) {
      job.progress = p;
      notifyListeners();
      final percent = (p * 100).floor();
      if (onDevice && percent != lastPercent) {
        lastPercent = percent;
        RecordingService.updateTranscribing(
                '${rec.title} · ${job.phase.label} $percent%')
            .catchError((_) {});
      }
    }

    var transcriptSaved = false;
    try {
      if (onDevice) {
        // Best effort: without the service it still runs while the app is open.
        await RecordingService.startTranscribing(rec.title).catchError((_) {});
      }

      if (transcribe) {
        final transcriber = AiFactory.transcriber(tConfig, models: models);
        final result = await transcriber.transcribe(
          store.audioOf(rec),
          language: tConfig.language == 'auto' ? null : tConfig.language,
          cancel: job.cancel,
          onProgress: report,
        );
        // The recording may have been deleted meanwhile.
        if (store.byId(rec.id) == null) return;
        rec.transcript = result;
        rec.speakerNames.clear();
        await store.save(rec);
        transcriptSaved = true;
      }

      final transcript = rec.transcript;
      if (speakers && transcript != null && transcript.segments.isNotEmpty) {
        job
          ..phase = JobPhase.speakers
          ..progress = null;
        notifyListeners();
        final diarizer =
            AiFactory.diarizer(sConfig, models: speakerModels);
        final turns = await diarizer.diarize(
          store.audioOf(rec),
          numSpeakers: sConfig.numSpeakers,
          cancel: job.cancel,
          onProgress: report,
        );
        if (store.byId(rec.id) == null) return;
        rec.transcript = assignSpeakers(transcript, turns);
        rec.speakerNames.clear();
        await store.save(rec);
      }
    } on AiException catch (e) {
      if (!e.cancelled) _errors[rec.id] = _describe(e.message, transcriptSaved);
    } catch (e) {
      _errors[rec.id] = _describe(e.toString(), transcriptSaved);
    } finally {
      _jobs.remove(rec.id);
      if (_jobs.isEmpty) {
        await RecordingService.stopTranscribing().catchError((_) {});
      }
      notifyListeners();
    }
  }

  static String _describe(String message, bool transcriptSaved) =>
      transcriptSaved
          ? 'Transcript saved, but speaker recognition failed: $message'
          : message;
}
