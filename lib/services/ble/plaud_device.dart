import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:wifi_iot/wifi_iot.dart';

import 'plaud_container.dart';
import 'plaud_credentials.dart';
import 'plaud_crypto.dart';
import 'plaud_protocol.dart';
import 'plaud_wifi.dart';

enum PlaudStatus {
  idle,
  scanning,
  connecting,
  handshaking,
  syncing,
  recording,
  stopping,
  done,
  error
}

/// A recording pulled from the device: its file id and the raw `PLAUD.AI`
/// container bytes (decrypted, reassembled).
class PlaudDownload {
  final int fileId;
  final Uint8List bytes;
  PlaudDownload(this.fileId, this.bytes);
}

/// A recording made live on the recorder: container bytes and the times
/// (ms from start) the recorder's button marked highlights.
class PlaudLiveRecording extends PlaudDownload {
  final List<int> markMs;
  PlaudLiveRecording(super.fileId, super.bytes, this.markMs);
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
  /// Files whose id is in [skip] (already in the library) are not downloaded.
  ///
  /// With [fast], the recordings come over the recorder's own WiFi access
  /// point ("fast transfer") instead of BLE; the list and setup stay on BLE.
  /// If WiFi can't be brought up the sync carries on over BLE.
  Future<void> sync(PlaudCredentials cred, PlaudDeviceCred dev,
      {Set<int> skip = const {}, bool fast = false}) async {
    downloads.clear();
    PlaudWifiLink? wifi;
    PlaudCommands? cmds;
    try {
      cmds = await _open(cred, dev);
      final todo = await _listToSync(cmds, skip);
      if (fast && todo.isNotEmpty) {
        try {
          wifi = await _openWifi(cmds, cred);
        } catch (e) {
          _log('fast transfer unavailable ($e); using Bluetooth');
          await _closeWifi(cmds, null);
          // The recorder drops Bluetooth once its access point is up.
          if (!_connected) cmds = await _open(cred, dev);
        }
      }
      for (final e in todo) {
        Uint8List? bytes;
        final link = wifi;
        if (link != null && link.connected) {
          _set(PlaudStatus.syncing,
              'Downloading ${e.fileId.toRadixString(16)} over WiFi…');
          progress = 0;
          bytes = await link.download(e.fileId, e.size, onProgress: (n) {
            final p = n / e.size;
            if (p - progress >= 0.01 || n >= e.size) {
              progress = p;
              notifyListeners();
            }
          });
        }
        bytes ??= await _download(cmds, e.fileId, e.size);
        if (bytes != null) downloads.add(PlaudDownload(e.fileId, bytes));
      }
      _set(PlaudStatus.done, 'Synced ${downloads.length} recording(s)');
    } catch (e) {
      _log('ERROR $e');
      _set(PlaudStatus.error, '$e');
    } finally {
      if (wifi != null) await _closeWifi(cmds, wifi);
      await _cleanup();
    }
  }

  /// BLE op 0x0a (OpenWiFi, `qi.d0`): `[isOta:1][password:8 ascii]` ->
  /// `[status:1][password:8]`. The recorder then runs an access point named
  /// `PLAUD` + the last 4 of its serial; once the phone has joined it, the
  /// recorder connects to the phone's WebSocket server on port 8081.
  Future<PlaudWifiLink> _openWifi(
      PlaudCommands cmds, PlaudCredentials cred) async {
    final dev = activeDevice!;
    _set(PlaudStatus.syncing, 'Starting fast transfer…');
    // The recorder's reply is just a status byte; the access point's
    // password is the last 8 characters of its serial (verified with Frida on
    // the Plaud app: serial ...7178688B -> SSID PLAUD688B, password 7178688B).
    final reply = await _request(cmds, 0x0a, const [0x00]);
    _log('open wifi reply ${_hex(reply)}');
    if (reply.isEmpty || reply[0] != 0) {
      throw StateError('recorder refused WiFi (status '
          '${reply.isEmpty ? '?' : reply[0]})');
    }
    final sn = dev.serial;
    if (sn.length < 8) throw StateError('serial too short for WiFi password');
    final apPass = reply.length >= 9
        ? String.fromCharCodes(reply.sublist(1, 9))
        : sn.substring(sn.length - 8);
    final s = dev.serial;
    final ssid = 'PLAUD${s.length >= 4 ? s.substring(s.length - 4) : s}';
    final link = PlaudWifiLink(
      keys: _keys!,
      nextSeq: cmds.takeSeq,
      serial: s,
      token: cred.userId ?? '',
      log: _log,
    );
    try {
      await link.listen();
      _set(PlaudStatus.syncing, 'Joining $ssid…');
      _log('joining $ssid');
      final joined = await WiFiForIoTPlugin.connect(ssid,
          password: apPass,
          security: NetworkSecurity.WPA,
          joinOnce: true,
          withInternet: false,
          timeoutInSeconds: 40);
      if (!joined) throw StateError('could not join $ssid');
      _log('joined $ssid');
      _set(PlaudStatus.syncing, 'Waiting for the recorder on WiFi…');
      await link.handshake();
      return link;
    } catch (e) {
      await link.close();
      rethrow;
    }
  }

