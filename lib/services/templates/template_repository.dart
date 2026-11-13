import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/note_template.dart';

/// Loads bundled default templates from assets and user templates from local
/// storage. No network, no Plaud servers.
class TemplateRepository extends ChangeNotifier {
  static const _prefsKey = 'custom_templates_v1';
  static const _favKey = 'template_favorites_v1';
  static const _recentKey = 'template_recent_v1';
  static const _defaultKey = 'template_default_v1';
  static const _recentMax = 8;

  final List<String> _favorites = [];
  final List<String> _recent = [];
  String? _defaultId;

  final List<NoteTemplate> _builtin = [];
  final List<NoteTemplate> _custom = [];

  TemplateRepository();

  /// A repository holding exactly [templates], without touching assets or
  /// storage. For tests.
  @visibleForTesting
  TemplateRepository.withTemplates(List<NoteTemplate> templates) {
    _builtin.addAll(templates);
  }

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
    final prefs = await SharedPreferences.getInstance();
    _favorites
      ..clear()
      ..addAll(prefs.getStringList(_favKey) ?? const []);
    _recent
      ..clear()
      ..addAll(prefs.getStringList(_recentKey) ?? const []);
    _defaultId = prefs.getString(_defaultKey);
  }

  // --- Favourites, recents, "set for next use" -----------------------------

  List<NoteTemplate> get favorites =>
      _favorites.map(byId).whereType<NoteTemplate>().toList();

  /// Most recently used first, at most [_recentMax].
  List<NoteTemplate> get recent =>
      _recent.map(byId).whereType<NoteTemplate>().toList();

  bool isFavorite(String id) => _favorites.contains(id);

  Future<void> toggleFavorite(String id) async {
    if (!_favorites.remove(id)) _favorites.insert(0, id);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_favKey, _favorites);
  }

  Future<void> markUsed(String id) async {
    _recent
      ..remove(id)
      ..insert(0, id);
    if (_recent.length > _recentMax) _recent.removeRange(_recentMax, _recent.length);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_recentKey, _recent);
  }

  /// The template used instead of "Auto" when one is set; null = Auto.
  NoteTemplate? get defaultTemplate =>
      _defaultId == null ? null : byId(_defaultId!);

  bool isDefault(String id) => _defaultId == id;

  /// Pass null to go back to Auto.
  Future<void> setDefault(String? id) async {
    _defaultId = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_defaultKey);
    } else {
      await prefs.setString(_defaultKey, id);
    }
  }

  // --- Search ----------------------------------------------------------------

  /// Templates matching every word of [query], best matches first: name
  /// starts-with, then name contains, then tags/category, then description.
  List<NoteTemplate> search(String query) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return all;
    final scored = <(NoteTemplate, int)>[];
    for (final t in all) {
      final score = _score(t, words);
      if (score > 0) scored.add((t, score));
    }
    scored.sort((a, b) {
      final c = b.$2.compareTo(a.$2);
      return c != 0 ? c : a.$1.name.compareTo(b.$1.name);
    });
    return [for (final e in scored) e.$1];
  }

  static int _score(NoteTemplate t, List<String> words) {
    final name = t.name.toLowerCase();
    final desc = t.description.toLowerCase();
    final tags = t.tags.map((e) => e.toLowerCase()).toList();
    final cat = t.category.toLowerCase();
    var total = 0;
    for (final w in words) {
      var best = 0;
      if (name.startsWith(w)) {
        best = 100;
      } else if (name.split(RegExp(r'[^a-z0-9]+')).any((p) => p.startsWith(w))) {
        best = 90;
      } else if (name.contains(w)) {
        best = 70;
      } else if (tags.any((e) => e.contains(w)) || cat.contains(w)) {
        best = 50;
      } else if (desc.contains(w)) {
        best = 25;
      }
      if (best == 0) return 0; // every word must match somewhere
      total += best;
    }
    return total;
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
    notifyListeners();
  }

  Future<void> deleteCustom(String id) async {
    _custom.removeWhere((e) => e.id == id);
    _favorites.remove(id);
    _recent.remove(id);
    if (_defaultId == id) _defaultId = null;
    await _persist();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_favKey, _favorites);
    await prefs.setStringList(_recentKey, _recent);
    if (_defaultId == null) await prefs.remove(_defaultKey);
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _prefsKey, jsonEncode(_custom.map((e) => e.toJson()).toList()));
  }
}
