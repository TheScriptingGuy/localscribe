import 'dart:typed_data';

import 'plaud_crypto.dart';

/// Wire framing for the Plaud BLE protocol, reverse-engineered and verified
/// (`findings/plaud-ble-phase5.md`). Clean-room; used only with the user's own
/// device + credentials.
///
/// Handshake frames (cleartext):
///   write  `10 FE 03 <seq>` + pubkey chunk   (seq 0,1,2; 100/100/56 bytes)
///   notify `12 FE 03 <seq>` + wrapped chunk  (reassemble to 256 bytes)
/// After the handshake every frame is ChaCha20-Poly1305 (see [PlaudCrypto]) and
/// decrypts to:
///   control: `[seq:4 LE][0x01][op][status][content]`
///   data:    `[seq:4 LE][0x02][fileId:4][offset:4 LE][len:1][bytes]`
class PlaudProtocol {
  static const svc = '00001910-0000-1000-8000-00805f9b34fb';
  static const chWrite = '00002bb1-0000-1000-8000-00805f9b34fb';
  static const chNotify = '00002bb0-0000-1000-8000-00805f9b34fb';
  static const deviceName = 'PLAUD_NOTE';

  // handshake
  // Device key is presented with `20 FE 03 <seq>` (the first-connect/enroll
  // variant captured live; `10 FE 03` is the reconnect variant — both work).
  static List<Uint8List> keyWriteFrames(Uint8List devicePublicKey256) {
    assert(devicePublicKey256.length == 256);
    final sizes = [100, 100, 56];
    final frames = <Uint8List>[];
    var off = 0;
    for (var seq = 0; seq < 3; seq++) {
      final n = sizes[seq];
      final b = BytesBuilder()
        ..add([0x20, 0xFE, 0x03, seq])
        ..add(Uint8List.sublistView(devicePublicKey256, off, off + n));
      frames.add(b.toBytes());
      off += n;
    }
    return frames;
  }

  /// `12 FE 05 <seq>` + the user's RSA public key PEM (100-byte chunks).
  ///
  /// This is the enrollment/provisioning write: it tells the recorder which
  /// user public key to wrap session (and at-rest content) keys to. Verified
  /// against a fresh key in `findings/plaud-fresh-enroll-verified.md` — no cloud
  /// needed, the device accepts whatever key is presented here.
  static List<Uint8List> userKeyWriteFrames(List<int> userPublicKeyPem) {
    final frames = <Uint8List>[];
    var off = 0;
    var seq = 0;
    while (off < userPublicKeyPem.length) {
      final n = (off + 100 < userPublicKeyPem.length)
          ? 100
          : userPublicKeyPem.length - off;
      final b = BytesBuilder()
        ..add([0x12, 0xFE, 0x05, seq])
        ..add(userPublicKeyPem.sublist(off, off + n));
      frames.add(b.toBytes());
      off += n;
      seq++;
    }
    return frames;
  }

  static bool isKeyNotify(List<int> f) =>
      f.length > 4 && f[0] == 0x12 && f[1] == 0xFE && f[2] == 0x03;

  /// Reassemble the 3 `12 FE 03` notify chunks (keyed by seq) into 256 bytes.
  static Uint8List? reassembleWrapped(Map<int, List<int>> chunks) {
    if (!(chunks.containsKey(0) && chunks.containsKey(1) && chunks.containsKey(2))) {
      return null;
    }
    final b = BytesBuilder()
      ..add(chunks[0]!)
      ..add(chunks[1]!)
      ..add(chunks[2]!);
    final all = b.toBytes();
    return all.length >= 256 ? Uint8List.sublistView(all, 0, 256) : null;
  }
}

/// A decrypted frame.
class PlaudFrame {
  final int seq;
  final int type; // 1 control, 2 data
  final Uint8List body; // bytes after [seq:4][type]

  PlaudFrame(this.seq, this.type, this.body);

  static PlaudFrame parse(Uint8List pt) {
    final seq = pt.buffer.asByteData(pt.offsetInBytes).getUint32(0, Endian.little);
    final type = pt.length > 4 ? pt[4] : 0;
    return PlaudFrame(seq, type, Uint8List.sublistView(pt, pt.length > 5 ? 5 : pt.length));
  }

