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

  /// Milliseconds of audio per unit.
  static const int unitMs = 20;

  /// The recorder's highlight mark: when the record button is pressed briefly
  /// during a recording, the firmware writes the unit at that moment with TOC
  /// `0xb9` instead of `0xb8` (verified with Frida against the Plaud app:
  /// one press -> exactly one such unit, at the press time).
  static const int markToc = 0xb9;

  /// A decrypted first byte that belongs to audio: the normal TOC or a mark.
  static bool isAudioToc(int toc) => toc == _toc || toc == markToc;

  /// Decrypt to the bare Opus packets, in order, plus the highlight times.
  ///
  /// Stops at the first unit that does not decrypt to a valid TOC, which is how
  /// the zero padding after the audio is trimmed. Mark units are restored to
  /// the normal TOC so they decode like every other packet.
  PlaudAudio decode(RSAPrivateKey priv) {
    if (!looksValid) throw StateError('not a PLAUD.AI container');
    if (declaredUnitSize != unitSize) {
      throw StateError('unexpected unit size: $declaredUnitSize');
    }
    final ks = keystream(priv);
    final packets = <Uint8List>[];
    final marks = <int>[];
    for (var off = headerSize; off + unitSize <= bytes.length; off += unitSize) {
      final toc = bytes[off] ^ ks[0];
      if (!isAudioToc(toc)) break; // padding / end of audio
      final pkt = Uint8List(unitSize);
      for (var i = 0; i < unitSize; i++) {
        pkt[i] = bytes[off + i] ^ ks[i];
      }
      if (toc == markToc) {
        marks.add(packets.length * unitMs);
        pkt[0] = _toc;
      }
      packets.add(pkt);
    }
    return PlaudAudio(packets, marks);
  }

  /// Decrypt to the bare Opus packets, in order (see [decode]).
  List<Uint8List> opusPackets(RSAPrivateKey priv) => decode(priv).packets;

  /// Full conversion: container bytes -> a playable/decodable Ogg Opus file.
  Uint8List toOggOpus(RSAPrivateKey priv) => _oggOpus(opusPackets(priv));

  /// Ogg Opus bytes for already-decoded packets.
  static Uint8List oggOpusOf(List<Uint8List> packets) => _oggOpus(packets);
}

/// Decoded recording: Opus packets (20 ms each) and the times, in ms from the
/// start, where the recorder's button marked a highlight.
class PlaudAudio {
  final List<Uint8List> packets;
  final List<int> markMs;
  const PlaudAudio(this.packets, this.markMs);

  int get durationMs => packets.length * PlaudContainer.unitMs;
}

/// Finds highlight marks in a recording while it is still streaming in.
///
/// Feed it the file bytes as they arrive (by file offset); once the
/// 0x200-byte header is in, it derives the keystream and checks the first
/// byte of every complete 80-byte unit. Bytes are kept by offset: the live
/// stream jumps from the header to the current size, and that gap is only
/// filled by the re-read after stop, so units are checked wherever they are.
class PlaudLiveScanner {
  final RSAPrivateKey priv;
  final void Function(int atMs)? onMark;
  PlaudLiveScanner(this.priv, {this.onMark});

  Uint8List _buf = Uint8List(64 * 1024);
  int _maxEnd = 0;

  /// Received byte ranges, sorted, disjoint, merged: [start, end) pairs.
  final _ranges = <List<int>>[];
  Uint8List? _ks;

  /// Per unit: 1 once its first byte has been checked.
  Uint8List _scanned = Uint8List(4096);
  final List<int> marks = [];

  /// End of the furthest bytes received.
  int get receivedEnd => _maxEnd;

  /// Bytes received without gaps from offset 0.
  int get contiguousBytes =>
      _ranges.isNotEmpty && _ranges.first[0] == 0 ? _ranges.first[1] : 0;

  /// How far into the recording the received audio reaches. This is the
  /// position the Plaud app gives highlights: the live stream skips from the
  /// header to the current size (the gap is fetched after stop), so it is the
  /// highest offset received, not the gap-free prefix.
  int get durationMs {
    final units =
        (_maxEnd - PlaudContainer.headerSize) ~/ PlaudContainer.unitSize;
    return units > 0 ? units * PlaudContainer.unitMs : 0;
  }

  /// The gap-free file bytes received so far.
  Uint8List get bytes => Uint8List.sublistView(_buf, 0, contiguousBytes);

  void add(int offset, Uint8List data) {
    if (data.isEmpty) return;
    final end = offset + data.length;
    _write(offset, data);
    _cover(offset, end);
    if (end > _maxEnd) _maxEnd = end;

    if (_ks == null) {
      if (contiguousBytes < PlaudContainer.headerSize) return;
      try {
        _ks = PlaudContainer(Uint8List.fromList(
                Uint8List.sublistView(_buf, 0, PlaudContainer.headerSize)))
            .keystream(priv);
      } catch (_) {
        return; // header not usable yet
      }
      // Everything that arrived before the header could be read.
      for (final r in List.of(_ranges)) {
        _scanRange(r[0], r[1]);
      }
      return;
    }
    _scanRange(offset, end);
  }

  /// Checks every unit lying fully inside received bytes around [from, to).
  void _scanRange(int from, int to) {
    const h = PlaudContainer.headerSize, u = PlaudContainer.unitSize;
    final first = from <= h ? 0 : (from - h) ~/ u;
    final last = (to - h) ~/ u; // exclusive
    for (var k = first; k < last; k++) {
      final off = h + k * u;
      if (_isScanned(k) || !_covered(off, off + u)) continue;
      _setScanned(k);
      if ((_buf[off] ^ _ks![0]) == PlaudContainer.markToc) {
        final at = k * PlaudContainer.unitMs;
        var i = marks.length;
        while (i > 0 && marks[i - 1] > at) {
          i--;
        }
        marks.insert(i, at);
        onMark?.call(at);
      }
    }
  }

  bool _isScanned(int k) => k < _scanned.length && _scanned[k] == 1;

  void _setScanned(int k) {
    if (k >= _scanned.length) {
      var n = _scanned.length * 2;
      while (n <= k) {
        n *= 2;
      }
      _scanned = Uint8List(n)..setRange(0, _scanned.length, _scanned);
    }
    _scanned[k] = 1;
  }

  void _cover(int s, int e) {
    var i = 0;
    while (i < _ranges.length && _ranges[i][1] < s) {
      i++;
    }
    var ns = s, ne = e;
    while (i < _ranges.length && _ranges[i][0] <= ne) {
      if (_ranges[i][0] < ns) ns = _ranges[i][0];
      if (_ranges[i][1] > ne) ne = _ranges[i][1];
      _ranges.removeAt(i);
    }
    _ranges.insert(i, [ns, ne]);
  }

  bool _covered(int s, int e) {
    for (final r in _ranges) {
      if (r[0] <= s && r[1] >= e) return true;
      if (r[0] > s) return false;
    }
    return false;
  }

  void _write(int offset, Uint8List data) {
    final end = offset + data.length;
    if (end > _buf.length) {
      var n = _buf.length * 2;
      while (n < end) {
        n *= 2;
      }
      _buf = Uint8List(n)..setRange(0, _buf.length, _buf);
    }
    _buf.setRange(offset, end, data);
  }
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
