import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A model file the app can download, pinned by size and SHA-256.
class DownloadableModel {
  /// Local file name.
  final String file;
  final String label;
  final String note;
  final int bytes;
  final String sha256;
  final String baseUrl;

  /// File name on the server, when it differs from [file].
  final String? remoteFile;

  const DownloadableModel({
    required this.file,
    required this.label,
    required this.note,
    required this.bytes,
    required this.sha256,
    required this.baseUrl,
    this.remoteFile,
  });

  String get url => '$baseUrl/${remoteFile ?? file}';
  String get sizeLabel => formatBytes(bytes);
}

String formatBytes(int bytes) => bytes >= 1000000000
    ? '${(bytes / 1e9).toStringAsFixed(1)} GB'
    : '${(bytes / 1e6).round()} MB';

class ModelDownload {
  double progress = 0;
  bool verifying = false;
  String? error;
  final CancelToken token = CancelToken();
}

/// Downloads, verifies and stores the models of one [catalog] in
/// `<app support>/models/<subdir>`. Interrupted downloads resume from the
/// `.part` file.
class ModelManager<M extends DownloadableModel> extends ChangeNotifier {
  final String subdir;
  final List<M> catalog;

  ModelManager(this.subdir, this.catalog);

  late Directory _dir;
  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 2),
  ));
  final _installed = <String>{};
  final _downloads = <String, ModelDownload>{};

  M? byFile(String file) {
    for (final m in catalog) {
      if (m.file == file) return m;
    }
    return null;
  }

  Future<void> load() async {
    final support = await getApplicationSupportDirectory();
    _dir = Directory(p.join(support.path, 'models', subdir));
    await _dir.create(recursive: true);
    await for (final e in _dir.list()) {
      final name = p.basename(e.path);
      if (e is File && byFile(name) != null) _installed.add(name);
    }
  }

  File fileOf(M m) => File(p.join(_dir.path, m.file));
  bool isInstalled(M m) => _installed.contains(m.file);
  ModelDownload? downloadOf(M m) => _downloads[m.file];

  Future<void> download(M m) async {
    final existing = _downloads[m.file];
    if (isInstalled(m) || (existing != null && existing.error == null)) return;
    final state = ModelDownload();
    _downloads[m.file] = state;
    notifyListeners();

    final part = File('${fileOf(m).path}.part');
    try {
      var have = await part.exists() ? await part.length() : 0;
      if (have > m.bytes) {
        await part.delete();
        have = 0;
      }
      if (have < m.bytes) {
        final resp = await _dio.get<ResponseBody>(
          m.url,
          cancelToken: state.token,
          options: Options(
            responseType: ResponseType.stream,
            headers: {if (have > 0) 'range': 'bytes=$have-'},
          ),
        );
        // 200 means the server ignored the range: start over.
        final resume = resp.statusCode == 206;
        if (!resume) have = 0;
        final sink =
            part.openWrite(mode: resume ? FileMode.append : FileMode.write);
        var got = have;
        var lastNotify = DateTime.now();
        try {
          await for (final chunk in resp.data!.stream) {
            sink.add(chunk);
            got += chunk.length;
            state.progress = got / m.bytes;
            final now = DateTime.now();
            if (now.difference(lastNotify).inMilliseconds > 250) {
              lastNotify = now;
              notifyListeners();
            }
          }
        } finally {
          await sink.close();
        }
      }
      if (await part.length() != m.bytes) {
        throw 'Download incomplete. Tap download to resume.';
      }

      state.verifying = true;
      notifyListeners();
      if (await _sha256Of(part.path) != m.sha256) {
        await part.delete();
        throw 'Checksum mismatch. Download it again.';
      }
      await part.rename(fileOf(m).path);
      _installed.add(m.file);
      _downloads.remove(m.file);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        _downloads.remove(m.file);
      } else {
        state.error = 'Download failed: ${e.message ?? e.type.name}';
      }
    } catch (e) {
      state.error = e.toString();
    }
    notifyListeners();
  }

  /// Stops a download; the partial file is kept so it can resume.
  void cancel(M m) => _downloads[m.file]?.token.cancel();

  Future<void> delete(M m) async {
    for (final f in [fileOf(m), File('${fileOf(m).path}.part')]) {
      if (await f.exists()) await f.delete();
    }
    _installed.remove(m.file);
    _downloads.remove(m.file);
    notifyListeners();
  }
}

// Top-level so the isolate closure captures only the path.
Future<String> _sha256Of(String path) => Isolate.run(
    () async => (await sha256.bind(File(path).openRead()).first).toString());
