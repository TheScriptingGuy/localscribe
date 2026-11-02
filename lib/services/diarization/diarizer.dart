import 'dart:io';

import '../transcription/transcriber.dart';

/// One stretch of speech by one voice. [speaker] is only meaningful within
/// a single result ("same voice as other turns with this id").
class SpeakerTurn {
  final double start; // seconds
  final double end;
  final String speaker;
  const SpeakerTurn(this.start, this.end, this.speaker);
}

/// A stretch of one speaker's audio transcribed on its own, so it gets its
/// own language (Spoken language: Mixed). [speaker] is "S1", "S2", ….
class SpeakerPiece {
  final double start; // seconds
  final double end;
  final String speaker;
  const SpeakerPiece(this.start, this.end, this.speaker);

  double get duration => end - start;

  /// 0 for "S1", 1 for "S2", …
  int get speakerIndex => int.parse(speaker.substring(1)) - 1;
}

/// Speaker recognition (diarization): who spoke when, without the words.
abstract class Diarizer {
  String get name;

  /// [numSpeakers] 0 = detect automatically. [onProgress] gets 0.0–1.0.
  Future<List<SpeakerTurn>> diarize(
    File audio, {
    int numSpeakers = 0,
    void Function(double progress)? onProgress,
    CancelSignal? cancel,
  });
}
