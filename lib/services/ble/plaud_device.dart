import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';

import 'plaud_credentials.dart';
import 'plaud_crypto.dart';
import 'plaud_protocol.dart';

enum PlaudStatus { idle, scanning, connecting, handshaking, syncing, done, error }

/// A recording pulled from the device: its file id and the raw `PLAUD.AI`
/// container bytes (decrypted, reassembled).
class PlaudDownload {
  final int fileId;
  final Uint8List bytes;
  PlaudDownload(this.fileId, this.bytes);
}

/// Connects to the user's Plaud recorder over BLE, runs the verified handshake,
/// and syncs recordings — entirely on-device, talking only to the recorder.
///
/// The command sequence is still being tuned against the live device, so every
/// decrypted frame is logged; [log] is shown in the import screen.
class PlaudDeviceSession extends ChangeNotifier {
  final FlutterReactiveBle _ble = FlutterReactiveBle();

  PlaudStatus status = PlaudStatus.idle;
  String message = '';
  double progress = 0; // 0..1 for the active download
  final List<String> log = [];
  final List<PlaudDownload> downloads = [];

  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<ConnectionStateUpdate>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  String? _deviceId;

  PlaudSessionKeys? _keys;
  final _keyChunks = <int, List<int>>{};
  final _frames = StreamController<PlaudFrame>.broadcast();

  void _log(String s) {
    log.add(s);
    if (log.length > 400) log.removeRange(0, log.length - 400);
    // `print` maps to `adb logcat -s flutter` even in release builds (unlike
    // debugPrint/developer.log, which are compiled out there), so a failed
    // sync is diagnosable from logcat.
    print('[plaud] $s');
    notifyListeners();
  }

  void _set(PlaudStatus s, [String? msg]) {
    status = s;
    if (msg != null) message = msg;
    notifyListeners();
  }

  /// Full flow: scan → connect → handshake → sync. Credentials come from
  /// [cred]; [dev] is the target recorder (its public key is presented).
  Future<void> sync(PlaudCredentials cred, PlaudDeviceCred dev) async {
    downloads.clear();
    // Reset session state so a re-connect starts a fresh handshake (a previous
    // session's key/chunks otherwise cause "mac check failed" on the new one).
    _keys = null;
    _keyChunks.clear();
    try {
      final priv = PlaudCrypto.privateKeyFromPem(cred.rsaPrivateKeyPem!);
      final id = await _scan();
      _deviceId = id;
      await _connect(id);
      await _subscribe(id);
      await _handshake(dev.publicKey, priv);
      await _runSync(cred.userId ?? '');
      _set(PlaudStatus.done, 'Synced ${downloads.length} recording(s)');
    } catch (e) {
      _log('ERROR $e');
      _set(PlaudStatus.error, '$e');
    } finally {
      await _cleanup();
    }
  }

  Future<String> _scan() async {
    _set(PlaudStatus.scanning, 'Scanning for ${PlaudProtocol.deviceName}…');
    final completer = Completer<String>();
    // No service filter: the recorder does not advertise its GATT service UUID
    // (0x1910) — that only appears in the GATT table after connecting. We match
    // purely by advertised device name instead. Log every named advert seen so
    // a miss is diagnosable on-screen.
    _scanSub = _ble.scanForDevices(
      withServices: const [],
      scanMode: ScanMode.lowLatency,
    ).listen((d) {
      if (d.name.isNotEmpty) _log('advert ${d.name} rssi=${d.rssi}');
      if (!completer.isCompleted &&
          (d.name == PlaudProtocol.deviceName || d.name.startsWith('PLAUD'))) {
        _log('found ${d.name} ${d.id} rssi=${d.rssi}');
        completer.complete(d.id);
      }
    }, onError: (e) {
      if (!completer.isCompleted) completer.completeError(e);
    });
    final id = await completer.future.timeout(const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException('recorder not found (is it on and not in the Plaud app?)'));
    await _scanSub?.cancel();
    _scanSub = null;
    return id;
  }

