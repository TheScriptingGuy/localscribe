import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:localscribe_llm/localscribe_llm.dart';

import '../ai/ai_types.dart';
import '../models/llm_models.dart';
import 'note_generator.dart';

/// Notes and Ask-AI on the phone with llama.cpp. Nothing leaves the device.
///
/// A transcript too long for the model's context is condensed part by part
/// first (keeping facts, names, numbers and decisions), then used as usual.
class LocalLlmGenerator implements NoteGenerator {
  final LlmModel model;
  final File modelFile;

  LocalLlmGenerator(this.model, this.modelFile);

  /// Replies are capped so a small model can't ramble forever.
  static const _maxTokens = 1536;

  /// The model stays in memory for follow-up questions, then is freed.
  static const _keepLoaded = Duration(minutes: 3);
  static Timer? _unloadTimer;

  @override
  String get name => 'llama.cpp (${model.label})';

  @override
  Future<String> complete(List<ChatMessage> messages,
      {void Function(double progress)? onProgress,
      CancelSignal? cancel}) async {
    final out = StringBuffer();
    await for (final s
        in stream(messages, onProgress: onProgress, cancel: cancel)) {
      out.write(s);
    }
    return out.toString();
  }

  @override
  Stream<String> stream(List<ChatMessage> messages,
      {void Function(double progress)? onProgress,
      CancelSignal? cancel}) async* {
    final unsupported = LocalLlm.unsupportedReason;
    if (unsupported != null) throw AiException(unsupported);
    if (!await modelFile.exists()) {
      throw AiException('The on-device AI model is missing. Download it '
          'again in Options > Note AI.');
    }
    _unloadTimer?.cancel();
    final report = onProgress;
    try {
      var msgs = [for (final m in messages) (m.role.name, m.content)];
      if (model.thinks) msgs = _noThinking(msgs);
      var progress = report;
      for (var round = 0;; round++) {
        try {
          // `await for` (not yield*) so errors land in this catch.
          await for (final s in _ThinkFilter.apply(_run(msgs, _maxTokens,
              onProgress: progress, cancel: cancel))) {
            yield s;
          }
          return;
        } on LlmException catch (e) {
          if (!e.tooLong || round >= 3) throw _wrap(e);
          msgs = await _condense(msgs, e,
              onProgress: report == null ? null : (p) => report(p * 0.7),
              cancel: cancel);
          // The final pass then reports 0.7–1.0.
          progress = report == null ? null : (p) => report(0.7 + 0.3 * p);
        }
      }
    } finally {
      _unloadTimer = Timer(_keepLoaded, () => LocalLlm.unload());
    }
  }

