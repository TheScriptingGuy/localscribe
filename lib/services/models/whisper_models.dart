import 'model_manager.dart';

export 'model_manager.dart' show ModelDownload;

/// Where GGML whisper models are downloaded from (the whisper.cpp project's
/// official model repository on Hugging Face).
const whisperModelBaseUrl =
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';

class WhisperModel extends DownloadableModel {
  const WhisperModel(
      String file, String label, String note, int bytes, String sha256)
      : super(
          file: file,
          label: label,
          note: note,
          bytes: bytes,
          sha256: sha256,
          baseUrl: whisperModelBaseUrl,
        );
}

/// Multilingual models only, so the language setting (or auto-detect) works
/// for every entry. Sizes and SHA-256 digests are from Hugging Face.
const whisperModels = <WhisperModel>[
  WhisperModel('ggml-tiny-q5_1.bin', 'Tiny', 'Fastest; rough accuracy',
      32152673, '818710568da3ca15689e31a743197b520007872ff9576237bda97bd1b469c3d7'),
  WhisperModel('ggml-base-q5_1.bin', 'Base', 'Recommended: fast, decent accuracy',
      59707625, '422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898'),
  WhisperModel('ggml-base.bin', 'Base (full precision)', 'Slightly better than Base, 2.5× larger',
      147951465, '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe'),
  WhisperModel('ggml-small-q5_1.bin', 'Small', 'Clearly better; about 3× slower than Base',
      190085487, 'ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb'),
  WhisperModel('ggml-small.bin', 'Small (full precision)', 'Marginally better than Small',
      487601967, '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b'),
  WhisperModel('ggml-medium-q5_0.bin', 'Medium', 'High accuracy; slow, needs 4+ GB RAM',
      539212467, '19fea4b380c3a618ec4723c3eef2eb785ffba0d0538cf43f8f235e7b3b34220f'),
  WhisperModel('ggml-large-v3-turbo-q5_0.bin', 'Large v3 Turbo', 'Best accuracy; slow, needs 4+ GB RAM',
      574041195, '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2'),
];

WhisperModel? whisperModelByFile(String file) {
  for (final m in whisperModels) {
    if (m.file == file) return m;
  }
  return null;
}

class WhisperModelManager extends ModelManager<WhisperModel> {
  WhisperModelManager() : super('whisper', whisperModels);
}
