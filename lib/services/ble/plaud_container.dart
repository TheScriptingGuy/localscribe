import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'plaud_crypto.dart';

/// Reads the `PLAUD.AI` container that the recorder streams over BLE (the same
/// bytes the vendor app stores as `.opuspa`) and turns it into a normal Ogg
/// Opus file that the transcription pipeline can decode.
///
/// Container layout, determined by comparing matched container/plain pairs from
/// the user's own device (`findings/plaud-ble-phase5.md`):
///
/// ```text
///   0x000  "PLAUD.AI"                  magic
///   0x008  01 00 00 02                 version
///   0x00C  u32                         per-file, purpose unknown
///   0x010  32 bytes                    "userid_…" field (a literal placeholder)
///   0x030  05 00 01 00 01 00 00 00     codec params
///   0x084  12 bytes                    ChaCha20 nonce
///   0x090  u32 = 80                    unit size
///   0x100  256 bytes                   RSA-2048 wrapped content key
///   0x200  N × 80 bytes                audio units
/// ```
///
/// The audio is **not** a custom codec: each 80-byte unit is a standard Opus
/// packet (TOC `0xb8` — CELT wideband, mono, 20 ms, 320 samples @ 16 kHz)
/// XORed with an 80-byte ChaCha20 keystream. The keystream counter is never
/// advanced, so every unit is masked with the *same* 80 bytes. Recovering it
/// needs only the user's own RSA key — the same `e2eeKey` the BLE handshake
/// already uses.
class PlaudContainer {
  static const int headerSize = 0x200;
  static const int unitSize = 80;
  static const int _offNonce = 0x084;
  static const int _offUnitSize = 0x090;
  static const int _offBlob = 0x100;
  static const int _blobLen = 256;

  /// Opus TOC byte every unit decrypts to; also our end-of-audio sentinel.
  static const int _toc = 0xb8;

  static const List<int> _magic = [0x50, 0x4c, 0x41, 0x55, 0x44, 0x2e, 0x41, 0x49];

  final Uint8List bytes;
  PlaudContainer(this.bytes);

  bool get looksValid {
    if (bytes.length < headerSize + unitSize) return false;
    for (var i = 0; i < _magic.length; i++) {
      if (bytes[i] != _magic[i]) return false;
    }
    return true;
  }

  int get declaredUnitSize =>
      ByteData.sublistView(bytes).getUint32(_offUnitSize, Endian.little);

  Uint8List get _nonce => Uint8List.sublistView(bytes, _offNonce, _offNonce + 12);

  Uint8List get _wrappedKey =>
      Uint8List.sublistView(bytes, _offBlob, _offBlob + _blobLen);

  /// The 80-byte mask every unit is XORed with.
  Uint8List keystream(RSAPrivateKey priv) {
    final key = PlaudCrypto.rsaUnwrap(priv, _wrappedKey);
    if (key.length < 32) {
      throw StateError('content key unwrap too short: ${key.length}');
    }
    final engine = ChaCha7539Engine()
      ..init(false, ParametersWithIV(KeyParameter(Uint8List.sublistView(key, 0, 32)),
          _nonce));
    final out = Uint8List(unitSize);
    engine.processBytes(Uint8List(unitSize), 0, unitSize, out, 0);
    return out;
  }

  /// Decrypt to the bare Opus packets, in order.
  ///
  /// Stops at the first unit that does not decrypt to a valid TOC, which is how
  /// the zero padding after the audio is trimmed.
  List<Uint8List> opusPackets(RSAPrivateKey priv) {
    if (!looksValid) throw StateError('not a PLAUD.AI container');
    if (declaredUnitSize != unitSize) {
      throw StateError('unexpected unit size: $declaredUnitSize');
    }
    final ks = keystream(priv);
    final packets = <Uint8List>[];
    for (var off = headerSize; off + unitSize <= bytes.length; off += unitSize) {
      if ((bytes[off] ^ ks[0]) != _toc) break; // padding / end of audio
      final pkt = Uint8List(unitSize);
      for (var i = 0; i < unitSize; i++) {
        pkt[i] = bytes[off + i] ^ ks[i];
      }
      packets.add(pkt);
    }
    return packets;
  }

  /// Full conversion: container bytes -> a playable/decodable Ogg Opus file.
  Uint8List toOggOpus(RSAPrivateKey priv) => _oggOpus(opusPackets(priv));
}

// ---------------------------------------------------------------- Ogg muxing

