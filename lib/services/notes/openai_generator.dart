import 'dart:convert';
import 'package:dio/dio.dart';

import '../../models/ai_config.dart';
import '../ai/ai_types.dart';
import 'note_generator.dart';

/// OpenAI-compatible `/chat/completions` client. Also covers Ollama, LM Studio,
/// llama.cpp server, vLLM, LocalAI, OpenRouter, Groq — just change the base URL.
class OpenAiChatGenerator implements NoteGenerator {
  final RemoteChatConfig config;
  final Dio _dio;

  OpenAiChatGenerator(this.config, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 5),
            ));

  @override
  String get name => 'OpenAI-compatible (${config.model})';

  String get _endpoint =>
      '${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (config.apiKey.isNotEmpty) 'Authorization': 'Bearer ${config.apiKey}',
      };

  List<Map<String, String>> _messages(List<ChatMessage> m) => m
      .map((e) => {'role': e.role.name, 'content': e.content})
      .toList(growable: false);

  @override
  Future<String> complete(List<ChatMessage> messages) async {
    try {
      final resp = await _dio.post(
        _endpoint,
        data: {
          'model': config.model,
          'messages': _messages(messages),
          'stream': false,
        },
        options: Options(headers: _headers, responseType: ResponseType.json),
      );
      final map = Map<String, dynamic>.from(resp.data as Map);
      final choices = map['choices'] as List?;
      if (choices == null || choices.isEmpty) {
        throw AiException('Empty response from chat endpoint');
      }
      final msg = Map<String, dynamic>.from(choices.first['message'] as Map);
      return (msg['content'] ?? '').toString();
    } on DioException catch (e) {
      throw AiException('Chat request failed: ${e.message}',
          statusCode: e.response?.statusCode);
    }
  }

  @override
  Stream<String> stream(List<ChatMessage> messages) async* {
    final resp = await _dio.post<ResponseBody>(
      _endpoint,
      data: {
        'model': config.model,
        'messages': _messages(messages),
        'stream': true,
      },
      options: Options(
        headers: _headers,
        responseType: ResponseType.stream,
      ),
    );
    final stream = resp.data!.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in stream) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty || payload == '[DONE]') continue;
      try {
        final obj = jsonDecode(payload) as Map<String, dynamic>;
        final delta = (obj['choices'] as List?)?.first?['delta']
            as Map<String, dynamic>?;
        final piece = delta?['content'];
        if (piece is String && piece.isNotEmpty) yield piece;
      } catch (_) {
        // Ignore keep-alive / malformed partial lines.
      }
    }
  }
}
