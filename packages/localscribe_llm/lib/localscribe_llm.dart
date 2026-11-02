/// Dart FFI bindings for liblocalscribe_llm.so (llama.cpp). Generation runs
/// in a background isolate; text, progress and cancellation go through a
/// shared native job handle that this isolate polls.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const _libName = 'liblocalscribe_llm.so';

typedef _GenerateC = Pointer<Utf8> Function(
    Pointer<Utf8>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    Int32,
    Int32,
    Int32,
    Float,
    Int32,
    Pointer<Void>);
typedef _GenerateDart = Pointer<Utf8> Function(
    Pointer<Utf8>,
    Pointer<Pointer<Utf8>>,
    Pointer<Pointer<Utf8>>,
    int,
    int,
    int,
    double,
    int,
    Pointer<Void>);

final class _Bindings {
  _Bindings(DynamicLibrary lib)
      : jobNew = lib.lookupFunction<Pointer<Void> Function(),
            Pointer<Void> Function()>('lsl_job_new'),
        jobProgress = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('lsl_job_progress'),
        jobCancel = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('lsl_job_cancel'),
        jobFree = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('lsl_job_free'),
        jobTake = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Void>),
            Pointer<Utf8> Function(Pointer<Void>)>('lsl_job_take'),
        freeString = lib.lookupFunction<Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)>('lsl_free_string'),
        unload = lib.lookupFunction<Void Function(), void Function()>(
            'lsl_unload'),
        generate =
            lib.lookupFunction<_GenerateC, _GenerateDart>('lsl_generate');

  final Pointer<Void> Function() jobNew;
  final int Function(Pointer<Void>) jobProgress;
  final void Function(Pointer<Void>) jobCancel;
  final void Function(Pointer<Void>) jobFree;
  final Pointer<Utf8> Function(Pointer<Void>) jobTake;
  final void Function(Pointer<Utf8>) freeString;
  final void Function() unload;
  final _GenerateDart generate;

  String take(Pointer<Void> job) {
    final p = jobTake(job);
    final s = _utf8(p);
    freeString(p);
    return s;
  }
}

String _utf8(Pointer<Utf8> p) => utf8.decode(
    Uint8List.fromList(p.cast<Uint8>().asTypedList(p.length)),
    allowMalformed: true);

_Bindings? _cached;
_Bindings get _bindings => _cached ??= _Bindings(DynamicLibrary.open(_libName));

class LlmException implements Exception {
  final String message;

  /// Set when the prompt doesn't fit: its size and the most that fits.
  final int? promptTokens;
  final int? maxPrompt;

  LlmException(this.message, {this.promptTokens, this.maxPrompt});
  bool get cancelled => message == 'cancelled';
  bool get tooLong => message == 'too_long';
  @override
  String toString() => 'LlmException($message)';
}

class LlmResult {
  final String text;
  final int promptTokens;
  final int tokens;

  /// Stopped at the token limit rather than finishing.
  final bool truncated;
  const LlmResult(this.text, this.promptTokens, this.tokens, this.truncated);
}

/// A running generation. [text] streams the reply as it's written;
/// [result] completes with all of it, or an [LlmException].
class LlmJob {
  LlmJob._(this.text, this.result, this._progress, this._cancel);
  final Stream<String> text;
  final Future<LlmResult> result;
  final double Function() _progress;
  final void Function() _cancel;

  /// How much of the prompt has been read, 0.0–1.0. Writing starts at 1.0.
  double get promptProgress => _progress();
  void cancel() => _cancel();
}

class LocalLlm {
  LocalLlm._();

  /// Why on-device AI can't run on this phone, or null if it can.
  static final String? unsupportedReason = _checkSupport();

  static String? _checkSupport() {
    if (!Platform.isAndroid) return 'On-device AI needs Android.';
    if (Abi.current() != Abi.androidArm64 && Abi.current() != Abi.androidX64) {
      return 'On-device AI needs a 64-bit phone.';
    }
    if (Abi.current() == Abi.androidArm64 && !_cpuHasFp16()) {
      return "This phone's CPU lacks ARMv8.2 FP16 support, which on-device "
          'AI requires. Use a chat API URL instead.';
    }
    try {
      _bindings;
    } catch (e) {
      return 'Native library failed to load: $e';
    }
    return null;
  }