  /// One generation. Progress: reading the prompt 0–0.9, writing 0.9–1.0.
  Stream<String> _run(List<(String, String)> msgs, int maxTokens,
      {void Function(double progress)? onProgress, CancelSignal? cancel}) {
    final job = LocalLlm.generate(
      modelPath: modelFile.path,
      messages: msgs,
      maxContext: model.contextTokens,
      maxTokens: maxTokens,
      temperature: 0.3,
      threads: min(4, Platform.numberOfProcessors),
    );
    cancel?.onCancel(job.cancel);
    var written = 0;
    final timer = onProgress == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 300), (_) {
            final read = job.promptProgress;
            onProgress(read < 1
                ? 0.9 * read
                : 0.9 + 0.1 * min(1, written / 4 / maxTokens));
          });
    return job.text
        .map((s) {
          written += s.length;
          return s;
        })
        .handleError((Object e) {
          throw e is LlmException ? e : AiException(e.toString());
        })
        .transform(StreamTransformer<String, String>.fromHandlers(
          handleDone: (sink) {
            timer?.cancel();
            sink.close();
          },
          handleError: (e, st, sink) {
            timer?.cancel();
            sink.addError(e, st);
          },
        ));
  }

  /// Shrinks the longest message (the transcript) until the prompt fits:
  /// each part is condensed on its own.
  Future<List<(String, String)>> _condense(
      List<(String, String)> msgs, LlmException tooLong,
      {void Function(double progress)? onProgress,
      CancelSignal? cancel}) async {
    var longest = 0;
    for (var i = 1; i < msgs.length; i++) {
      if (msgs[i].$2.length > msgs[longest].$2.length) longest = i;
    }
    final text = msgs[longest].$2;
    final totalChars = msgs.fold<int>(0, (n, m) => n + m.$2.length);
    final charsPerToken = totalChars / max(1, tooLong.promptTokens ?? 1);
    final maxPrompt = tooLong.maxPrompt ?? model.contextTokens ~/ 2;
    final textTokens = text.length / charsPerToken;
    final over = (tooLong.promptTokens ?? 0) - maxPrompt;
    // What the transcript may take afterwards, with some margin.
    final target = max(256, ((textTokens - over) * 0.85).floor());

    // Parts that each fit comfortably, cut at line breaks.
    final partChars = (maxPrompt * 0.8 * charsPerToken).floor();
    final parts = _split(text, partChars);
    final perPart = max(128, target ~/ parts.length);

    final condensed = <String>[];
    for (var i = 0; i < parts.length; i++) {
      if (cancel?.isCancelled ?? false) {
        throw AiException('Cancelled', cancelled: true);
      }
      final out = StringBuffer();
      await for (final s in _ThinkFilter.apply(_run(
        _noThinkingIf([
          ('system', _condensePrompt),
          ('user', 'Part ${i + 1} of ${parts.length}:\n\n${parts[i]}'),
        ]),
        perPart,
        onProgress: onProgress == null
            ? null
            : (p) => onProgress((i + p) / parts.length),
        cancel: cancel,
      ))) {
        out.write(s);
      }
      condensed.add(out.toString().trim());
    }
    return [
      for (var i = 0; i < msgs.length; i++)
        i == longest
            ? (
                msgs[i].$1,
                '(The transcript was condensed to fit the on-device model.)\n\n'
                    '${condensed.join('\n\n')}'
              )
            : msgs[i],
    ];
  }

  static const _condensePrompt =
      'You condense one part of a recorded conversation. Keep every fact, '
      'name, number, date, decision, question and action item, and who said '
      'what. Leave out filler and repetition. Write in the language of the '
      'text. Output only the condensed text.';

  List<(String, String)> _noThinkingIf(List<(String, String)> msgs) =>
      model.thinks ? _noThinking(msgs) : msgs;

  /// Qwen3's switch for answering without a reasoning block.
  static List<(String, String)> _noThinking(List<(String, String)> msgs) {
    final i = msgs.lastIndexWhere((m) => m.$1 == 'user');
    if (i < 0) return msgs;
    return [
      for (var j = 0; j < msgs.length; j++)
        j == i ? (msgs[j].$1, '${msgs[j].$2} /no_think') : msgs[j],
    ];
  }

  static List<String> _split(String text, int maxChars) {
    final parts = <String>[];
    final current = StringBuffer();
    for (final line in text.split('\n')) {
      if (current.length + line.length > maxChars && current.isNotEmpty) {
        parts.add(current.toString());
        current.clear();
      }
      // A single line longer than a part (no line breaks): hard cut.
      var rest = line;
      while (rest.length > maxChars) {
        parts.add(rest.substring(0, maxChars));
        rest = rest.substring(maxChars);
      }
      current
        ..write(rest)
        ..write('\n');
    }
    if (current.toString().trim().isNotEmpty) parts.add(current.toString());
    return parts;
  }

  static AiException _wrap(LlmException e) {
    if (e.cancelled) return AiException('Cancelled', cancelled: true);
    if (e.tooLong) {
      return AiException('This transcript is too long for the on-device '
          'model, even condensed. Use a chat API URL for it.');
    }
    return AiException(e.message);
  }
}

/// Drops a leading <think>…</think> block (Qwen3) from a reply stream.
class _ThinkFilter {
  static Stream<String> apply(Stream<String> source) async* {
    var head = StringBuffer();
    var decided = false;
    var inThink = false;
    await for (final s in source) {
      if (decided && !inThink) {
        yield s;
        continue;
      }
      head.write(s);
      final text = head.toString();
      if (!decided) {
        final trimmed = text.trimLeft();
        if (trimmed.length < 7 && '<think>'.startsWith(trimmed)) continue;
        decided = true;
        inThink = trimmed.startsWith('<think>');
        if (!inThink) {
          head = StringBuffer();
          yield text;
          continue;
        }
      }
      final end = text.indexOf('</think>');
      if (end < 0) continue;
      inThink = false;
      final rest = text.substring(end + 8).trimLeft();
      head = StringBuffer();
      if (rest.isNotEmpty) yield rest;
    }
    if (!decided && head.isNotEmpty) yield head.toString();
  }
}