  Future<void> _connect(String id) async {
    _set(PlaudStatus.connecting, 'Connecting…');
    final completer = Completer<void>();
    _connSub = _ble.connectToDevice(
      id: id,
      connectionTimeout: const Duration(seconds: 15),
    ).listen((u) {
      _log('conn ${u.connectionState}');
      if (u.connectionState == DeviceConnectionState.connected &&
          !completer.isCompleted) {
        completer.complete();
      }
    }, onError: (e) {
      if (!completer.isCompleted) completer.completeError(e);
    });
    await completer.future
        .timeout(const Duration(seconds: 20), onTimeout: () => throw TimeoutException('connect timeout'));
    try {
      final mtu = await _ble.requestMtu(deviceId: id, mtu: 247);
      _log('mtu=$mtu');
    } catch (e) {
      _log('mtu request failed: $e');
    }
  }

  QualifiedCharacteristic _qc(String uuid, String id) => QualifiedCharacteristic(
        characteristicId: Uuid.parse(uuid),
        serviceId: Uuid.parse(PlaudProtocol.svc),
        deviceId: id,
      );

  Future<void> _subscribe(String id) async {
    _notifySub = _ble
        .subscribeToCharacteristic(_qc(PlaudProtocol.chNotify, id))
        .listen(_onNotify, onError: (e) => _log('notify error $e'));
    // The recorder disconnects (~280 ms) if its device key is not presented
    // promptly after the notify CCCD lands, so keep this settle very short.
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }

  void _onNotify(List<int> data) {
    if (_keys == null) {
      if (PlaudProtocol.isKeyNotify(data)) {
        _keyChunks[data[3]] = data.sublist(4);
        _log('key chunk ${data[3]} (${data.length}B)');
      } else {
        _log('pre-key notify ${data.length}B ${_hexHead(data)}');
      }
      return;
    }
    try {
      final pt = PlaudCrypto.frameDecrypt(_keys!, data);
      final f = PlaudFrame.parse(pt);
      if (f.isControl) {
        _log('IN ctrl seq=${f.seq} op=0x${f.op.toRadixString(16)} '
            'st=${f.status} content=${_hex(f.content)}');
      } else if (f.isData) {
        _log('IN data seq=${f.seq} fileId=0x${f.fileId.toRadixString(16)} '
            'off=${f.offset} len=${f.dataLen} head=${_hexHead(f.data)}');
      } else {
        _log('IN type=${f.type} ${_hex(pt)}');
      }
      _frames.add(f);
    } catch (e) {
      _log('decrypt fail (${data.length}B): $e');
    }
  }

  Future<void> _write(List<int> bytes) =>
      _ble.writeCharacteristicWithoutResponse(_qc(PlaudProtocol.chWrite, _deviceId!), value: bytes);

  /// Send an encrypted control command and log its plaintext (op/content) so the
  /// outgoing sequence is visible in the sync log.
  Future<void> _sendCmd(PlaudCommands cmds, int op, List<int> content,
      {int status = 0}) async {
    _log('OUT seq=${cmds.nextSeq} op=0x${op.toRadixString(16)} '
        'st=$status content=${_hex(content)}');
    await _write(cmds.raw(op, content));
  }

