import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'plaud_crypto.dart';

/// One message on the recorder's WiFi link.
///
/// Wire format (Tinnotech PenBleSDK `si.a` / `ti.a`, see
/// findings/plaud-wifi-fast-transfer.md): an 8-byte header
/// `[total:u24 LE][pdu:u8][type:u16 LE][jsonLen:u16 LE]`, a JSON object, then
/// (for file data and file lists) raw bytes up to `total`. With session keys
/// the whole message is prefixed by a u32 LE sequence number and sealed with
/// the BLE session's ChaCha20-Poly1305 key/nonce/aad, like a BLE frame.
class PlaudWifiMsg {
  final int type;
  final int pdu;
  final Map<String, dynamic> json;
  final Uint8List data;
  final bool encrypted;
  PlaudWifiMsg(this.type, this.pdu, this.json, this.data, this.encrypted);

  int intOf(String k) => (json[k] as num?)?.toInt() ?? 0;

  @override
  String toString() => 'type=$type pdu=$pdu ${jsonEncode(json)}'
      '${data.isEmpty ? '' : ' +${data.length}B'}${encrypted ? '' : ' (plain)'}';
}

/// Message types (`t.P` dispatch and the `si`/`ti` request/response classes).
class PlaudWifiType {
  static const error = 0; // UniversalErr {cmd,status}
  static const handshake = 1; // app -> {token,stamp}; rec -> {status}
  static const hello = 2; // rec -> {token: md5hex(serial), pVer}
  static const heartbeat = 3; // rec ping {volume,voltage,charging}; app pong {}
  static const closing = 4; // rec -> {status}: back to Bluetooth mode
  static const tips = 5;
  static const fileList = 11;
  static const fileSync = 12; // app {session,scene,start,end}; rec {session,status}
  static const fileData = 13; // rec {session,offset,length,last} + bytes
  static const fileDelete = 14;
  static const fileSyncStop = 15;
  static const extendExit = 16;
}

/// The phone side of Plaud "fast transfer": after BLE op 0x0a makes the
/// recorder open its own access point and the phone has joined it, the phone
/// runs a WebSocket server on port 8081 and the recorder connects to it.
class PlaudWifiLink {
  static const port = 8081;

  final PlaudSessionKeys keys;
  final int Function() nextSeq;
  final String serial;
  final String token;
  final void Function(String) log;

  PlaudWifiLink({
    required this.keys,
    required this.nextSeq,
    required this.serial,
    required this.token,
    required this.log,
  });

  HttpServer? _server;
  WebSocket? _ws;
  bool _encrypted = true;
  int _pdu = 1;
  final _msgs = StreamController<PlaudWifiMsg>.broadcast();
  final _clientUp = Completer<void>();

  Stream<PlaudWifiMsg> get messages => _msgs.stream;
  bool get connected => _ws != null;

