import 'package:flutter_test/flutter_test.dart';
import 'package:localscribe/services/models/whisper_models.dart';
import 'package:localscribe/services/transcription/live_captioner.dart';

void main() {
  bool Function(WhisperModel) have(List<String> files) =>
      (m) => files.contains(m.file);

  test('live captions prefer a fast model over the transcription model', () {
    expect(
        liveCaptionModel('ggml-small-q5_1.bin',
                have(['ggml-small-q5_1.bin', 'ggml-base-q5_1.bin']))
            ?.file,
        'ggml-base-q5_1.bin');
    expect(
        liveCaptionModel('ggml-small-q5_1.bin',
                have(['ggml-small-q5_1.bin', 'ggml-tiny-q5_1.bin']))
            ?.file,
        'ggml-tiny-q5_1.bin');
  });

  test('falls back to the transcription model, or none', () {
    expect(
        liveCaptionModel('ggml-small-q5_1.bin', have(['ggml-small-q5_1.bin']))
            ?.file,
        'ggml-small-q5_1.bin');
    expect(liveCaptionModel('ggml-small-q5_1.bin', have([])), isNull);
  });
}
