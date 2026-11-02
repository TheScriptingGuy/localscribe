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
    Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Float>, Int32, Pointer<Void>);
typedef _TranscribeDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Float>, int, Pointer<Void>);
typedef _DecodeFn = Pointer<Utf8> Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Void>);

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
        jobCancelled = lib.lookupFunction<Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)>('ls_job_cancelled'),
        jobSetProgress = lib.lookupFunction<
            Void Function(Pointer<Void>, Int32),
            void Function(Pointer<Void>, int)>('ls_job_set_progress'),
        decode = lib.lookupFunction<_DecodeFn, _DecodeFn>('ls_decode'),
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
  final int Function(Pointer<Void>) jobCancelled;
  final void Function(Pointer<Void>, int) jobSetProgress;
  final _DecodeFn decode;
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
/// (`language`, `segments: [{start, end, text, words}]`; with ranges
/// `pieces: [{language, segments}]`) or a [WhisperException].
class WhisperJob {
  WhisperJob._(this.result, this._cancel);
  final Future<Map<String, dynamic>> result;
  final void Function() _cancel;
  void cancel() => _cancel();
}

/// A progress/cancel handle that background isolates reach by [address]
/// (pointers can't be sent between isolates, addresses can).
class NativeJob {
  NativeJob() : _ptr = _bindings.jobNew();
  final Pointer<Void> _ptr;

  int get address => _ptr.address;

  /// 0.0–1.0, as last reported by the worker.
  double get progress => _bindings.jobProgress(_ptr) / 1000;
  void cancel() => _bindings.jobCancel(_ptr);
  void free() => _bindings.jobFree(_ptr);

  static void setProgress(int address, double progress) =>
      _bindings.jobSetProgress(
          Pointer.fromAddress(address), (progress * 1000).round());

  static bool isCancelled(int address) =>
      _bindings.jobCancelled(Pointer.fromAddress(address)) != 0;
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

  /// Decodes [audioPath] to 16 kHz mono 16-bit PCM at [pcmPath] and returns
  /// the number of samples; the caller deletes the file. Reports progress to
  /// the job at [jobAddress] as 0–0.1. Blocking: call from a background
  /// isolate. Throws [WhisperException] (`cancelled` after a cancel).
  static int decodeToPcmSync({
    required String audioPath,
    required String pcmPath,
    required int jobAddress,
  }) {
    final a = audioPath.toNativeUtf8();
    final pcm = pcmPath.toNativeUtf8();
    try {
      final r = _bindings.decode(a, pcm, Pointer.fromAddress(jobAddress));
      final json = r.toDartString();
      _bindings.freeString(r);
      final map = jsonDecode(json) as Map;
      if (map['error'] != null) throw WhisperException(map['error'].toString());
      return (map['samples'] as num).toInt();
    } finally {
      malloc.free(a);
      malloc.free(pcm);
    }
  }

  /// whisper.cpp/ggml build flags, e.g. "NEON = 1 | ARM_FMA = 1 | FP16_VA = 1".
  static String systemInfo() => _bindings.systemInfo().toDartString();

  /// Transcribes [audioPath] with the GGML model at [modelPath]. [scratchPath]
  /// receives the decoded PCM temporarily. [onProgress] gets 0.0–1.0.
  ///
  /// With [ranges] (start s, end s, speaker index) only those stretches are
  /// transcribed, each detecting its own language; see `pieces` in the result.
  static WhisperJob transcribe({
    required String modelPath,
    required String audioPath,
    required String scratchPath,
    String language = 'auto',
    int threads = 4,
    List<(double, double, int)>? ranges,
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

    final future = _runInIsolate(modelPath, audioPath, scratchPath, language,
            threads, ranges ?? const [], jobAddress)
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
        String language, int threads, List<(double, double, int)> ranges,
        int jobAddress) =>
    Isolate.run(() => _transcribeSync(
        model, audio, scratch, language, threads, ranges, jobAddress));

String _transcribeSync(String model, String audio, String scratch,
    String language, int threads, List<(double, double, int)> ranges,
    int jobAddress) {
  final b = _Bindings(DynamicLibrary.open(_libName));
  final m = model.toNativeUtf8();
  final a = audio.toNativeUtf8();
  final s = scratch.toNativeUtf8();
  final l = language.toNativeUtf8();
  final rs = malloc<Float>(ranges.isEmpty ? 1 : ranges.length * 3);
  for (var i = 0; i < ranges.length; i++) {
    final (start, end, speaker) = ranges[i];
    rs[3 * i] = start;
    rs[3 * i + 1] = end;
    rs[3 * i + 2] = speaker.toDouble();
  }
  try {
    final r = b.transcribe(m, a, s, l, threads, rs, ranges.length,
        Pointer.fromAddress(jobAddress));
    // Segment boundaries can split a multi-byte character; don't throw on it.
    final bytes = Uint8List.fromList(r.cast<Uint8>().asTypedList(r.length));
    b.freeString(r);
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    malloc.free(m);
    malloc.free(a);
    malloc.free(s);
    malloc.free(l);
    malloc.free(rs);
  }
}