  /// Start the WebSocket server the recorder connects to.
  Future<void> listen() async {
    final server =
        await HttpServer.bind(InternetAddress.anyIPv4, port, shared: true);
    _server = server;
    log('wifi: listening on :$port');
    server.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        log('wifi: non-websocket ${req.method} ${req.uri} '
            'from ${req.connectionInfo?.remoteAddress.address}');
        req.response.statusCode = HttpStatus.notFound;
        await req.response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      log('wifi: recorder connected from '
          '${req.connectionInfo?.remoteAddress.address} ${req.uri}');
      await _ws?.close();
      _ws = ws;
      if (!_clientUp.isCompleted) _clientUp.complete();
      ws.listen((d) {
        if (d is List<int>) {
          _onData(Uint8List.fromList(d));
        } else {
          log('wifi: text message $d');
        }
      }, onDone: () {
        log('wifi: recorder disconnected (${ws.closeCode} ${ws.closeReason})');
        if (identical(_ws, ws)) _ws = null;
      }, onError: (e) => log('wifi: socket error $e'));
    });
  }

  /// Waits for the recorder to connect and say hello, then authenticates.
  Future<void> handshake({Duration timeout = const Duration(seconds: 40)}) async {
    final hello = _next(PlaudWifiType.hello, timeout);
    await _clientUp.future.timeout(timeout,
        onTimeout: () =>
            throw TimeoutException('the recorder did not connect over WiFi'));
    final h = await hello;
    _pdu = h.pdu;
    _encrypted = h.encrypted;
    final want = md5.convert(utf8.encode(serial)).toString().toUpperCase();
    final got = (h.json['token'] as String? ?? '').toUpperCase();
    if (got != want) log('wifi: hello token $got != md5(serial) $want');
    var t = token;
    if (t.length < 32) t = t.padRight(32, '0');
    final reply = _next(PlaudWifiType.handshake, const Duration(seconds: 10));
    send(PlaudWifiType.handshake,
        {'token': t, 'stamp': DateTime.now().millisecondsSinceEpoch ~/ 1000});
    final r = await reply;
    if (r.intOf('status') != 0) {
      throw StateError('WiFi handshake refused (status ${r.intOf('status')})');
    }
    log('wifi: handshake ok (pVer ${h.json['pVer']}, pdu $_pdu, '
        '${_encrypted ? 'encrypted' : 'plaintext'})');
  }

  /// Downloads `[0, size)` of [session] (a file id). The recorder streams
  /// type-13 chunks; a gap or a stall re-requests from the first missing byte,
  /// as the Plaud app does. Returns null if it could not finish.
  Future<Uint8List?> download(int session, int size,
      {void Function(int received)? onProgress}) async {
    final buf = Uint8List(size);
    var have = 0;
    var attempts = 0;
    while (have < size && attempts < 6 && connected) {
      attempts++;
      final done = Completer<bool>();
      var last = DateTime.now();
      final sub = messages.listen((m) {
        if (m.type == PlaudWifiType.fileSync) {
          if (m.intOf('status') != 0 && !done.isCompleted) {
            log('wifi: sync refused ${m.json}');
            done.complete(false);
          }
          return;
        }
        if (m.type != PlaudWifiType.fileData || m.intOf('session') != session) {
          return;
        }
        last = DateTime.now();
        final off = m.intOf('offset');
        if (off == have) {
          final n = (size - have).clamp(0, m.data.length);
          buf.setRange(have, have + n, m.data);
          have += n;
          onProgress?.call(have);
        } else if (off > have && !done.isCompleted) {
          log('wifi: gap at $have (got $off); re-requesting');
          done.complete(true);
          return;
        }
        if ((m.intOf('last') == 1 || have >= size) && !done.isCompleted) {
          done.complete(true);
        }
      });
      final stall = Timer.periodic(const Duration(seconds: 1), (_) {
        if (DateTime.now().difference(last).inSeconds >= 6 &&
            !done.isCompleted) {
          log('wifi: stalled at $have/$size');
          done.complete(true);
        }
      });
      log('wifi: sync ${session.toRadixString(16)} from $have to $size');
      send(PlaudWifiType.fileSync,
          {'session': session, 'scene': 0, 'start': have, 'end': size});
      final ok = await done.future;
      stall.cancel();
      await sub.cancel();
      if (!ok) break;
      if (have < size) {
        send(PlaudWifiType.fileSyncStop, {'session': session, 'scene': 0});
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    if (have < size) {
      log('wifi: ${session.toRadixString(16)} incomplete $have/$size');
      return null;
    }
    return buf;
  }

  void send(int type, Map<String, dynamic> json) {
    final ws = _ws;
    if (ws == null) throw StateError('WiFi link is down');
    final j = utf8.encode(jsonEncode(json));
    final total = j.length + 8;
    final pkt = Uint8List(total)
      ..[0] = total & 0xff
      ..[1] = (total >> 8) & 0xff
      ..[2] = (total >> 16) & 0xff
      ..[3] = _pdu
      ..[4] = type & 0xff
      ..[5] = (type >> 8) & 0xff
      ..[6] = j.length & 0xff
      ..[7] = (j.length >> 8) & 0xff
      ..setRange(8, total, j);
    if (type != PlaudWifiType.heartbeat) {
      log('wifi: OUT type=$type ${jsonEncode(json)}');
    }
    if (!_encrypted) {
      ws.add(pkt);
      return;
    }
    final seq = nextSeq();
    final plain = Uint8List(4 + total)
      ..[0] = seq & 0xff
      ..[1] = (seq >> 8) & 0xff
      ..[2] = (seq >> 16) & 0xff
      ..[3] = (seq >> 24) & 0xff
      ..setRange(4, 4 + total, pkt);
    ws.add(PlaudCrypto.frameEncrypt(keys, plain));
  }

  Future<PlaudWifiMsg> _next(int type, Duration timeout) =>
      messages.firstWhere((m) => m.type == type).timeout(timeout,
          onTimeout: () =>
              throw TimeoutException('no WiFi reply of type $type'));

  void _onData(Uint8List raw) {
    PlaudWifiMsg? m;
    if (raw.length >= 4 + 8 + 16) {
      try {
        final p = PlaudCrypto.frameDecrypt(keys, raw);
        m = _parse(Uint8List.sublistView(p, 4), true);
      } catch (_) {/* not sealed with the session key: try plaintext */}
    }
    m ??= _parse(raw, false);
    if (m == null) {
      log('wifi: unparsed ${raw.length}B ${_hex(raw.take(24))}');
      return;
    }
    switch (m.type) {
      case PlaudWifiType.heartbeat:
        send(PlaudWifiType.heartbeat, const {});
      case PlaudWifiType.fileData:
        break; // too chatty to log
      default:
        log('wifi: IN $m');
    }
    if (!_msgs.isClosed) _msgs.add(m);
  }

  static PlaudWifiMsg? _parse(Uint8List b, bool encrypted) {
    if (b.length < 8) return null;
    final jl = b[6] | (b[7] << 8);
    if (8 + jl > b.length) return null;
    final total = b[0] | (b[1] << 8) | (b[2] << 16);
    Map<String, dynamic> json;
    try {
      final j = jl == 0 ? const <String, dynamic>{} : jsonDecode(utf8.decode(
          Uint8List.sublistView(b, 8, 8 + jl)));
      if (j is! Map<String, dynamic>) return null;
      json = j;
    } catch (_) {
      return null;
    }
    final end = total >= 8 + jl && total <= b.length ? total : b.length;
    return PlaudWifiMsg(b[4] | (b[5] << 8), b[3], json,
        Uint8List.sublistView(b, 8 + jl, end), encrypted);
  }

  Future<void> close() async {
    try {
      await _ws?.close();
    } catch (_) {}
    _ws = null;
    await _server?.close(force: true);
    _server = null;
    await _msgs.close();
  }

  static String _hex(Iterable<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
