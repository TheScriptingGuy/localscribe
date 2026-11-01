// Configuration for the two AI pipelines (transcription + note/chat).
// Each pipeline is either on-device or pointed at a custom API URL.

/// Which wire protocol a remote chat/note endpoint speaks.
enum ChatApiFlavor {
  /// OpenAI-compatible `/chat/completions` — also Ollama, LM Studio,
  /// llama.cpp server, vLLM, LocalAI, OpenRouter, Groq, …
  openai,

  /// Anthropic `/v1/messages`.
  anthropic,
}

extension ChatApiFlavorLabel on ChatApiFlavor {
  String get label => switch (this) {
        ChatApiFlavor.openai => 'OpenAI-compatible',
        ChatApiFlavor.anthropic => 'Anthropic (Claude)',
      };
}

/// Remote chat/note endpoint: base URL + key + model + flavor.
class RemoteChatConfig {
  String baseUrl;
  String apiKey;
  String model;
  ChatApiFlavor flavor;

  RemoteChatConfig({
    this.baseUrl = 'https://api.openai.com/v1',
    this.apiKey = '',
    this.model = 'gpt-4o-mini',
    this.flavor = ChatApiFlavor.openai,
  });

  RemoteChatConfig copy() => RemoteChatConfig(
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: model,
        flavor: flavor,
      );

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'flavor': flavor.name,
      };

  factory RemoteChatConfig.fromJson(Map<String, dynamic> j) => RemoteChatConfig(
        baseUrl: j['baseUrl'] ?? 'https://api.openai.com/v1',
        apiKey: j['apiKey'] ?? '',
        model: j['model'] ?? 'gpt-4o-mini',
        flavor: ChatApiFlavor.values.firstWhere(
          (f) => f.name == j['flavor'],
          orElse: () => ChatApiFlavor.openai,
        ),
      );
}

/// Remote Whisper-compatible transcription endpoint (OpenAI audio API shape).
class RemoteWhisperConfig {
  String baseUrl;
  String apiKey;
  String model;

  RemoteWhisperConfig({
    this.baseUrl = 'https://api.openai.com/v1',
    this.apiKey = '',
    this.model = 'whisper-1',
  });

  RemoteWhisperConfig copy() =>
      RemoteWhisperConfig(baseUrl: baseUrl, apiKey: apiKey, model: model);

  Map<String, dynamic> toJson() =>
      {'baseUrl': baseUrl, 'apiKey': apiKey, 'model': model};

  factory RemoteWhisperConfig.fromJson(Map<String, dynamic> j) =>
      RemoteWhisperConfig(
        baseUrl: j['baseUrl'] ?? 'https://api.openai.com/v1',
        apiKey: j['apiKey'] ?? '',
        model: j['model'] ?? 'whisper-1',
      );
}

/// Transcription pipeline config: on-device whisper.cpp OR a remote URL.
class TranscriptionConfig {
  bool onDevice;
  String localModel; // whisper.cpp GGML model id/path (Phase 3)
  RemoteWhisperConfig remote;

  TranscriptionConfig({
    this.onDevice = false,
    this.localModel = 'ggml-base.bin',
    RemoteWhisperConfig? remote,
  }) : remote = remote ?? RemoteWhisperConfig();

  Map<String, dynamic> toJson() => {
        'onDevice': onDevice,
        'localModel': localModel,
        'remote': remote.toJson(),
      };

  factory TranscriptionConfig.fromJson(Map<String, dynamic> j) =>
      TranscriptionConfig(
        onDevice: j['onDevice'] ?? false,
        localModel: j['localModel'] ?? 'ggml-base.bin',
        remote: j['remote'] != null
            ? RemoteWhisperConfig.fromJson(
                Map<String, dynamic>.from(j['remote']))
            : RemoteWhisperConfig(),
      );
}

/// Note/chat pipeline config: on-device llama.cpp OR a remote URL.
class NoteAiConfig {
  bool onDevice;
  String localModel; // llama.cpp GGUF model id/path (Phase 4)
  RemoteChatConfig remote;

  NoteAiConfig({
    this.onDevice = false,
    this.localModel = '',
    RemoteChatConfig? remote,
  }) : remote = remote ?? RemoteChatConfig();

  Map<String, dynamic> toJson() => {
        'onDevice': onDevice,
        'localModel': localModel,
        'remote': remote.toJson(),
      };

  factory NoteAiConfig.fromJson(Map<String, dynamic> j) => NoteAiConfig(
        onDevice: j['onDevice'] ?? false,
        localModel: j['localModel'] ?? '',
        remote: j['remote'] != null
            ? RemoteChatConfig.fromJson(Map<String, dynamic>.from(j['remote']))
            : RemoteChatConfig(),
      );
}
