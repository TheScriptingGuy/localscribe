import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import '../../models/ai_config.dart';
import '../ai/ai_types.dart';
import '../transcription/transcriber.dart';
import 'diarizer.dart';

/// Speaker recognition on a self-hosted server (server/diarization/):
/// `POST <base>/diarize` multipart `file` [+ `num_speakers`] returns
/// `{"segments":[{"start":0.0,"end":6.8,"speaker":0}, …]}`.
class RemoteDiarizer implements Diarizer {
  final RemoteDiarizationConfig config;
  final Dio _dio;

  RemoteDiarizer(this.config, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 30),
            ));

  @override
  String get name => 'Speaker API';

  String get _endpoint {
    final base = config.baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
    return base.endsWith('/diarize') ? base : '$base/diarize';
  }

  @override
  Future<List<SpeakerTurn>> diarize(
    File audio, {
    int numSpeakers = 0,
    void Function(double progress)? onProgress,
    CancelSignal? cancel,
  }) async {
    final form = FormData.fromMap({
      if (numSpeakers > 0) 'num_speakers': numSpeakers.toString(),
      'file':
          await MultipartFile.fromFile(audio.path, filename: p.basename(audio.path)),
    });
    final token = CancelToken();
    cancel?.onCancel(token.cancel);
    try {
      final resp = await _dio.post(
        _endpoint,
        data: form,
        cancelToken: token,
        // Upload is the part we can measure; the server reports no progress.
        onSendProgress: (sent, total) {
          if (total > 0) onProgress?.call(0.9 * sent / total);
        },
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
      final detail = e.response?.data is Map ? (e.response!.data as Map)['detail'] : null;
      throw AiException(
        'Speaker recognition request failed: ${detail ?? e.message}',
        statusCode: e.response?.statusCode,
      );
    }
  }

  List<SpeakerTurn> _parse(dynamic data) {
    final segments = data is Map ? data['segments'] : null;
    if (segments is! List) {
      throw AiException('Speaker API returned no "segments" list.');
    }
    return [
      for (final s in segments)
        if (s is Map)
          SpeakerTurn(
            (s['start'] as num? ?? 0).toDouble(),
            (s['end'] as num? ?? 0).toDouble(),
            '${s['speaker']}',
          ),
    ];
  }
}