  Future<void> _handshake(Uint8List devicePubKey, priv) async {
    _set(PlaudStatus.handshaking, 'Handshaking…');
    for (final f in PlaudProtocol.keyWriteFrames(devicePubKey)) {
      await _write(f);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // `12 FE 05`: provision our RSA public key so the device wraps the session
    // key to US. This is what makes a self-generated (or imported) key "work"
    // — the recorder accepts whatever user key is written here, no cloud.
    final userPem = PlaudCrypto.publicKeyPemFromPrivate(priv);
    final userBytes = Uint8List.fromList(utf8.encode(userPem));
    for (final f in PlaudProtocol.userKeyWriteFrames(userBytes)) {
      await _write(f);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    // wait for the 3 wrapped-key chunks
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      final wrapped = PlaudProtocol.reassembleWrapped(_keyChunks);
      if (wrapped != null) {
        _keys = PlaudCrypto.sessionKeysFrom(priv, wrapped);
        _log('session keys derived (key32/nonce12/aad12)');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw TimeoutException('no wrapped-key response (key not enrolled?)');
  }

  Future<void> _runSync(String userId) async {
    _set(PlaudStatus.syncing, 'Requesting recordings…');
    final cmds = PlaudCommands(_keys!);

    await _sendCmd(cmds, 0x01, [0x02, 0x00, 0x00, ...userId.codeUnits]);
    await _settle();
    await _sendCmd(cmds, 0x6c, const []);
    await _settle();

    // op 0x1a = list pending files, verified against a live capture of the
    // real app (findings/decoded_live_capture.txt): content =
    // [echo:4][count:4 LE] + count x [fileId:4][size:4 LE][flags:2].
    // (op 0x03 — the earlier guess for "list" — always echoes an empty/
    // "no file" shape regardless of what's actually queued; it is not this.)
    final listCompleter = Completer<Uint8List>();
    final listSub = _frames.stream.listen((f) {
      if (f.isControl && f.op == 0x1a && !listCompleter.isCompleted) {
        listCompleter.complete(f.content);
      }
    });
    await _sendCmd(cmds, 0x1a, List<int>.filled(9, 0));
    Uint8List listContent;
    try {
      listContent = await listCompleter.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () =>
            throw TimeoutException('no file-list response (op 0x1a)'),
      );
    } finally {
      await listSub.cancel();
    }

    final entries = parseFileList(listContent);
    _log('file list: ${entries.map((e) => '${e.fileId.toRadixString(16)}:${e.size}B').toList()}');

    // Newest first (file ids are unix timestamps, so descending = latest).
    final sorted = entries.toList()..sort((a, b) => b.fileId.compareTo(a.fileId));
    for (final e in sorted) {
      await _download(cmds, e.fileId);
    }
  }

  Future<void> _download(PlaudCommands cmds, int fileId) async {
    _set(PlaudStatus.syncing, 'Downloading ${fileId.toRadixString(16)}…');
    final asm = PlaudFileAssembler(fileId);
    var totalSize = 0;
    var blockDone = Completer<void>();
    final sub = _frames.stream.listen((f) {
      if (f.isData && f.fileId == fileId) {
        asm.add(f);
        progress = (asm.bytesReceived % 1000000) / 1000000;
        if (asm.bytesReceived % 8000 < 90) notifyListeners();
      } else if (f.isControl && f.op == 0x16 && f.content.length >= 8) {
        // op 0x16 reply: [fileid:4][size:4][0401]
        final sz = f.content[4] |
            (f.content[5] << 8) |
            (f.content[6] << 16) |
            (f.content[7] << 24);
        if (sz > 0) totalSize = sz;
        _log('file ${fileId.toRadixString(16)} size=$sz');
      } else if (f.isControl && f.op == 0x1d) {
        // end of this download block
        if (!blockDone.isCompleted) blockDone.complete();
      }
    });

    // Query the total size first (op 0x16: [fileid:4][00]).
    await _sendCmd(cmds, 0x16, [..._le32(fileId), 0x00]);
    await _settle(ms: 400);

    // Download in 0x280-byte (640) blocks until the whole file is assembled.
    var offset = 0;
    var rounds = 0;
    while ((totalSize == 0 || offset < totalSize) && rounds < 20000) {
      blockDone = Completer<void>();
      await _sendCmd(
          cmds, 0x1c, [..._le32(fileId), ..._le32(offset), ..._le32(0x280)]);
      await blockDone.future
          .timeout(const Duration(seconds: 20), onTimeout: () {});
      final got = asm.bytesReceived;
      if (got <= offset) {
        _log('download ${fileId.toRadixString(16)} stalled at $offset');
        break;
      }
      offset = got;
      rounds++;
    }

    await sub.cancel();
    final bytes = asm.assemble();
    if (bytes.isNotEmpty) {
      downloads.add(PlaudDownload(fileId, bytes));
      _log('downloaded ${fileId.toRadixString(16)}: ${bytes.length}B '
          'magic=${String.fromCharCodes(bytes.take(8))}');
    }
  }

  static List<int> _le32(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

  Future<void> _settle({int ms = 600}) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> _cleanup() async {
    await _notifySub?.cancel();
    await _connSub?.cancel();
    await _scanSub?.cancel();
    _notifySub = _connSub = _scanSub = null;
  }

  static String _hexHead(List<int> b) {
    final n = b.length < 64 ? b.length : 64;
    final sb = StringBuffer();
    for (var i = 0; i < n; i++) {
      sb.write(b[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  static String _hex(List<int> b) {
    final sb = StringBuffer();
    for (final v in b) {
      sb.write(v.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  @override
  void dispose() {
    _cleanup();
    _frames.close();
    super.dispose();
  }
}