  /// Leaves fast-transfer mode: closes the link, tells the recorder to turn
  /// its access point off (BLE op 0x0d, `qi.g`) and drops the phone's
  /// connection to it.
  Future<void> _closeWifi(PlaudCommands? cmds, PlaudWifiLink? link) async {
    await link?.close();
    if (cmds != null && _connected) {
      try {
        await _sendCmd(cmds, 0x0d, const []);
        await _settle();
      } catch (e) {
        _log('close wifi: $e');
      }
    }
    try {
      await WiFiForIoTPlugin.disconnect();
      await WiFiForIoTPlugin.forceWifiUsage(false);
    } catch (e) {
      _log('wifi disconnect: $e');
    }
  }

  /// Scan, connect, handshake, then the session setup the Plaud app does on
  /// every connect (auth, device info, ops 0x19/0x18).
  Future<PlaudCommands> _open(PlaudCredentials cred, PlaudDeviceCred dev) async {
    // Reset session state so a re-connect starts a fresh handshake (a previous
    // session's key/chunks otherwise cause "mac check failed" on the new one).
    _keys = null;
    _keyChunks.clear();
    _connected = false;
    final priv = PlaudCrypto.privateKeyFromPem(cred.rsaPrivateKeyPem!);
    final (id, target) = await _scan(dev, cred.devices);
    _deviceId = id;
    activeDevice = target;
    await _connect(id);
    await _subscribe(id);
    await _handshake(target.publicKey, priv);

    _set(PlaudStatus.handshaking, 'Setting up…');
    final cmds = PlaudCommands(_keys!);
    await _sendCmd(cmds, 0x01, [0x02, 0x00, 0x00, ...(cred.userId ?? '').codeUnits]);
    await _settle();
    await _sendCmd(cmds, 0x6c, const []);
    await _settle();
    // ops 0x19 then 0x18, verified against the real app's capture
    // (findings/decoded_live_capture.txt): OUT 0x19 content=00 -> IN 0x22
    // content=00, OUT 0x18 content=(empty) -> IN 0x21 content=00. Without
    // these the recorder was free to auto-start a new recording as soon as
    // it was connected. The Plaud app sends them on every connect, including
    // before it starts a recording.
    await _sendCmd(cmds, 0x19, const [0x00]);
    await _settle();
    await _sendCmd(cmds, 0x18, const []);
    await _settle();
    return cmds;
  }

  /// Sends [op] and waits for the recorder's control reply with [replyOp]
  /// (default: the same op). Returns the reply content.
  Future<Uint8List> _request(PlaudCommands cmds, int op, List<int> content,
      {int? replyOp, Duration timeout = const Duration(seconds: 8)}) async {
    final want = replyOp ?? op;
    final reply = Completer<Uint8List>();
    final sub = _frames.stream.listen((f) {
      if (f.isControl && f.op == want && !reply.isCompleted) {
        reply.complete(f.content);
      }
    });
    try {
      await _sendCmd(cmds, op, content);
      return await reply.future.timeout(timeout,
          onTimeout: () => throw TimeoutException(
              'no reply to op 0x${op.toRadixString(16)}'));
    } finally {
      await sub.cancel();
    }
  }

