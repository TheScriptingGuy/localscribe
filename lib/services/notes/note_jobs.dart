import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../models/recording.dart';
import '../../settings/settings.dart';
import '../ai/ai_factory.dart';
import '../ai/ai_types.dart';
import '../audio/recording_service.dart';
import '../library/recording_store.dart';
import '../models/llm_models.dart';
import '../templates/prompt_builder.dart';
import '../templates/template_repository.dart';
import 'auto_template.dart';
import 'note_generator.dart';

class _NoteJob {
  double? progress; // null until the generator reports any
  final cancel = CancelSignal();
}

/// Generates notes independently of any screen, so leaving a recording
/// doesn't lose the work. With the on-device model (which can take minutes
/// on a long transcript) it holds the foreground service.
class NoteJobs extends ChangeNotifier {
  /// [generate]'s choice for "let the AI pick the template".
  static const autoTemplate = '__auto__';
  static const _owner = 'notes';

  final RecordingStore store;
  final Settings settings;
  final TemplateRepository templates;
  final LlmModelManager llmModels;

  NoteJobs({
    required this.store,
    required this.settings,
    required this.templates,
    required this.llmModels,
  });

  final _jobs = <String, _NoteJob>{};
  final _errors = <String, String>{};

  bool isRunning(String recordingId) => _jobs.containsKey(recordingId);
  double? progressOf(String recordingId) => _jobs[recordingId]?.progress;
  String? errorOf(String recordingId) => _errors[recordingId];

  void clearError(String recordingId) {
    if (_errors.remove(recordingId) != null) notifyListeners();
  }

  void cancel(String recordingId) => _jobs[recordingId]?.cancel.cancel();

  /// Writes a note from template [choice] (an id, or [autoTemplate]) and
  /// puts it first in the recording's notes.
  Future<void> generate(Recording rec, String choice) async {
    if (isRunning(rec.id)) return;
    final transcript = rec.transcriptForAi;
    if (transcript.isEmpty) {
      _errors[rec.id] = 'Transcribe the recording first.';
      notifyListeners();
      return;
    }
    final job = _NoteJob();
    _jobs[rec.id] = job;
    _errors.remove(rec.id);
    notifyListeners();

    final onDevice = settings.noteAi.onDevice;
    var lastPercent = -1;
    void report(double p) {
      job.progress = p;
      notifyListeners();
      final percent = (p * 100).floor();
      if (onDevice && percent != lastPercent) {
        lastPercent = percent;
        RecordingService.updateWork(
                _owner, 'LocalScribe is writing notes', '${rec.title} · $percent%')
            .catchError((_) {});
      }
    }

    try {
      if (onDevice) {
        await RecordingService.startWork(
                _owner, 'LocalScribe is writing notes', rec.title)
            .catchError((_) {});
      }
      final gen = AiFactory.noteGenerator(settings.noteAi, models: llmModels);
      // "Set for next use" replaces Auto when the user chose a default.
      final fallback = choice == autoTemplate ? templates.defaultTemplate : null;
      final auto = choice == autoTemplate && fallback == null;
      final template = fallback ??
          (auto
              ? await AutoTemplatePicker.pick(
                  generator: gen,
                  templates: templates.all,
                  transcript: transcript)
              : templates.byId(choice));
      if (template == null) throw AiException('Template not found: $choice');

      final content = await gen.complete(
        PromptBuilder.forNote(
          template: template,
          transcript: transcript,
          languageHint: settings.noteLanguage,
        ),
        onProgress: report,
        cancel: job.cancel,
      );
      // The recording may have been deleted meanwhile.
      if (store.byId(rec.id) == null) return;
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
      await templates.markUsed(template.id);
    } on AiException catch (e) {
      if (!e.cancelled) _errors[rec.id] = e.message;
    } catch (e) {
      _errors[rec.id] = e.toString();
    } finally {
      _jobs.remove(rec.id);
      if (_jobs.isEmpty) {
        await RecordingService.stopWork(_owner).catchError((_) {});
      }
      notifyListeners();
    }
  }
}
