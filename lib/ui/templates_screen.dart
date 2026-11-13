import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note_template.dart';
import '../services/ai/ai_factory.dart';
import '../services/ai/ai_types.dart';
import '../services/models/llm_models.dart';
import '../services/notes/note_generator.dart';
import '../services/templates/prompt_builder.dart';
import '../services/templates/template_repository.dart';
import '../settings/settings.dart';
import 'recordings_screen.dart';
import 'template_editor.dart';
import 'template_style.dart';
import 'template_widgets.dart';
import 'theme.dart';

/// Templates tab: "My space" (recent, favourites, your own) and "Discover"
/// (every category), with search and template creation.
class TemplatesScreen extends StatelessWidget {
  const TemplatesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          actions: [
            IconButton(
              tooltip: 'Search templates',
              icon: const Icon(Icons.search),
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const TemplateSearchScreen())),
            ),
            const SizedBox(width: 4),
            FilledButton.icon(
              onPressed: () => startCreateTemplate(context),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Create'),
              style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10)),
            ),
            const SizedBox(width: 12),
            const OptionsButton(),
          ],
        ),
        body: Column(
          children: [
            const PageHeader('Templates',
                padding: EdgeInsets.fromLTRB(24, 16, 24, 8)),
            const Align(
              alignment: Alignment.centerLeft,
              child: TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                padding: EdgeInsets.symmetric(horizontal: 14),
                tabs: [Tab(text: 'My space'), Tab(text: 'Discover')],
              ),
            ),
            const Expanded(
              child: TabBarView(children: [_MySpaceTab(), _DiscoverTab()]),
            ),
          ],
        ),
      ),
    );
  }
}

class _MySpaceTab extends StatelessWidget {
  const _MySpaceTab();

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TemplateRepository>();
    final recent = repo.recent;
    final favorites = repo.favorites;
    final mine = repo.custom;
    final defaultT = repo.defaultTemplate;

    return ListView(
      padding: const EdgeInsets.only(bottom: 120),
      children: [
        if (defaultT != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Row(
              children: [
                const Icon(Icons.check_circle, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Next notes use "${defaultT.name}"',
                      style: TextStyle(color: context.colors.muted)),
                ),
                TextButton(
                  onPressed: () => repo.setDefault(null),
                  child: const Text('Use Auto'),
                ),
              ],
            ),
          ),
        if (recent.isNotEmpty) ...[
          const SectionHeader('Recently used'),
          TemplateCarousel(children: [
            for (final t in recent) TemplateCard(template: t, width: 200),
          ]),
        ],
        if (favorites.isNotEmpty) ...[
          const SectionHeader('Favourites'),
          TemplateCarousel(children: [
            for (final t in favorites) TemplateCard(template: t, width: 200),
          ]),
        ],
        const SectionHeader('My templates'),
        TemplateCarousel(children: [
          _CreateCard(onTap: () => startCreateTemplate(context)),
          for (final t in mine) TemplateCard(template: t, width: 200),
        ]),
        if (recent.isEmpty && favorites.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
            child: Text(
              'Templates you use or star show up here. Browse Discover to find one.',
              style: TextStyle(color: context.colors.muted),
            ),
          ),
        const SizedBox(height: 24),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Card(
            child: ListTile(
              leading: const Icon(Icons.science_outlined),
              title: const Text('Try a template on pasted text'),
              subtitle: const Text(
                  'Paste a transcript, pick a template and see the note it produces.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const GenerateNoteScreen())),
            ),
          ),
        ),
      ],
    );
  }
}

/// Dashed "Create template" tile at the start of My templates.
class _CreateCard extends StatelessWidget {
  final VoidCallback onTap;
  const _CreateCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: 200,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: CustomPaint(
          painter: _DashedBorderPainter(color: c.faint),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit_outlined, size: 28, color: c.text),
                const SizedBox(height: 10),
                const Text('Create template',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DashedBorderPainter extends CustomPainter {
  final Color color;
  const _DashedBorderPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, const Radius.circular(16)));
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 7), paint);
        d += 12;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) => old.color != color;
}

class _DiscoverTab extends StatelessWidget {
  const _DiscoverTab();

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TemplateRepository>();
    final byCategory = <String, List<NoteTemplate>>{
      for (final id in templateCategoryIds)
        id: repo.all.where((t) => t.category == id).toList(),
    }..removeWhere((_, list) => list.isEmpty);