  bool get isControl => type == 0x01;
  bool get isData => type == 0x02;
  int get op => isControl && body.isNotEmpty ? body[0] : -1;
  int get status => isControl && body.length > 1 ? body[1] : -1;
  Uint8List get content => isControl && body.length > 2
      ? Uint8List.sublistView(body, 2)
      : Uint8List(0);

  // data frame fields
  int get fileId => isData ? _u32(body, 0) : 0;
  int get offset => isData ? _u32(body, 4) : 0;
  int get dataLen => isData && body.length > 8 ? body[8] : 0;
  Uint8List get data => isData && body.length > 9
      ? Uint8List.sublistView(body, 9, (9 + dataLen).clamp(9, body.length))
      : Uint8List(0);

  static int _u32(Uint8List b, int o) =>
      (o + 4 <= b.length) ? b.buffer.asByteData(b.offsetInBytes).getUint32(o, Endian.little) : 0;
}

/// Builds encrypted outbound control frames.
class PlaudCommands {
  final PlaudSessionKeys keys;
  int _seq;
  PlaudCommands(this.keys, {int startSeq = 2}) : _seq = startSeq;

  int get nextSeq => _seq;

  Uint8List _control(int op, List<int> content, {int status = 0}) {
    final b = BytesBuilder()
      ..add(_le32(_seq++))
      ..add([0x01, op, status])
      ..add(content);
    return PlaudCrypto.frameEncrypt(keys, b.toBytes());
  }

  /// op 0x01 — auth; content = `02 00 00` + ascii user id.
  Uint8List auth(String userId) =>
      _control(0x01, [0x02, 0x00, 0x00, ...userId.codeUnits]);

  /// op 0x6c — device info (name).
  Uint8List deviceInfo() => _control(0x6c, const []);

  /// op 0x1a — list pending files. Content = `[echo:4][count:4 LE]` +
  /// `count` × `[fileId:4][size:4 LE][flags:2]` records. Verified against a
  /// live capture of the real app (`findings/decoded_live_capture.txt`):
  /// `op 0x03` always echoes back an empty/"no file" shape regardless of
  /// what's actually queued — it is NOT the list opcode, despite earlier
  /// notes assuming so. Use the top-level [parseFileList] on the response.
  Uint8List listFiles() => _control(0x1a, List<int>.filled(9, 0));

  /// op 0x1c — download: [fileId:4][offset:4][blockSize:4].
  Uint8List download(int fileId, int offset, int blockSize) => _control(
        0x1c,
        [..._le32(fileId), ..._le32(offset), ..._le32(blockSize)],
      );

  /// Raw opcode with content (for replaying/experimenting).
  Uint8List raw(int op, List<int> content) => _control(op, content);

  static List<int> _le32(int v) =>
      [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];
}

/// One entry from an `op 0x1a` file-list response.
class PlaudFileEntry {
  final int fileId;
  final int size;
  final int flags;
  PlaudFileEntry(this.fileId, this.size, this.flags);
}

/// Parses an `op 0x1a` response content into its file records.
List<PlaudFileEntry> parseFileList(Uint8List content) {
  final entries = <PlaudFileEntry>[];
  if (content.length < 8) return entries;
  final count = content.buffer
      .asByteData(content.offsetInBytes)
      .getUint32(4, Endian.little);
  var off = 8;
  for (var i = 0; i < count && off + 10 <= content.length; i++) {
    final bd = content.buffer.asByteData(content.offsetInBytes + off);
    final fileId = bd.getUint32(0, Endian.little);
    final size = bd.getUint32(4, Endian.little);
    final flags = bd.getUint16(8, Endian.little);
    entries.add(PlaudFileEntry(fileId, size, flags));
    off += 10;
  }
  return entries;
}

/// Collects type-0x02 data frames for one file id and reassembles the file
/// bytes in offset order.
class PlaudFileAssembler {
  final int fileId;
  final _chunks = <int, Uint8List>{};
  int _maxEnd = 0;

  PlaudFileAssembler(this.fileId);

  void add(PlaudFrame f) {
    if (!f.isData || f.fileId != fileId) return;
    _chunks[f.offset] = f.data;
    final end = f.offset + f.data.length;
    if (end > _maxEnd) _maxEnd = end;
  }

  int get bytesReceived => _maxEnd;

  Uint8List assemble() {
    final b = BytesBuilder();
    final offs = _chunks.keys.toList()..sort();
    for (final o in offs) {
      b.add(_chunks[o]!);
    }
    return b.toBytes();
  }
}
