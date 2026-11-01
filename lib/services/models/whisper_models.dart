import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where GGML whisper models are downloaded from (the whisper.cpp project's
/// official model repository on Hugging Face).
const whisperModelBaseUrl =
    'https://huggingface.co/ggerganov/whisper.cpp/resolve/main';

class WhisperModel {
  final String file;
  final String label;
  final String note;
  final int bytes;
  final String sha256;

  const WhisperModel(this.file, this.label, this.note, this.bytes, this.sha256);

  String get url => '$whisperModelBaseUrl/$file';
  String get sizeLabel => bytes >= 1000000000
      ? '${(bytes / 1e9).toStringAsFixed(1)} GB'
      : '${(bytes / 1e6).round()} MB';
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

class ModelDownload {
  double progress = 0;
  bool verifying = false;
  String? error;
  final CancelToken token = CancelToken();
}

/// Downloads, verifies and stores whisper models in app-private storage.
/// Interrupted downloads resume from the `.part` file.
class WhisperModelManager extends ChangeNotifier {
  late Directory _dir;
  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 30),
    receiveTimeout: const Duration(minutes: 2),
  ));
  final _installed = <String>{};
  final _downloads = <String, ModelDownload>{};

  Future<void> load() async {
    final support = await getApplicationSupportDirectory();
    _dir = Directory(p.join(support.path, 'models', 'whisper'));
    await _dir.create(recursive: true);
    await for (final e in _dir.list()) {
      final name = p.basename(e.path);
      if (e is File && whisperModelByFile(name) != null) _installed.add(name);
    }
  }

  File fileOf(WhisperModel m) => File(p.join(_dir.path, m.file));
  bool isInstalled(WhisperModel m) => _installed.contains(m.file);
  ModelDownload? downloadOf(WhisperModel m) => _downloads[m.file];

  Future<void> download(WhisperModel m) async {
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
  void cancel(WhisperModel m) => _downloads[m.file]?.token.cancel();

  Future<void> delete(WhisperModel m) async {
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
