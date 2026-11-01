/// Dart FFI bindings for liblocalscribe_native.so (whisper.cpp + Android
/// MediaCodec decoding). The blocking native call runs in a background
/// isolate; progress and cancellation go through a shared native job handle.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const _libName = 'liblocalscribe_native.so';

typedef _TranscribeC = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Void>);
typedef _TranscribeDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Void>);

final class _Bindings {
  _Bindings(DynamicLibrary lib)
      : jobNew = lib.lookupFunction<Pointer<Void> Function(),
            Pointer<Void> Function()>('ls_job_new'),
        jobProgress = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('ls_job_progress'),
        jobCancel = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('ls_job_cancel'),
        jobFree = lib.lookupFunction<Void Function(Pointer<Void>),
            void Function(Pointer<Void>)>('ls_job_free'),
        freeString = lib.lookupFunction<Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)>('ls_free_string'),
        systemInfo = lib.lookupFunction<Pointer<Utf8> Function(),
            Pointer<Utf8> Function()>('ls_system_info'),
        transcribe =
            lib.lookupFunction<_TranscribeC, _TranscribeDart>('ls_transcribe');

  final Pointer<Void> Function() jobNew;
  final int Function(Pointer<Void>) jobProgress;
  final void Function(Pointer<Void>) jobCancel;
  final void Function(Pointer<Void>) jobFree;
  final void Function(Pointer<Utf8>) freeString;
  final Pointer<Utf8> Function() systemInfo;
  final _TranscribeDart transcribe;
}

_Bindings? _cached;
_Bindings get _bindings => _cached ??= _Bindings(DynamicLibrary.open(_libName));

class WhisperException implements Exception {
  final String message;
  WhisperException(this.message);
  bool get cancelled => message == 'cancelled';
  @override
  String toString() => 'WhisperException($message)';
}

/// A running transcription. [result] completes with the decoded JSON map
/// (`language`, `segments: [{start, end, text}]`) or a [WhisperException].
class WhisperJob {
  WhisperJob._(this.result, this._cancel);
  final Future<Map<String, dynamic>> result;
  final void Function() _cancel;
  void cancel() => _cancel();
}

class LocalScribeNative {
  LocalScribeNative._();

  /// Why on-device transcription can't run on this phone, or null if it can.
  static final String? unsupportedReason = _checkSupport();

  static String? _checkSupport() {
    if (!Platform.isAndroid) return 'On-device transcription needs Android.';
    if (Abi.current() == Abi.androidArm64 && !_cpuHasFp16()) {
      return "This phone's CPU lacks ARMv8.2 FP16 support, which the "
          'on-device build requires. Use a Whisper API URL instead.';
    }
    if (Abi.current() != Abi.androidArm64 && Abi.current() != Abi.androidX64) {
      return 'On-device transcription needs a 64-bit phone.';
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

  /// whisper.cpp/ggml build flags, e.g. "NEON = 1 | ARM_FMA = 1 | FP16_VA = 1".
  static String systemInfo() => _bindings.systemInfo().toDartString();

  /// Transcribes [audioPath] with the GGML model at [modelPath]. [scratchPath]
  /// receives the decoded PCM temporarily. [onProgress] gets 0.0–1.0.
  static WhisperJob transcribe({
    required String modelPath,
    required String audioPath,
    required String scratchPath,
    String language = 'auto',
    int threads = 4,
    void Function(double progress)? onProgress,
  }) {
    final b = _bindings;
    final job = b.jobNew();
    final jobAddress = job.address;
    var done = false;

    final timer = onProgress == null
        ? null
        : Timer.periodic(const Duration(milliseconds: 400), (_) {
            if (!done) onProgress(b.jobProgress(job) / 1000);
          });

    final future = _runInIsolate(
            modelPath, audioPath, scratchPath, language, threads, jobAddress)
        .then((json) {
      final map = Map<String, dynamic>.from(jsonDecode(json) as Map);
      if (map['error'] != null) throw WhisperException(map['error'].toString());
      return map;
    }).whenComplete(() {
      done = true;
      timer?.cancel();
      b.jobFree(job);
    });

    return WhisperJob._(future, () {
      if (!done) b.jobCancel(job);
    });
  }
}

// Kept separate so the isolate closure captures only these sendable values,
// not the timer/bindings in transcribe()'s scope.
Future<String> _runInIsolate(String model, String audio, String scratch,
        String language, int threads, int jobAddress) =>
    Isolate.run(() =>
        _transcribeSync(model, audio, scratch, language, threads, jobAddress));

String _transcribeSync(String model, String audio, String scratch,
    String language, int threads, int jobAddress) {
  final b = _Bindings(DynamicLibrary.open(_libName));
  final m = model.toNativeUtf8();
  final a = audio.toNativeUtf8();
  final s = scratch.toNativeUtf8();
  final l = language.toNativeUtf8();
  try {
    final r = b.transcribe(m, a, s, l, threads, Pointer.fromAddress(jobAddress));
    // Segment boundaries can split a multi-byte character; don't throw on it.
    final bytes = Uint8List.fromList(r.cast<Uint8>().asTypedList(r.length));
    b.freeString(r);
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    malloc.free(m);
    malloc.free(a);
    malloc.free(s);
    malloc.free(l);
  }
}
