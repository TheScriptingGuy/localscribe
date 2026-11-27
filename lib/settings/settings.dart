import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai_config.dart';

/// App-wide settings, persisted to shared_preferences. Notifies listeners so
/// the Options screen and services stay in sync.
class Settings extends ChangeNotifier {
  static const _key = 'settings_v1';

  TranscriptionConfig transcription;
  NoteAiConfig noteAi;
  SpeakerConfig speakers;

  /// Default output language for notes ('auto' = follow transcript).
  String noteLanguage;

  /// Light, dark or follow the system.
  ThemeMode themeMode;

  /// Show rolling captions while recording (on-device transcription only).
  bool liveCaptions;

  Settings({
    TranscriptionConfig? transcription,
    NoteAiConfig? noteAi,
    SpeakerConfig? speakers,
    this.noteLanguage = 'auto',
    this.themeMode = ThemeMode.system,
    this.liveCaptions = true,
  })  : transcription = transcription ?? TranscriptionConfig(),
        noteAi = noteAi ?? NoteAiConfig(),
        speakers = speakers ?? SpeakerConfig();

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['transcription'] != null) {
        transcription = TranscriptionConfig.fromJson(
            Map<String, dynamic>.from(j['transcription']));
      }
      if (j['noteAi'] != null) {
        noteAi = NoteAiConfig.fromJson(Map<String, dynamic>.from(j['noteAi']));
      }
      if (j['speakers'] != null) {
        speakers =
            SpeakerConfig.fromJson(Map<String, dynamic>.from(j['speakers']));
      }
      noteLanguage = j['noteLanguage'] ?? 'auto';
      liveCaptions = j['liveCaptions'] ?? true;
      themeMode = ThemeMode.values.firstWhere(
          (m) => m.name == j['themeMode'],
          orElse: () => ThemeMode.system);
    } catch (_) {
      // Ignore corrupt settings.
    }
    notifyListeners();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        'transcription': transcription.toJson(),
        'noteAi': noteAi.toJson(),
        'speakers': speakers.toJson(),
        'noteLanguage': noteLanguage,
        'themeMode': themeMode.name,
        'liveCaptions': liveCaptions,
      }),
    );
    notifyListeners();
  }
}
