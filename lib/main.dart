import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/audio/recording_service.dart';
import 'services/library/recording_store.dart';
import 'services/models/whisper_models.dart';
import 'services/templates/template_repository.dart';
import 'services/transcription/transcription_jobs.dart';
import 'settings/settings.dart';
import 'ui/options_screen.dart';
import 'ui/recordings_screen.dart';
import 'ui/templates_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  RecordingService.init();

  final settings = Settings();
  await settings.load();

  final templates = TemplateRepository();
  await templates.load();

  final recordings = RecordingStore();
  await recordings.load();

  final models = WhisperModelManager();
  await models.load();

  runApp(LocalScribeApp(
    settings: settings,
    templates: templates,
    recordings: recordings,
    models: models,
    jobs: TranscriptionJobs(
        store: recordings, settings: settings, models: models),
  ));
}

class LocalScribeApp extends StatelessWidget {
  final Settings settings;
  final TemplateRepository templates;
  final RecordingStore recordings;
  final WhisperModelManager models;
  final TranscriptionJobs jobs;

  const LocalScribeApp({
    super.key,
    required this.settings,
    required this.templates,
    required this.recordings,
    required this.models,
    required this.jobs,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        Provider.value(value: templates),
        ChangeNotifierProvider.value(value: recordings),
        ChangeNotifierProvider.value(value: models),
        ChangeNotifierProvider.value(value: jobs),
      ],
      child: MaterialApp(
        title: 'LocalScribe',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF2E7D32),
          useMaterial3: true,
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: const Color(0xFF2E7D32),
          useMaterial3: true,
          brightness: Brightness.dark,
        ),
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

  static const _pages = [RecordingsScreen(), TemplatesScreen(), OptionsScreen()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.graphic_eq_outlined),
              selectedIcon: Icon(Icons.graphic_eq),
              label: 'Recordings'),
          NavigationDestination(
              icon: Icon(Icons.library_books_outlined),
              selectedIcon: Icon(Icons.library_books),
              label: 'Templates'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Options'),
        ],
      ),
    );
  }
}