    return ListView(
      padding: const EdgeInsets.only(bottom: 120),
      children: [
        const SectionHeader('Categories'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final e in byCategory.entries)
                _CategoryTile(id: e.key, count: e.value.length),
            ],
          ),
        ),
        for (final e in byCategory.entries) ...[
          SectionHeader(
            categoryStyle(e.key).label,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => TemplateCategoryScreen(category: e.key))),
          ),
          TemplateCarousel(children: [
            for (final t in e.value) TemplateCard(template: t, width: 200),
          ]),
        ],
      ],
    );
  }
}

class _CategoryTile extends StatelessWidget {
  final String id;
  final int count;
  const _CategoryTile({required this.id, required this.count});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = categoryStyle(id);
    final width = (MediaQuery.sizeOf(context).width - 48 - 12) / 2;
    return SizedBox(
      width: width,
      child: Material(
        color: c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: c.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => TemplateCategoryScreen(category: id))),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(style.icon, color: style.color, size: 26),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(style.label,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      Text('$count template${count == 1 ? '' : 's'}',
                          style: TextStyle(color: c.muted, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Every template in one category.
class TemplateCategoryScreen extends StatelessWidget {
  final String category;
  const TemplateCategoryScreen({super.key, required this.category});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TemplateRepository>();
    final items = repo.all.where((t) => t.category == category).toList();
    return Scaffold(
      appBar: AppBar(),
      body: Column(
        children: [
          PageHeader(categoryStyle(category).label,
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12)),
          Expanded(child: TemplateGrid(templates: items)),
        ],
      ),
    );
  }
}

/// Search box with live results as a grid of cards.
class TemplateSearchScreen extends StatefulWidget {
  const TemplateSearchScreen({super.key});

  @override
  State<TemplateSearchScreen> createState() => _TemplateSearchScreenState();
}

class _TemplateSearchScreenState extends State<TemplateSearchScreen> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TemplateRepository>();
    final query = _ctrl.text.trim();
    final results = query.isEmpty ? <NoteTemplate>[] : repo.search(query);
    return Scaffold(
      appBar: AppBar(
        centerTitle: false,
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: TextField(
            controller: _ctrl,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: 'Search (e.g. Meeting)',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(_ctrl.clear),
                    ),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
            ),
          ),
        ),
      ),
      body: query.isEmpty
          ? Center(
              child: Text('Search by name, topic or category',
                  style: TextStyle(color: context.colors.muted)))
          : results.isEmpty
              ? Center(
                  child: Text('No templates match "$query"',
                      style: TextStyle(color: context.colors.muted)))
              : TemplateGrid(templates: results),
    );
  }
}

class GenerateNoteScreen extends StatefulWidget {
  const GenerateNoteScreen({super.key});

  @override
  State<GenerateNoteScreen> createState() => _GenerateNoteScreenState();
}

class _GenerateNoteScreenState extends State<GenerateNoteScreen> {
  final _transcript = TextEditingController();
  NoteTemplate? _selected;
  bool _busy = false;
  String _result = '';
  String? _error;

  @override
  void dispose() {
    _transcript.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    final settings = context.read<Settings>();
    final template = _selected;
    if (template == null || _transcript.text.trim().isEmpty) return;

    setState(() {
      _busy = true;
      _result = '';
      _error = null;
    });

    try {
      final NoteGenerator gen = AiFactory.noteGenerator(settings.noteAi,
          models: context.read<LlmModelManager>());
      final messages = PromptBuilder.forNote(
        template: template,
        transcript: _transcript.text.trim(),
        languageHint: settings.noteLanguage,
      );
      final out = await gen.complete(messages);
      setState(() => _result = out);
    } on AiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final templates = context.read<TemplateRepository>();
    _selected ??= templates.all.isNotEmpty ? templates.all.first : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Transcript → Note')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<NoteTemplate>(
            initialValue: _selected,
            decoration: const InputDecoration(
                labelText: 'Template', border: OutlineInputBorder()),
            items: templates.all
                .map((t) =>
                    DropdownMenuItem(value: t, child: Text(t.name)))
                .toList(),
            onChanged: (v) => setState(() => _selected = v),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _transcript,
            minLines: 5,
            maxLines: 12,
            decoration: const InputDecoration(
              labelText: 'Transcript',
              hintText: 'Paste or type a transcript to summarize…',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _generate,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome),
            label: Text(_busy ? 'Generating…' : 'Generate note'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context)
                            .colorScheme
                            .onErrorContainer)),
              ),
            ),
          ],
          if (_result.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('Result', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(_result),
          ],
        ],
      ),
    );
  }
}
