import 'model_manager.dart';

/// A GGUF chat model for on-device notes and Ask-AI (llama.cpp).
class LlmModel extends DownloadableModel {
  /// Most tokens (prompt + reply) to use on a phone. Longer transcripts are
  /// condensed part by part first. Bounded by the memory the KV cache takes.
  final int contextTokens;

  /// Qwen3 reasons in a <think> block first unless told not to.
  final bool thinks;

  const LlmModel({
    required super.file,
    required super.label,
    required super.note,
    required super.bytes,
    required super.sha256,
    required super.baseUrl,
    required this.contextTokens,
    this.thinks = false,
  });
}

/// Instruction-tuned models in Q4_K_M from the publishers' own Hugging Face
/// repositories. Sizes and SHA-256 digests are from Hugging Face. Qwen is
/// used for its multilingual ability (Dutch, German, …) at small sizes.
const llmModels = <LlmModel>[
  LlmModel(
    file: 'qwen2.5-0.5b-instruct-q4_k_m.gguf',
    label: 'Qwen2.5 0.5B',
    note: 'Fastest; short, basic summaries',
    bytes: 491400032,
    sha256: '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db',
    baseUrl: 'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main',
    contextTokens: 16384,
  ),
  LlmModel(
    file: 'qwen2.5-1.5b-instruct-q4_k_m.gguf',
    label: 'Qwen2.5 1.5B',
    note: 'Recommended for phones with 4 GB RAM',
    bytes: 1117320736,
    sha256: '6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e',
    baseUrl: 'https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main',
    contextTokens: 16384,
  ),
  LlmModel(
    file: 'qwen2.5-3b-instruct-q4_k_m.gguf',
    label: 'Qwen2.5 3B',
    note: 'Better notes; needs 6 GB RAM. Non-commercial licence',
    bytes: 2104932768,
    sha256: '626b4a6678b86442240e33df819e00132d3ba7dddfe1cdc4fbb18e0a9615c62d',
    baseUrl: 'https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main',
    contextTokens: 16384,
  ),
  LlmModel(
    file: 'Qwen3-4B-Q4_K_M.gguf',
    label: 'Qwen3 4B',
    note: 'Best notes; slow, needs 8 GB RAM',
    bytes: 2497280256,
    sha256: '7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5',
    baseUrl: 'https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/main',
    contextTokens: 8192,
    thinks: true,
  ),
];

class LlmModelManager extends ModelManager<LlmModel> {
  LlmModelManager() : super('llm', llmModels);
}