  // ------------------------------------------------------- live recording

  PlaudCommands? _liveCmds;
  PlaudLiveScanner? _live;
  StreamSubscription<PlaudFrame>? _liveSub;
  int? _liveFileId;
  int _liveHeadSize = 0x280;
  final Stopwatch _liveClock = Stopwatch();
  bool _connected = false;

  /// File id of the recording in progress (its start time, unix seconds).
  int? get liveFileId => _liveFileId;

  /// Time since the recorder confirmed it started.
  Duration get liveElapsed => _liveClock.elapsed;

  /// Highlight marks made with the recorder's button so far, ms from start.
  List<int> get liveMarks => List.unmodifiable(_live?.marks ?? const <int>[]);

  /// Audio received over BLE so far.
  int get liveReceivedMs => _live?.durationMs ?? 0;

  /// Where in the recording "now" is, for a highlight, photo or note: the
  /// audio received so far, which is how the Plaud app times them (verified:
  /// a tap 31.6 s after start was labelled 00:00:30, the received position).
  /// Falls back to the clock until audio arrives.
  int get liveMarkMs {
    final rx = liveReceivedMs;
    return rx > 0 ? rx : _liveClock.elapsedMilliseconds;
  }

  bool _livePaused = false;
  bool get livePaused => _livePaused;

  /// op 0x15 `[fileId] 00` -> `[fileId][size:4] 00 01`. The recorder stops
  /// writing until resumed; the stream simply runs dry.
  Future<bool> pauseRecording() async {
    final cmds = _liveCmds, fileId = _liveFileId;
    if (cmds == null || fileId == null || _livePaused) return false;
    try {
      await _request(cmds, 0x15, [..._le32(fileId), 0x00]);
      _livePaused = true;
      _liveClock.stop();
      _set(PlaudStatus.recording, 'Paused');
      return true;
    } catch (e) {
      _log('pause failed: $e');
      _set(PlaudStatus.recording, 'Could not pause: $e');
      return false;
    }
  }

  /// op 0x16 `[fileId] 00` -> `[fileId][size:4] 00 01` resumes recording
  /// (0x14 start, 0x15 pause, 0x16 resume, 0x17 stop); then, like the Plaud
  /// app, stream live again from the reported size.
  Future<bool> resumeRecording() async {
    final cmds = _liveCmds, fileId = _liveFileId;
    if (cmds == null || fileId == null || !_livePaused) return false;
    try {
      final info = await _request(cmds, 0x16, [..._le32(fileId), 0x00]);
      final size = info.length >= 8 ? _u32(info, 4) : 0;
      await _sendCmd(cmds, 0x1c, [..._le32(fileId), ..._le32(size), ..._le32(0)]);
      _livePaused = false;
      _liveClock.start();
      _set(PlaudStatus.recording, 'Recording');
      return true;
    } catch (e) {
      _log('resume failed: $e');
      _set(PlaudStatus.recording, 'Could not resume: $e');
      return false;
    }
  }

  /// Fires with the time (ms) of each recorder-button highlight.
  final _markEvents = StreamController<int>.broadcast();
  Stream<int> get deviceMarks => _markEvents.stream;

