import 'dart:convert';
import 'dart:typed_data';

/// Minimal ZIP container using the "stored" method (no compression), which is
/// all a .docx needs and keeps us free of an archive dependency.
class ZipWriter {
  final _names = <List<int>>[];
  final _data = <Uint8List>[];

  void addText(String name, String text) =>
      add(name, Uint8List.fromList(utf8.encode(text)));

  void add(String name, Uint8List data) {
    _names.add(utf8.encode(name));
    _data.add(data);
  }

  Uint8List build() {
    final out = BytesBuilder();
    final crcs = <int>[];
    final offsets = <int>[];

    void u16(BytesBuilder b, int v) =>
        b.add([v & 0xFF, (v >> 8) & 0xFF]);
    void u32(BytesBuilder b, int v) => b.add(
        [v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

    // DOS date 1980-01-01 00:00:00.
    const dosTime = 0;
    const dosDate = 0x0021;
    const flags = 0x0800; // UTF-8 names

    for (var i = 0; i < _names.length; i++) {
      final crc = crc32(_data[i]);
      crcs.add(crc);
      offsets.add(out.length);
      u32(out, 0x04034b50);
      u16(out, 20); // version needed
      u16(out, flags);
      u16(out, 0); // stored
      u16(out, dosTime);
      u16(out, dosDate);
      u32(out, crc);
      u32(out, _data[i].length);
      u32(out, _data[i].length);
      u16(out, _names[i].length);
      u16(out, 0); // extra
      out.add(_names[i]);
      out.add(_data[i]);
    }

    final cdStart = out.length;
    for (var i = 0; i < _names.length; i++) {
      u32(out, 0x02014b50);
      u16(out, 20); // made by
      u16(out, 20); // needed
      u16(out, flags);
      u16(out, 0);
      u16(out, dosTime);
      u16(out, dosDate);
      u32(out, crcs[i]);
      u32(out, _data[i].length);
      u32(out, _data[i].length);
      u16(out, _names[i].length);
      u16(out, 0); // extra
      u16(out, 0); // comment
      u16(out, 0); // disk
      u16(out, 0); // internal attrs
      u32(out, 0); // external attrs
      u32(out, offsets[i]);
      out.add(_names[i]);
    }
    final cdSize = out.length - cdStart;

    u32(out, 0x06054b50);
    u16(out, 0);
    u16(out, 0);
    u16(out, _names.length);
    u16(out, _names.length);
    u32(out, cdSize);
    u32(out, cdStart);
    u16(out, 0); // comment length
    return out.toBytes();
  }
}

final _crcTable = () {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1);
    }
    t[n] = c;
  }
  return t;
}();

int crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
