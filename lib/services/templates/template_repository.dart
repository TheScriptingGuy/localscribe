import 'dart:convert';
import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/note_template.dart';

/// Loads bundled default templates from assets and user templates from local
/// storage. No network, no Plaud servers.
class TemplateRepository {
  static const _prefsKey = 'custom_templates_v1';

  final List<NoteTemplate> _builtin = [];
  final List<NoteTemplate> _custom = [];

  List<NoteTemplate> get all => [..._builtin, ..._custom];
  List<NoteTemplate> get builtin => List.unmodifiable(_builtin);
  List<NoteTemplate> get custom => List.unmodifiable(_custom);

  NoteTemplate? byId(String id) {
    for (final t in all) {
      if (t.id == id) return t;
    }
    return null;
  }

  Future<void> load() async {
    await _loadBuiltin();
    await _loadCustom();
  }

  Future<void> _loadBuiltin() async {
    _builtin.clear();
    // Discover bundled template JSONs via the asset manifest so adding a file
    // to assets/templates/ is enough — no hard-coded list.
    List<String> keys;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      keys = manifest
          .listAssets()
          .where((k) =>
              k.startsWith('assets/templates/') && k.endsWith('.json'))
          .toList();
    } catch (_) {
      // Fallback for older Flutter without AssetManifest API.
      keys = const [
        'assets/templates/meeting_minutes.json',
        'assets/templates/chat_note.json',
        'assets/templates/todo_list.json',
        'assets/templates/general_summary.json',
        'assets/templates/key_points.json',
      ];
    }
    for (final k in keys) {
      try {
        final raw = await rootBundle.loadString(k);
        _builtin.add(
            NoteTemplate.fromJson(jsonDecode(raw) as Map<String, dynamic>));
      } catch (_) {
        // Skip malformed asset; keep the app running.
      }
    }
    _builtin.sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> _loadCustom() async {
    _custom.clear();
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final list = jsonDecode(raw) as List;
      for (final e in list) {
        _custom.add(NoteTemplate.fromJson(
            Map<String, dynamic>.from(e as Map),
            custom: true));
      }
    } catch (_) {
      // Ignore corrupt store.
    }
  }

  Future<void> saveCustom(NoteTemplate t) async {
    final idx = _custom.indexWhere((e) => e.id == t.id);
    if (idx >= 0) {
      _custom[idx] = t;
    } else {
      _custom.add(t);
    }
    await _persist();
  }

  Future<void> deleteCustom(String id) async {
    _custom.removeWhere((e) => e.id == id);
    await _persist();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode(_custom.map((e) => e.toJson()).toList()));
  }
}