  /// Connects and tells the recorder to start recording, then streams the
  /// recording in as it is made, the way the Plaud app does (verified with
  /// Frida, findings/plaud-device-recording.md):
  ///
  ///   op 0x14 `01 00`          -> reply `[fileId:4] 00 02 00 00 00 01`
  ///   op 0x03                  status (`03 ...` = recording)
  ///   op 0x1c fileId, 0, 0x280 first block (header), ends with op 0x1d
  ///   op 0x16 fileId, 00       -> `[fileId:4][size:4]...` bytes so far
  ///   op 0x1c fileId, size, 0  stream everything from there on, live
  ///
  /// Returns false (with [message] set) if it could not start.
  Future<bool> startRecording(PlaudCredentials cred, PlaudDeviceCred dev) async {
    try {
      final priv = PlaudCrypto.privateKeyFromPem(cred.rsaPrivateKeyPem!);
      final cmds = await _open(cred, dev);
      _liveCmds = cmds;
      _liveHeadSize = 0x280;
      _livePaused = false;
      _set(PlaudStatus.recording, 'Starting…');

      final start = await _request(cmds, 0x14, const [0x01, 0x00],
          timeout: const Duration(seconds: 6));
      if (start.length < 4) throw StateError('unexpected start reply ${_hex(start)}');
      final fileId = _u32(start, 0);
      _liveFileId = fileId;
      _liveClock
        ..reset()
        ..start();
      _log('recording started, file ${fileId.toRadixString(16)}');

      final live = PlaudLiveScanner(priv, onMark: (ms) {
        _log('recorder highlight at ${ms}ms');
        _markEvents.add(ms);
        notifyListeners();
      });
      _live = live;
      var lastNotify = 0;
      _liveSub = _frames.stream.listen((f) {
        if (f.isData && f.fileId == fileId && f.offset < 0x10000000) {
          live.add(f.offset, f.data);
          // Repaint about once a second, not per 20 ms unit.
          if (live.durationMs - lastNotify >= 1000) {
            lastNotify = live.durationMs;
            notifyListeners();
          }
        }
      });

      await _sendCmd(cmds, 0x03, const []);
      await _settle(ms: 100);
      // First block, then ask how far the recorder has got and stream from
      // there on. Waiting for the block's op 0x1d keeps the order the Plaud
      // app uses; a missing 0x1d only costs the timeout.
      // (op 0x16 is "resume"; on a file that is already recording it just
      // reports the size so far, which is how the Plaud app uses it here.)
      final firstEnd = _awaitFileEnd(fileId, const Duration(seconds: 4));
      await _sendCmd(cmds, 0x1c,
          [..._le32(fileId), ..._le32(0), ..._le32(_liveHeadSize)]);
      await firstEnd;
      var from = _liveHeadSize;
      try {
        final info = await _request(cmds, 0x16, [..._le32(fileId), 0x00],
            timeout: const Duration(seconds: 4));
        if (info.length >= 8) {
          final size = _u32(info, 4);
          if (size > 0) from = size;
        }
      } catch (e) {
        _log('op 0x16 failed ($e); streaming from $from');
      }
      _liveHeadSize = from;
      await _sendCmd(cmds, 0x1c, [..._le32(fileId), ..._le32(from), ..._le32(0)]);
      _set(PlaudStatus.recording, 'Recording');
      return true;
    } catch (e) {
      _log('ERROR $e');
      _set(PlaudStatus.error, '$e');
      await _endLive();
      await _cleanup();
      return false;
    }
  }

  /// Stops the recorder and returns the finished recording (container bytes
  /// plus the recorder-button marks), or null if it could not be retrieved
  /// (it then stays on the recorder for a later sync).
  Future<PlaudLiveRecording?> stopRecording() async {
    final cmds = _liveCmds;
    final fileId = _liveFileId;
    final live = _live;
    if (cmds == null || fileId == null || live == null) return null;
    _liveClock.stop();
    try {
      if (!_connected) {
        throw StateError('lost the connection to the recorder; it keeps '
            'recording until you stop it on the recorder, then sync');
      }
      _set(PlaudStatus.stopping, 'Stopping…');
      final reply = await _request(cmds, 0x17, const [0x01, 0x00]);
      // `[fileId:4] 02 01 [size:4]`
      final size = reply.length >= 10 ? _u32(reply, 6) : 0;
      _log('recording stopped, size=$size');

      // Let the tail of the stream arrive.
      final deadline = DateTime.now().add(const Duration(seconds: 6));
      while (size > 0 &&
          live.receivedEnd < size &&
          DateTime.now().isBefore(deadline)) {
        await _settle(ms: 200);
      }
      // The Plaud app re-reads the start of the file after stop; do the same
      // so a header the recorder finalised at stop is the one we keep.
      final headEnd = _awaitFileEnd(fileId, const Duration(seconds: 4));
      await _sendCmd(cmds, 0x1c, [
        ..._le32(fileId),
        ..._le32(0),
        ..._le32(size > 0 && size < _liveHeadSize ? size : _liveHeadSize),
      ]);
      await headEnd;

      Uint8List bytes;
      if (size > 0 && live.contiguousBytes < size) {
        _log('stream incomplete (${live.contiguousBytes}/$size); downloading');
        await _endLive();
        bytes = await _download(cmds, fileId, size) ?? live.bytes;
      } else {
        bytes = Uint8List.fromList(size > 0
            ? Uint8List.sublistView(live.bytes, 0, size)
            : live.bytes);
      }
      final result = PlaudLiveRecording(fileId, bytes, List.of(live.marks));
      _set(PlaudStatus.done, 'Recording saved');
      return result;
    } catch (e) {
      _log('ERROR $e');
      _set(PlaudStatus.error, '$e');
      return null;
    } finally {
      await _endLive();
      await _cleanup();
    }
  }