const int _sampleRate = 16000;
const int _samplesPerPacket48k = 960; // 20 ms at the 48 kHz granule clock
const int _packetsPerPage = 50;

Uint8List _oggOpus(List<Uint8List> packets) {
  final out = BytesBuilder(copy: false);
  final serial = DateTime.now().millisecondsSinceEpoch & 0x7fffffff;
  var seq = 0;

  out.add(_page(_opusHead(), serial, seq++, 0, bos: true));
  out.add(_page(_opusTags(), serial, seq++, 0));

  var granule = 0;
  for (var i = 0; i < packets.length; i += _packetsPerPage) {
    final end = (i + _packetsPerPage < packets.length)
        ? i + _packetsPerPage
        : packets.length;
    final chunk = packets.sublist(i, end);
    granule += chunk.length * _samplesPerPacket48k;
    out.add(_pagePackets(chunk, serial, seq++, granule, eos: end == packets.length));
  }
  return out.toBytes();
}

Uint8List _opusHead() {
  final b = BytesBuilder(copy: false)..add('OpusHead'.codeUnits);
  final d = ByteData(11);
  d.setUint8(0, 1); // version
  d.setUint8(1, 1); // mono
  d.setUint16(2, 0, Endian.little); // pre-skip (unknown; trim nothing)
  d.setUint32(4, _sampleRate, Endian.little);
  d.setUint16(8, 0, Endian.little); // output gain
  d.setUint8(10, 0); // channel mapping family
  b.add(d.buffer.asUint8List());
  return b.toBytes();
}

Uint8List _opusTags() {
  const vendor = 'LocalScribe';
  final b = BytesBuilder(copy: false)..add('OpusTags'.codeUnits);
  final len = ByteData(4)..setUint32(0, vendor.length, Endian.little);
  b.add(len.buffer.asUint8List());
  b.add(vendor.codeUnits);
  final n = ByteData(4)..setUint32(0, 0, Endian.little); // no comments
  b.add(n.buffer.asUint8List());
  return b.toBytes();
}

/// One page holding a single whole packet (used for the two header pages).
Uint8List _page(Uint8List payload, int serial, int seq, int granule,
        {bool bos = false, bool eos = false}) =>
    _pagePackets([payload], serial, seq, granule, bos: bos, eos: eos);

Uint8List _pagePackets(List<Uint8List> packets, int serial, int seq, int granule,
    {bool bos = false, bool eos = false}) {
  // Lacing: each packet becomes ceil(len/255) segments; a packet whose length
  // is a multiple of 255 needs a trailing 0 segment.
  final segments = <int>[];
  for (final p in packets) {
    var n = p.length;
    while (n >= 255) {
      segments.add(255);
      n -= 255;
    }
    segments.add(n);
  }
  if (segments.length > 255) {
    throw StateError('too many segments for one page: ${segments.length}');
  }

  final header = Uint8List(27 + segments.length);
  final hd = ByteData.sublistView(header);
  header.setRange(0, 4, 'OggS'.codeUnits);
  hd.setUint8(4, 0); // stream structure version
  hd.setUint8(5, (bos ? 0x02 : 0) | (eos ? 0x04 : 0));
  hd.setUint64(6, granule, Endian.little);
  hd.setUint32(14, serial, Endian.little);
  hd.setUint32(18, seq, Endian.little);
  hd.setUint32(22, 0, Endian.little); // CRC, filled in below
  hd.setUint8(26, segments.length);
  header.setRange(27, 27 + segments.length, segments);

  final body = BytesBuilder(copy: false);
  for (final p in packets) {
    body.add(p);
  }
  final page = Uint8List(header.length + body.length)
    ..setRange(0, header.length, header)
    ..setRange(header.length, header.length + body.length, body.toBytes());

  ByteData.sublistView(page).setUint32(22, _oggCrc(page), Endian.little);
  return page;
}

/// Ogg's CRC-32: poly 0x04c11db7, init 0, no reflection, no final xor.
final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var r = i << 24;
    for (var j = 0; j < 8; j++) {
      r = ((r & 0x80000000) != 0) ? ((r << 1) ^ 0x04c11db7) : (r << 1);
      r &= 0xffffffff;
    }
    t[i] = r;
  }
  return t;
}();

int _oggCrc(Uint8List data) {
  var crc = 0;
  for (final b in data) {
    crc = ((crc << 8) & 0xffffffff) ^ _crcTable[((crc >> 24) & 0xff) ^ b];
  }
  return crc;
}
