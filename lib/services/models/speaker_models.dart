import 'model_manager.dart';

/// pyannote segmentation 3.0 (MIT), exported to ONNX by sherpa-onnx: finds
/// where speech is and where the voice changes.
const speakerSegmentationModel = DownloadableModel(
  file: 'pyannote-segmentation-3.0.onnx',
  label: 'Speech segmentation',
  note: 'pyannote segmentation 3.0',
  bytes: 5992913,
  sha256: '220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079',
  baseUrl: 'https://huggingface.co/csukuangfj/'
      'sherpa-onnx-pyannote-segmentation-3-0/resolve/main',
  remoteFile: 'model.onnx',
);

/// WeSpeaker ResNet34-LM voice embeddings (CC BY 4.0), the same embedding
/// model pyannote's own pipeline uses. Works on voice, not words, so it is
/// language independent.
const speakerEmbeddingModel = DownloadableModel(
  file: 'wespeaker_en_voxceleb_resnet34_LM.onnx',
  label: 'Voice embeddings',
  note: 'WeSpeaker ResNet34-LM',
  bytes: 26530550,
  sha256: 'e9848563da86f263117134dfd7ad63c92355b37de492b55e325400c9d9c39012',
  baseUrl: 'https://huggingface.co/csukuangfj/speaker-embedding-models/'
      'resolve/main',
);

const speakerModels = [speakerSegmentationModel, speakerEmbeddingModel];

/// The two models on-device speaker recognition needs, managed as one unit.
class SpeakerModelManager extends ModelManager<DownloadableModel> {
  SpeakerModelManager() : super('speakers', speakerModels);

  bool get ready => catalog.every(isInstalled);

  int get totalBytes => catalog.fold(0, (sum, m) => sum + m.bytes);

  bool get downloading =>
      catalog.any((m) => downloadOf(m) != null && downloadOf(m)!.error == null);

  String? get error {
    for (final m in catalog) {
      final e = downloadOf(m)?.error;
      if (e != null) return e;
    }
    return null;
  }

  /// Combined download progress, weighted by file size.
  double get progress {
    var done = 0.0;
    for (final m in catalog) {
      done += isInstalled(m) ? m.bytes : (downloadOf(m)?.progress ?? 0) * m.bytes;
    }
    return done / totalBytes;
  }

  Future<void> downloadAll() async {
    for (final m in catalog) {
      if (isInstalled(m)) continue;
      await download(m);
      if (!isInstalled(m)) return; // cancelled or failed
    }
  }

  void cancelAll() => catalog.forEach(cancel);

  Future<void> deleteAll() async {
    for (final m in catalog) {
      await delete(m);
    }
  }
}
