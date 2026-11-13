/// Titles for recordings are renamed after the first note is written, like
/// Plaud does, but only while the recording still has a machine-made name.
library;

final _timestampName = RegExp(r'^\d{4}-\d{2}-\d{2}[ T_]\d{2}[:.\-]\d{2}([:.\-]\d{2})?$');
final _plaudName = RegExp(r'^Plaud Note\b', caseSensitive: false);
final _recordingName = RegExp(r'^Recording\b', caseSensitive: false);
final _audioName = RegExp(r'^(audio|voice|rec|new recording)[ _\-]?\d*$',
    caseSensitive: false);

/// True for names LocalScribe, Plaud or the recorder generated themselves
/// ("Recording 13 Nov", "Plaud Note 6af71e15", "2026-11-13 15:17:06").
bool isAutoTitle(String title) {
  final t = title.trim();
  if (t.isEmpty) return true;
  return _recordingName.hasMatch(t) ||
      _plaudName.hasMatch(t) ||
      _timestampName.hasMatch(t) ||
      _audioName.hasMatch(t);
}

/// The first `# Heading` of a generated note, cleaned up for use as a title.
String? titleFromNote(String content) {
  final raw = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(content)?.group(1);
  if (raw == null) return null;
  var t = raw
      .replaceAll(RegExp(r'[*_`]+'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  t = t.replaceAll(RegExp(r'[.:;,\-–— ]+$'), '');
  if (t.isEmpty) return null;
  if (t.length > 80) t = '${t.substring(0, 79).trimRight()}…';
  return t;
}
