import 'dart:io';

import '../ai/ai_types.dart';
import '../transcription/transcriber.dart';
import 'diarizer.dart';

/// F-Droid build: on-device speaker recognition is left out. sherpa-onnx
/// ships prebuilt onnxruntime libraries, and F-Droid only distributes code
/// it builds from source. The remote speaker API still works.
///
/// tool/fdroid/prepare.sh copies this over lib/services/diarization/
/// local_diarizer.dart; keep the public API (class, constructor, constant)
/// the same as that file.
const bool localDiarizerAvailable = false;

class LocalDiarizer implements Diarizer {
  final File segmentationModel;
  final File embeddingModel;

  LocalDiarizer(
      {required this.segmentationModel, required this.embeddingModel});

  @override
  String get name => 'unavailable';

  @override
  Future<List<SpeakerTurn>> diarize(
    File audio, {
    int numSpeakers = 0,
    void Function(double progress)? onProgress,
    CancelSignal? cancel,
  }) async {
    throw AiException('On-device speaker recognition is not part of the '
        'F-Droid build. Use a custom speaker API in Options > Speaker '
        'recognition instead.');
  }
}
