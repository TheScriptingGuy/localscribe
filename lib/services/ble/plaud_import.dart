import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';
import 'package:uuid/uuid.dart';

import '../../models/recording.dart';
import '../library/recording_store.dart';
import 'plaud_container.dart';
import 'plaud_device.dart';

/// Adds a recording from a Plaud recorder to the library: unmasks the
/// container to Ogg Opus, turns the recorder-button marks into highlights,
/// and dates it by the recorder's file id (its start time).
///
/// [markers] and [photos] are extra moments marked in LocalScribe while the
/// recording was live. If the container cannot be decoded the raw `.plaud`
/// bytes are kept rather than losing the recording.
Future<Recording> addPlaudRecording(
  RecordingStore store,
  RSAPrivateKey? priv,
  PlaudDownload d, {
  String? title,
  List<RecordingMarker> markers = const [],
  Map<String, File> photos = const {},
}) async {
  final tmp = await getTemporaryDirectory();
  final stem = 'plaud_${d.fileId.toRadixString(16)}';
  final all = <RecordingMarker>[...markers];
  var durationMs = 0;
  File f;
  try {
    if (priv == null) throw StateError('no RSA key loaded');
    final audio = PlaudContainer(d.bytes).decode(priv);
    durationMs = audio.durationMs;
    f = File(p.join(tmp.path, '$stem.opus'));
    await f.writeAsBytes(PlaudContainer.oggOpusOf(audio.packets), flush: true);
    all.addAll(recorderMarkers(audio.markMs, existing: markers));
  } catch (e) {
    debugPrint('plaud: container decode failed for $stem: $e');
    f = File(p.join(tmp.path, '$stem.plaud'));
    await f.writeAsBytes(d.bytes, flush: true);
  }
  all.sort((a, b) => a.atMs.compareTo(b.atMs));
  return store.add(
    f,
    title: title ?? 'Plaud Note ${d.fileId.toRadixString(16)}',
    source: RecordingSource.plaud,
    durationMs: durationMs,
    move: true,
    markers: all,
    photos: photos,
    createdAt: fileIdTime(d.fileId),
    deviceFileId: d.fileId,
  );
}

/// The recorder's file id is the unix time (seconds) it started recording.
/// Ids outside 2020..2100 are not trusted as dates.
DateTime? fileIdTime(int fileId) {
  if (fileId < 1577836800 || fileId > 4102444800) return null;
  return DateTime.fromMillisecondsSinceEpoch(fileId * 1000);
}

/// Highlight markers for recorder-button marks, skipping any that are already
/// in [existing] as a flag within a second (the live screen adds them as they
/// arrive).
List<RecordingMarker> recorderMarkers(List<int> markMs,
    {List<RecordingMarker> existing = const []}) {
  const uuid = Uuid();
  final out = <RecordingMarker>[];
  for (final ms in markMs) {
    final dup = existing.any(
        (m) => m.type == MarkerType.flag && (m.atMs - ms).abs() < 1000);
    if (dup) continue;
    out.add(RecordingMarker(id: uuid.v4(), atMs: ms, type: MarkerType.flag));
  }
  return out;
}
