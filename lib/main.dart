import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/audio/recording_service.dart';
import 'services/ble/plaud_credentials.dart';
import 'services/library/recording_store.dart';
import 'services/models/llm_models.dart';
import 'services/models/speaker_models.dart';
import 'services/models/whisper_models.dart';
import 'services/notes/note_jobs.dart';
import 'services/templates/template_repository.dart';
import 'services/transcription/transcription_jobs.dart';
import 'settings/settings.dart';
import 'ui/plaud_devices_screen.dart';
import 'ui/record_screen.dart';
import 'ui/recordings_screen.dart';
import 'ui/templates_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Release builds can't write Dart errors to logcat, so persist any unhandled
  // Flutter error to app-private external storage (readable via adb).
  FlutterError.onError = (details) {
    _persistError('${details.exceptionAsString()}\n${details.stack ?? ''}');
    FlutterError.presentError(details);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    _persistError('$error\n$stack');
    return false;
  };

  RecordingService.init();

  final settings = Settings();
  await settings.load();

  final templates = TemplateRepository();
  await templates.load();

  final recordings = RecordingStore();
  await recordings.load();

  final models = WhisperModelManager();
  await models.load();

  final speakerModels = SpeakerModelManager();
  await speakerModels.load();

  final llmModels = LlmModelManager();
  await llmModels.load();

  final plaudCredentials = PlaudCredentials();
  await plaudCredentials.load();

  runApp(LocalScribeApp(
    settings: settings,
    templates: templates,
    recordings: recordings,
    models: models,
    speakerModels: speakerModels,
    llmModels: llmModels,
    plaudCredentials: plaudCredentials,
    jobs: TranscriptionJobs(
      store: recordings,
      settings: settings,
      models: models,
      speakerModels: speakerModels,
    ),
    noteJobs: NoteJobs(
      store: recordings,
      settings: settings,
      templates: templates,
      llmModels: llmModels,
    ),
  ));
}

void _persistError(String s) {
  try {
    File('/sdcard/Android/data/ai.localscribe.localscribe/files/plaud_error.txt')
        .writeAsStringSync(s, flush: true);
  } catch (_) {/* best-effort only */}
}

class LocalScribeApp extends StatelessWidget {
  final Settings settings;
  final TemplateRepository templates;
  final RecordingStore recordings;
  final WhisperModelManager models;
  final SpeakerModelManager speakerModels;
  final LlmModelManager llmModels;
  final PlaudCredentials plaudCredentials;
  final TranscriptionJobs jobs;
  final NoteJobs noteJobs;

  const LocalScribeApp({
    super.key,
    required this.settings,
    required this.templates,
    required this.recordings,
    required this.models,
    required this.speakerModels,
    required this.llmModels,
    required this.plaudCredentials,
    required this.jobs,
    required this.noteJobs,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        Provider.value(value: templates),
        ChangeNotifierProvider.value(value: recordings),
        ChangeNotifierProvider.value(value: models),
        ChangeNotifierProvider.value(value: speakerModels),
        ChangeNotifierProvider.value(value: llmModels),
        ChangeNotifierProvider.value(value: plaudCredentials),
        ChangeNotifierProvider.value(value: jobs),
        ChangeNotifierProvider.value(value: noteJobs),
      ],
      child: MaterialApp(
        title: 'LocalScribe',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        themeMode: ThemeMode.light,
        home: const RootShell(),
      ),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const _pages = [RecordingsScreen(), TemplatesScreen()];

  Future<void> _newRecording() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SheetAction(
                icon: Icons.mic_none,
                title: 'Record',
                subtitle: 'Capture with the phone microphone',
                onTap: () => Navigator.pop(ctx, 'record'),
              ),
              _SheetAction(
                icon: Icons.upload_file_outlined,
                title: 'Import audio',
                subtitle: 'MP3, M4A, WAV and other audio files',
                onTap: () => Navigator.pop(ctx, 'import'),
              ),
              _SheetAction(
                icon: Icons.bluetooth_outlined,
                title: 'Plaud devices',
                subtitle: 'Pair and sync recordings from your Plaud recorders',
                onTap: () => Navigator.pop(ctx, 'plaud'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'record':
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const RecordScreen()));
      case 'import':
        await importAudio(context);
      case 'plaud':
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const PlaudDevicesScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: _NewButton(onPressed: _newRecording),
      bottomNavigationBar: BottomAppBar(
        color: Palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 64,
        padding: EdgeInsets.zero,
        child: Row(
          children: [
            Expanded(
              child: IconButton(
                tooltip: 'Library',
                iconSize: 30,
                icon: Icon(_index == 0 ? Icons.folder : Icons.folder_outlined),
                onPressed: () => setState(() => _index = 0),
              ),
            ),
            const SizedBox(width: 96),
            Expanded(
              child: IconButton(
                tooltip: 'Templates',
                iconSize: 30,
                icon: Icon(_index == 1 ? Icons.widgets : Icons.widgets_outlined),
                onPressed: () => setState(() => _index = 1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The round black "+" that sits on the bottom bar's edge.
class _NewButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _NewButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'New recording',
      child: Material(
        color: Palette.text,
        shape: const CircleBorder(
            side: BorderSide(color: Palette.surface, width: 5)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: const SizedBox(
            width: 72,
            height: 72,
            child: Icon(Icons.add, color: Colors.white, size: 34),
          ),
        ),
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _SheetAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: Palette.fill,
        foregroundColor: Palette.text,
        child: Icon(icon),
      ),
      title: Text(title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      onTap: onTap,
    );
  }
}
