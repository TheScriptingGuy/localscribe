import 'dart:convert';
import 'package:dio/dio.dart';

import '../../models/ai_config.dart';
import '../ai/ai_types.dart';
import 'note_generator.dart';

/// Anthropic `/v1/messages` client (Claude). System messages are hoisted into
/// the top-level `system` field as the Messages API requires.
class AnthropicChatGenerator implements NoteGenerator {
  final RemoteChatConfig config;
  final Dio _dio;

  AnthropicChatGenerator(this.config, {Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 30),
              receiveTimeout: const Duration(minutes: 5),
            ));

  @override
  String get name => 'Anthropic (${config.model})';

  String get _endpoint =>
      '${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/v1/messages';

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'anthropic-version': '2023-06-01',
        if (config.apiKey.isNotEmpty) 'x-api-key': config.apiKey,
      };

  (String?, List<Map<String, String>>) _split(List<ChatMessage> m) {
    final sys = m
        .where((e) => e.role == ChatRole.system)
        .map((e) => e.content)
        .join('\n\n');
    final turns = m
        .where((e) => e.role != ChatRole.system)
        .map((e) => {'role': e.role.name, 'content': e.content})
        .toList();
    return (sys.isEmpty ? null : sys, turns);
  }

  @override
  Future<String> complete(List<ChatMessage> messages) async {
    final (system, turns) = _split(messages);
    try {
      final resp = await _dio.post(
        _endpoint,
        data: {
          'model': config.model,
          'max_tokens': 4096,
          if (system != null) 'system': system,
          'messages': turns,
        },
        options: Options(headers: _headers, responseType: ResponseType.json),
      );
      final map = Map<String, dynamic>.from(resp.data as Map);
      final content = map['content'] as List?;
      if (content == null || content.isEmpty) {
        throw AiException('Empty response from Anthropic endpoint');
      }
      // Concatenate all text blocks.
      return content
          .whereType<Map>()
          .where((b) => b['type'] == 'text')
          .map((b) => b['text'] ?? '')
          .join();
    } on DioException catch (e) {
      throw AiException('Claude request failed: ${e.message}',
          statusCode: e.response?.statusCode);
    }
  }

  @override
  Stream<String> stream(List<ChatMessage> messages) async* {
    final (system, turns) = _split(messages);
    final resp = await _dio.post<ResponseBody>(
      _endpoint,
      data: {
        'model': config.model,
        'max_tokens': 4096,
        'stream': true,
        if (system != null) 'system': system,
        'messages': turns,
      },
      options: Options(headers: _headers, responseType: ResponseType.stream),
    );
    final lines = resp.data!.stream
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());

    await for (final line in lines) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      try {
        final obj = jsonDecode(payload) as Map<String, dynamic>;
        if (obj['type'] == 'content_block_delta') {
          final delta = obj['delta'] as Map<String, dynamic>?;
          final piece = delta?['text'];
          if (piece is String && piece.isNotEmpty) yield piece;
        }
      } catch (_) {
        // Ignore non-JSON event lines.
      }
    }
  }
}
