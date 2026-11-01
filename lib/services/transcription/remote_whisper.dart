import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../models/ai_config.dart';
import '../ai/ai_types.dart';
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
    final form = FormData.fromMap({
      'model': config.model,
      // verbose_json yields per-segment timings when the server supports it.
      'response_format': 'verbose_json',
      if (language != null && language.isNotEmpty) 'language': language,
      'file': await MultipartFile.fromFile(
        audio.path,
        filename: p.basename(audio.path),
      ),
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
}
