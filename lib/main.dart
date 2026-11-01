import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'services/templates/template_repository.dart';
import 'settings/settings.dart';
import 'ui/home_screen.dart';
import 'ui/options_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = Settings();
  await settings.load();

  final templates = TemplateRepository();
  await templates.load();

  runApp(LocalScribeApp(settings: settings, templates: templates));
}

class LocalScribeApp extends StatelessWidget {
  final Settings settings;
  final TemplateRepository templates;

  const LocalScribeApp({
    super.key,
    required this.settings,
    required this.templates,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        Provider.value(value: templates),
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

  static const _pages = [HomeScreen(), OptionsScreen()];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _pages[_index],
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.library_books_outlined),
              selectedIcon: Icon(Icons.library_books),
              label: 'Notes'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Options'),
        ],
      ),
    );
  }
}