  static bool _cpuHasFp16() {
    try {
      final info = File('/proc/cpuinfo').readAsStringSync();
      return RegExp(r'^Features\s*:.*\basimdhp\b', multiLine: true)
          .hasMatch(info);
    } catch (_) {
      return false;
    }
  }

  /// Runs [messages] (role, content) through the GGUF chat model at
  /// [modelPath]. The prompt plus [maxTokens] must fit in [maxContext]
  /// tokens, else [result] fails with [LlmException.tooLong].
  static LlmJob generate({
    required String modelPath,
    required List<(String, String)> messages,
    int maxContext = 8192,
    int maxTokens = 1024,
    double temperature = 0.3,
    int threads = 4,
  }) {
    final b = _bindings;
    final job = b.jobNew();
    final jobAddress = job.address;
    final controller = StreamController<String>();
    var done = false;

    void drain() {
      final s = b.take(job);
      if (s.isNotEmpty) controller.add(s);
    }

    final timer =
        Timer.periodic(const Duration(milliseconds: 100), (_) => drain());

    final future = _runInIsolate(modelPath, messages, maxContext, maxTokens,
            temperature, threads, jobAddress)
        .then((json) {
      final map = Map<String, dynamic>.from(jsonDecode(json) as Map);
      final error = map['error'];
      if (error != null) {
        throw LlmException(error.toString(),
            promptTokens: map['prompt_tokens'] as int?,
            maxPrompt: map['max_prompt'] as int?);
      }
      return LlmResult(
        map['text'] as String? ?? '',
        map['prompt_tokens'] as int? ?? 0,
        map['tokens'] as int? ?? 0,
        map['truncated'] == true,
      );
    }).whenComplete(() {
      done = true;
      timer.cancel();
      drain();
      b.jobFree(job);
    });
    future.then((_) => controller.close(), onError: (Object e) {
      controller.addError(e);
      controller.close();
    });

    return LlmJob._(
      controller.stream,
      future,
      () => done ? 1.0 : b.jobProgress(job) / 1000,
      () {
        if (!done) b.jobCancel(job);
      },
    );
  }

  /// Frees the model's memory; the next [generate] loads it again.
  static Future<void> unload() => Isolate.run(_unloadSync);
}

void _unloadSync() => _Bindings(DynamicLibrary.open(_libName)).unload();

// Top-level so the isolate closure captures only these sendable values.
Future<String> _runInIsolate(
        String model,
        List<(String, String)> messages,
        int maxContext,
        int maxTokens,
        double temperature,
        int threads,
        int jobAddress) =>
    Isolate.run(() => _generateSync(model, messages, maxContext, maxTokens,
        temperature, threads, jobAddress));

String _generateSync(String model, List<(String, String)> messages,
    int maxContext, int maxTokens, double temperature, int threads,
    int jobAddress) {
  final b = _Bindings(DynamicLibrary.open(_libName));
  final m = model.toNativeUtf8();
  final roles = malloc<Pointer<Utf8>>(messages.length);
  final contents = malloc<Pointer<Utf8>>(messages.length);
  for (var i = 0; i < messages.length; i++) {
    roles[i] = messages[i].$1.toNativeUtf8();
    contents[i] = messages[i].$2.toNativeUtf8();
  }
  try {
    final r = b.generate(m, roles, contents, messages.length, maxContext,
        maxTokens, temperature, threads, Pointer.fromAddress(jobAddress));
    final s = _utf8(r);
    b.freeString(r);
    return s;
  } finally {
    for (var i = 0; i < messages.length; i++) {
      malloc.free(roles[i]);
      malloc.free(contents[i]);
    }
    malloc.free(roles);
    malloc.free(contents);
    malloc.free(m);
  }
}
