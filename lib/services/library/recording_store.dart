import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../models/recording.dart';

/// The local recording library. Everything lives in the app's private
/// documents directory — one folder per recording holding the audio file and
/// a `meta.json` (transcript, notes, chat). Nothing leaves the device here.
class RecordingStore extends ChangeNotifier {
  static const _uuid = Uuid();

  late Directory _root;
  final List<Recording> _items = [];

  /// Newest first.
  List<Recording> get all => List.unmodifiable(_items);

  Recording? byId(String id) {
    for (final r in _items) {
      if (r.id == id) return r;
    }
    return null;
  }

  Future<void> load() async {
    final docs = await getApplicationDocumentsDirectory();
    _root = Directory(p.join(docs.path, 'recordings'));
    await _root.create(recursive: true);

    _items.clear();
    await for (final entry in _root.list()) {
      if (entry is! Directory) continue;
      final meta = File(p.join(entry.path, 'meta.json'));
      if (!await meta.exists()) continue;
      try {
        _items.add(Recording.fromJson(
            jsonDecode(await meta.readAsString()) as Map<String, dynamic>));
      } catch (_) {
        // Skip a corrupt entry rather than failing the whole library.
      }
    }
    _sort();
    notifyListeners();
  }

  File audioOf(Recording r) => File(p.join(_root.path, r.id, r.audioFile));

  /// The photo attached to [m], or null for markers without one.
  File? photoOf(Recording r, RecordingMarker m) => m.photoFile == null
      ? null
      : File(p.join(_root.path, r.id, m.photoFile!));

  /// A scratch path for the recorder to write into before the recording is
  /// added to the library.
  Future<String> newTempAudioPath(String extension) async {
    final tmp = await getTemporaryDirectory();
    return p.join(tmp.path, 'rec_${_uuid.v4()}.$extension');
  }

  /// Adds [audio] to the library. With [move] the source file is moved
  /// (recorder temp files); otherwise it is copied (imports).
  Future<Recording> add(
    File audio, {
    required String title,
    required RecordingSource source,
    int durationMs = 0,
    bool move = false,
    List<RecordingMarker> markers = const [],
    Map<String, File> photos = const {},
  }) async {
    final id = _uuid.v4();
    final dir = Directory(p.join(_root.path, id));
    await dir.create(recursive: true);

    final ext = p.extension(audio.path).isEmpty ? '.m4a' : p.extension(audio.path);
    final name = 'audio$ext';
    final dest = p.join(dir.path, name);
    if (move) {
      try {
        await audio.rename(dest);
      } on FileSystemException {
        // rename fails across filesystems; fall back to copy + delete.
        await audio.copy(dest);
        await audio.delete();
      }
    } else {
      await audio.copy(dest);
    }

    // Photos taken while recording live in <recording>/photos/<markerId>.jpg.
    final saved = <RecordingMarker>[];
    for (final m in markers) {
      final photo = photos[m.id];
      if (photo == null) {
        saved.add(m);
        continue;
      }
      final rel = 'photos/${m.id}.jpg';
      final target = File(p.join(dir.path, rel));
      await target.parent.create(recursive: true);
      try {
        await photo.rename(target.path);
      } on FileSystemException {
        await photo.copy(target.path);
        await photo.delete();
      }
      saved.add(m.withPhotoFile(rel));
    }

    final rec = Recording(
      id: id,
      title: title,
      createdAt: DateTime.now(),
      audioFile: name,
      durationMs: durationMs,
      source: source,
      markers: saved,
    );
    await _write(rec);
    _items.add(rec);
    _sort();
    notifyListeners();
    return rec;
  }

  /// Persists changes made to [r] (title, transcript, notes, chat).
  Future<void> save(Recording r) async {
    await _write(r);
    notifyListeners();
  }

  Future<void> delete(Recording r) async {
    final dir = Directory(p.join(_root.path, r.id));
    if (await dir.exists()) await dir.delete(recursive: true);
    _items.removeWhere((e) => e.id == r.id);
    notifyListeners();
  }

  Future<void> _write(Recording r) async {
    final meta = File(p.join(_root.path, r.id, 'meta.json'));
    // Write-then-rename so a crash mid-write never corrupts the entry.
    final tmp = File('${meta.path}.tmp');
    await tmp.writeAsString(jsonEncode(r.toJson()), flush: true);
    await tmp.rename(meta.path);
  }

  void _sort() => _items.sort((a, b) => b.createdAt.compareTo(a.createdAt));
}