  /// Completes when the recorder signals the end of a block for [fileId]
  /// (op 0x1d `[fileId] ffff`), or after [timeout].
  Future<void> _awaitFileEnd(int fileId, Duration timeout) {
    final done = Completer<void>();
    late final StreamSubscription<PlaudFrame> sub;
    sub = _frames.stream.listen((f) {
      if (f.isControl && f.op == 0x1d && f.content.length >= 4 &&
          _u32(f.content, 0) == fileId && !done.isCompleted) {
        done.complete();
      }
    });
    return done.future
        .timeout(timeout, onTimeout: () {})
        .whenComplete(() => sub.cancel());
  }

  Future<void> _endLive() async {
    await _liveSub?.cancel();
    _liveSub = null;
  }

  static int _u32(Uint8List b, int o) =>
      b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  /// Pull a device serial out of the manufacturer data (same extraction as
  /// `PlaudDevicesScreen._serialIn`). The serial is NOT ASCII text — it's 9
  /// raw binary bytes at a fixed offset (captured live: bytes 11-19 of
  /// `590002780304560802020988831804767178688b14000494433b0b0101` hex-encode
  /// to `88831804767178688B`, matching the enrolled credential's serial).
  /// Hex-encode those bytes directly rather than filtering for printable
  /// ASCII first — that filter drops nearly every byte here (most are < 0x20)
  /// and is why extraction always logged `serial=?` on real hardware.
  String? _serialIn(Uint8List data) {
    if (data.length < 20) return null;
    final sb = StringBuffer();
    for (var i = 11; i < 20; i++) {
      sb.write(data[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString().toUpperCase();
  }

  /// [targetSerial]: when set, two Notes nearby could otherwise answer the
  /// generic `PLAUD_NOTE` name race in either order, and the recorder that
  /// isn't enrolled to [targetSerial]'s key rejects the handshake outright —
  /// that's "can only sync with one of my two recorders". Require the
  /// advertised serial (from manufacturer data) to match so we always
  /// connect to the one the selected credential is actually for.
  /// The enrolled recorder this session actually connected to. Usually the
  /// one asked for, but if that one is not around and another recorder on the
  /// account is, it is that one (its own public key must be presented, or the
  /// recorder drops the connection during the handshake).
  PlaudDeviceCred? activeDevice;

  /// Scans for [dev]. Returns the BLE id and the credentials to use: [dev] if
  /// it is advertising, else another enrolled recorder from [known] that is,
  /// else (adverts without a readable serial) the first PLAUD advert with
  /// [dev]'s credentials.
  Future<(String, PlaudDeviceCred)> _scan(
      PlaudDeviceCred dev, List<PlaudDeviceCred> known) async {
    _set(PlaudStatus.scanning, 'Scanning for ${PlaudProtocol.deviceName}…');
    final completer = Completer<(String, PlaudDeviceCred)>();
    (String, PlaudDeviceCred)? otherEnrolled;
    String? unknownId;
    final foreign = <String>{};
    // No service filter: the recorder does not advertise its GATT service UUID
    // (0x1910) — that only appears in the GATT table after connecting. We match
    // by advertised name, then by the serial in the manufacturer data.
    _scanSub = _ble.scanForDevices(
      withServices: const [],
      scanMode: ScanMode.lowLatency,
    ).listen((d) {
      if (completer.isCompleted) return;
      if (d.name != PlaudProtocol.deviceName && !d.name.startsWith('PLAUD')) {
        return;
      }
      final serial = _serialIn(d.manufacturerData);
      if (dev.serial.isEmpty || serial == dev.serial) {
        _log('found ${d.name} ${d.id} serial=$serial rssi=${d.rssi}');
        completer.complete((d.id, dev));
        return;
      }
      if (serial == null) {
        unknownId ??= d.id;
        return;
      }
      final match = known.where((k) => k.serial == serial);
      if (match.isNotEmpty) {
        otherEnrolled ??= (d.id, match.first);
      } else if (foreign.add(serial)) {
        _log('ignoring ${d.name} $serial (not on this account)');
      }
    }, onError: (e) {
      if (!completer.isCompleted) completer.completeError(e);
    });
    final r = await completer.future.timeout(const Duration(seconds: 8),
        onTimeout: () {
      final other = otherEnrolled;
      if (other != null) {
        _log('${dev.serial} not nearby; using ${other.$2.name} '
            '${other.$2.serial} instead');
        return other;
      }
      if (unknownId != null) {
        _log('no serial in adverts; trying ${unknownId!} as ${dev.serial}');
        return (unknownId!, dev);
      }
      throw TimeoutException(foreign.isEmpty
          ? 'recorder not found (is it on and not in the Plaud app?)'
          : 'recorder ${dev.serial} not found; nearby recorder '
              '${foreign.join(', ')} is not on this account');
    });
    await _scanSub?.cancel();
    _scanSub = null;
    return r;
  }


  Future<void> _connect(String id) async {
    _set(PlaudStatus.connecting, 'Connecting…');
    final completer = Completer<void>();
    _connSub = _ble.connectToDevice(
      id: id,
      connectionTimeout: const Duration(seconds: 15),
    ).listen((u) {
      _log('conn ${u.connectionState}');
      if (u.connectionState == DeviceConnectionState.connected) {
        _connected = true;
        if (!completer.isCompleted) completer.complete();
      } else if (u.connectionState == DeviceConnectionState.disconnected) {
        final wasLive = _connected && status == PlaudStatus.recording;
        _connected = false;
        if (wasLive) {
          // The recorder keeps recording on its own; say so instead of
          // pretending the session is still live.
          _set(PlaudStatus.recording,
              'Connection lost. The recorder keeps recording; stop it there and sync later.');
        }
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
        // Data arrives 50 frames a second while a recording streams in; log
        // about one in a hundred so the log (and listeners) aren't flooded.
        if (f.seq % 100 == 0 || f.offset >= 0x10000000) {
          _log('IN data seq=${f.seq} fileId=0x${f.fileId.toRadixString(16)} '
              'off=${f.offset} len=${f.dataLen} head=${_hexHead(f.data)}');
        }
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

  /// The recorder's finished recordings (op 0x1a) that are not in [skip],
  /// newest first.
  Future<List<PlaudFileEntry>> _listToSync(
      PlaudCommands cmds, Set<int> skip) async {
    _set(PlaudStatus.syncing, 'Requesting recordings…');

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
    final todo = <PlaudFileEntry>[];
    for (final e in sorted) {
      // A reported size of 0 means the recorder is still actively writing
      // this file (it's the in-progress recording, not a finished one) — its
      // fileId is allocated the moment recording starts, so it shows up in
      // the list immediately and keeps growing for as long as the mic is
      // live. Downloading it mid-recording yields whatever ambient audio
      // happened to be captured during the sync itself, not a real memo, and
      // never reaches a known end (no size to stop at). Skip it; it will
      // have a real size once the recorder finishes and the user re-syncs.
      if (e.size <= 0) {
        _log('skipping ${e.fileId.toRadixString(16)}: size=0 (still recording)');
        continue;
      }
      if (skip.contains(e.fileId)) {
        _log('skipping ${e.fileId.toRadixString(16)}: already in the library');
        continue;
      }
      todo.add(e);
    }
    return todo;
  }

  Future<Uint8List?> _download(PlaudCommands cmds, int fileId, int knownSize) async {
    // Never issue an unbounded request (e.g. a 0x7FFFFFFF blockSize) — without
    // a known size there is no way to tell a finished file from one the
    // recorder is still actively writing, and requesting "everything" against
    // a live recording downloads for as long as the mic stays on.
    if (knownSize <= 0) {
      _log('refusing to download ${fileId.toRadixString(16)}: unknown size');
      return null;
    }
    _set(PlaudStatus.syncing, 'Downloading ${fileId.toRadixString(16)}…');
    final asm = PlaudFileAssembler(fileId);
    // Seed from the file-list's reported size (op 0x1a) and never let op 0x16
    // overwrite it — op 0x16's own size field is unreliable (seen returning
    // both all-zero and a too-small nonzero value for files that are larger).
    final totalSize = knownSize;
    final done = Completer<void>();
    Timer? idleTimer;
    void bumpIdleTimer() {
      idleTimer?.cancel();
      // No new data for a while after at least one real frame means the
      // device is done (it has no final "stream complete" signal beyond the
      // per-call 0x1d below, which — unlike a real EOF — it also sends after
      // only the sentinel with nothing new, so idle-timeout is the backstop).
      idleTimer = Timer(const Duration(seconds: 15), () {
        if (!done.isCompleted) done.complete();
      });
    }

    final sub = _frames.stream.listen((f) {
      if (f.isData && f.fileId == fileId) {
        // The device appends a trailer/sentinel data frame with
        // offset=0xFFFFFFFF after real data (the official app's own SDK logs
        // this as "EMPTY_PACKAGE, code: 1" and discards it); it must not be
        // treated as real content.
        if (f.offset < totalSize) {
          asm.add(f);
          progress = (asm.bytesReceived % 1000000) / 1000000;
          if (asm.bytesReceived % 8000 < 90) notifyListeners();
          bumpIdleTimer();
          if (asm.bytesReceived >= totalSize && !done.isCompleted) {
            done.complete();
          }
        }
      } else if (f.isControl && f.op == 0x16 && f.content.length >= 8) {
        // op 0x16's reply is not a trustworthy size: observed returning both
        // all-zero and a small bogus nonzero value (512) for files that are
        // actually much larger. totalSize is seeded from the file-list above
        // and must not be overwritten here — this is diagnostic logging only.
        final sz = f.content[4] |
            (f.content[5] << 8) |
            (f.content[6] << 16) |
            (f.content[7] << 24);
        _log('file ${fileId.toRadixString(16)} op0x16 size=$sz (ignored, using known size=$totalSize)');
      } else if (f.isControl && f.op == 0x1d && f.content.length >= 4) {
        final eofFileId = f.content[0] |
            (f.content[1] << 8) |
            (f.content[2] << 16) |
            (f.content[3] << 24);
        if (eofFileId == fileId) bumpIdleTimer();
      }
    });

    // Query the total size first (op 0x16: [fileid:4][00]) — kept for parity
    // with the official app's traffic; its reply is not used (see above).
    await _sendCmd(cmds, 0x16, [..._le32(fileId), 0x00]);
    await _settle(ms: 400);

    // Request the WHOLE file in one call — the device doesn't support
    // resuming a chunked read at a nonzero offset (a second op 0x1c at
    // offset>0 after a small block reliably returned nothing but the
    // sentinel+0x1d). The official app always requests the full known size
    // in one go (findings/decoded_live_capture.txt) and drains however many
    // data notifications follow until done.
    bumpIdleTimer();
    await _sendCmd(
        cmds, 0x1c, [..._le32(fileId), ..._le32(0), ..._le32(totalSize)]);
    await done.future.timeout(const Duration(minutes: 10), onTimeout: () {});
    idleTimer?.cancel();

    await sub.cancel();
    final bytes = asm.assemble();
    if (bytes.isEmpty) return null;
    _log('downloaded ${fileId.toRadixString(16)}: ${bytes.length}B '
        'magic=${String.fromCharCodes(bytes.take(8))}');
    return bytes;
  }

  static List<int> _le32(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

  Future<void> _settle({int ms = 600}) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> _cleanup() async {
    _liveCmds = null;
    _live = null;
    _liveFileId = null;
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
    _endLive();
    _cleanup();
    _frames.close();
    _markEvents.close();
    super.dispose();
  }
}
