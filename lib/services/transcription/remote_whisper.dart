import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:localscribe_native/localscribe_native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/ai_config.dart';
import '../ai/ai_types.dart';
import '../diarization/speaker_merge.dart';
import 'transcriber.dart';

/// Transcribes via an OpenAI-compatible `/audio/transcriptions` endpoint.
///
/// Works with OpenAI Whisper, Groq, and any self-hosted whisper.cpp /
/// faster-whisper HTTP server that implements the same multipart shape.
class RemoteWhisperTranscriber implements Transcriber {
  final RemoteWhisperConfig config;
  final Dio _dio;

  RemoteWhisperTranscriber(this.config, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 10),
            ));

  @override
  String get name => 'Whisper API (${_host()})';

  String _host() {
    try {
      return Uri.parse(config.baseUrl).host;
    } catch (_) {
      return config.baseUrl;
    }
  }

  String get _endpoint {
    final base = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    return '$base/audio/transcriptions';
  }

  @override
  Future<TranscriptResult> transcribe(
    File audio, {
    String? language,
    void Function(double progress)? onProgress,
    CancelSignal? cancel,
  }) async {
    if (!await audio.exists()) {
      throw AiException('Audio file not found: ${audio.path}');
    }
    return _post(
      await MultipartFile.fromFile(audio.path,
          filename: p.basename(audio.path)),
      language: language,
      cancel: cancel,
    );
  }

  /// Decodes the audio on the phone, then uploads each piece as a small WAV
  /// so the server detects the language per speaker turn. Short turns are
  /// sent with the language their speaker used in longer ones.
  @override
  Future<TranscriptResult> transcribePieces(
    File audio,
    List<SpeakerPiece> pieces, {
    void Function(double progress)? onProgress,
    CancelSignal? cancel,
  }) async {
    if (pieces.isEmpty) return const TranscriptResult(text: '');
    if (!await audio.exists()) {
      throw AiException('Audio file not found: ${audio.path}');
    }
    final tmp = await getTemporaryDirectory();
    final pcmPath = p.join(
        tmp.path, 'pieces-${DateTime.now().microsecondsSinceEpoch}.pcm');
    final job = NativeJob();
    cancel?.onCancel(job.cancel);
    try {
      try {
        await _decode(audio.path, pcmPath, job.address);
      } on WhisperException catch (e) {
        throw AiException(e.cancelled ? 'Cancelled' : e.message,
            cancelled: e.cancelled);
      }
      onProgress?.call(0.1);
      final pcm = await File(pcmPath).readAsBytes();

      // Long turns first, so a short reply can reuse its speaker's language.
      bool long(int i) => pieces[i].duration >= _shortTurn;
      final order = [
        for (var i = 0; i < pieces.length; i++) if (long(i)) i,
        for (var i = 0; i < pieces.length; i++) if (!long(i)) i,
      ];
      final total = pieces.fold<double>(0, (t, x) => t + x.duration);
      final speakerLanguage = <String, String>{};
      final results =
          List<({String? language, List<TranscriptSegment> segments})>.filled(
              pieces.length, (language: null, segments: const []));
      var done = 0.0;
      for (final i in order) {
        if (cancel?.isCancelled ?? false) {
          throw AiException('Cancelled', cancelled: true);
        }
        final piece = pieces[i];
        final r = await _post(
          MultipartFile.fromBytes(_wavSlice(pcm, piece.start, piece.end),
              filename: 'turn-$i.wav'),
          language: long(i) ? null : speakerLanguage[piece.speaker],
          cancel: cancel,
        );
        final language = _isoCode(r.language);
        if (long(i) && language != null) {
          speakerLanguage[piece.speaker] = language;
        }
        final segments = r.segments.isNotEmpty
            ? r.segments
            : [TranscriptSegment(start: 0, end: piece.duration, text: r.text)];
        results[i] = (
          language: language,
          segments: [
            for (final s in segments)
              if (s.text.isNotEmpty)
                TranscriptSegment(
                  start: piece.start + s.start,
                  end: piece.start + s.end,
                  text: s.text,
                ),
          ],
        );
        done += piece.duration;
        onProgress?.call(0.1 + 0.9 * done / total);
      }
      return joinPieces(pieces, results);
    } finally {
      job.free();
      final f = File(pcmPath);
      if (await f.exists()) await f.delete();
    }
  }

  static const _shortTurn = 3.0; // seconds; too short to detect a language

  Future<TranscriptResult> _post(
    MultipartFile file, {
    String? language,
    CancelSignal? cancel,
  }) async {
    final form = FormData.fromMap({
      'model': config.model,
      // verbose_json yields per-segment timings when the server supports it.
      'response_format': 'verbose_json',
      if (language != null && language.isNotEmpty) 'language': language,
      'file': file,
    });

    final token = CancelToken();
    cancel?.onCancel(token.cancel);
    try {
      final resp = await _dio.post(
        _endpoint,
        data: form,
        cancelToken: token,
        options: Options(
          headers: {
            if (config.apiKey.isNotEmpty)
              'Authorization': 'Bearer ${config.apiKey}',
          },
          responseType: ResponseType.json,
        ),
      );
      return _parse(resp.data);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        throw AiException('Cancelled', cancelled: true);
      }
      throw AiException(
        'Transcription request failed: ${e.message}',
        statusCode: e.response?.statusCode,
      );
    }
  }

  TranscriptResult _parse(dynamic data) {
    // Some servers return plain text; handle both.
    if (data is String) {
      return TranscriptResult(text: data.trim());
    }
    final map = Map<String, dynamic>.from(data as Map);
    final text = (map['text'] ?? '').toString().trim();
    final segments = <TranscriptSegment>[];
    if (map['segments'] is List) {
      for (final s in (map['segments'] as List)) {
        final sm = Map<String, dynamic>.from(s as Map);
        segments.add(TranscriptSegment(
          start: (sm['start'] ?? 0).toDouble(),
          end: (sm['end'] ?? 0).toDouble(),
          text: (sm['text'] ?? '').toString().trim(),
        ));
      }
    }
    return TranscriptResult(
      text: text,
      segments: segments,
      language: map['language']?.toString(),
    );
  }

  /// OpenAI's verbose_json names the language ("german"); whisper.cpp
  /// servers give the code ("de"). Requests want the code.
  static String? _isoCode(String? language) {
    if (language == null || language.isEmpty) return null;
    final l = language.toLowerCase();
    return l.length <= 3 ? l : _languageCodes[l];
  }

  static const _languageCodes = {
    'english': 'en', 'dutch': 'nl', 'german': 'de', 'french': 'fr',
    'spanish': 'es', 'italian': 'it', 'portuguese': 'pt', 'polish': 'pl',
    'swedish': 'sv', 'danish': 'da', 'norwegian': 'no', 'finnish': 'fi',
    'turkish': 'tr', 'russian': 'ru', 'ukrainian': 'uk', 'chinese': 'zh',
    'japanese': 'ja', 'korean': 'ko', 'arabic': 'ar', 'hindi': 'hi',
    'czech': 'cs', 'greek': 'el', 'hungarian': 'hu', 'romanian': 'ro',
    'indonesian': 'id', 'vietnamese': 'vi', 'thai': 'th', 'hebrew': 'he',
  };

  /// Seconds [start, end) of 16 kHz mono 16-bit [pcm] as a WAV file.
  static Uint8List _wavSlice(Uint8List pcm, double start, double end) {
    const rate = 16000;
    final samples = pcm.length ~/ 2;
    final from = (start * rate).round().clamp(0, samples);
    final to = (end * rate).round().clamp(from, samples);
    final data = Uint8List.sublistView(pcm, from * 2, to * 2);
    final header = ByteData(44)
      ..setUint32(0, 0x52494646) // "RIFF"
      ..setUint32(4, 36 + data.length, Endian.little)
      ..setUint32(8, 0x57415645) // "WAVE"
      ..setUint32(12, 0x666d7420) // "fmt "
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little) // PCM
      ..setUint16(22, 1, Endian.little) // mono
      ..setUint32(24, rate, Endian.little)
      ..setUint32(28, rate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little)
      ..setUint32(36, 0x64617461) // "data"
      ..setUint32(40, data.length, Endian.little);
    return (BytesBuilder(copy: false)
          ..add(header.buffer.asUint8List())
          ..add(data))
        .takeBytes();
  }
}

// Top-level so the isolate closure captures only these sendable values.
Future<int> _decode(String audio, String pcm, int job) => Isolate.run(() =>
    LocalScribeNative.decodeToPcmSync(
        audioPath: audio, pcmPath: pcm, jobAddress: job));
