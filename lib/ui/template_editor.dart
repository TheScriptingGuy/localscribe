import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note_template.dart';
import '../services/ai/ai_factory.dart';
import '../services/ai/ai_types.dart';
import '../services/models/llm_models.dart';
import '../services/templates/template_drafter.dart';
import '../services/templates/template_repository.dart';
import '../settings/settings.dart';
import 'template_style.dart';
import 'theme.dart';

/// "Create template": describe it to the AI, or write it yourself.
Future<void> startCreateTemplate(BuildContext context) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.auto_awesome),
              title: const Text('Describe it'),
              subtitle: const Text(
                  'Say what you need and the AI drafts the template'),
              onTap: () => Navigator.pop(ctx, 'ai'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Write it yourself'),
              subtitle: const Text('Start from an empty template'),
              onTap: () => Navigator.pop(ctx, 'manual'),
            ),
          ],
        ),
      ),
    ),
  );
  if (choice == null || !context.mounted) return;
  final page = choice == 'ai'
      ? const TemplateAiScreen()
      : const TemplateEditorScreen();
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
}

/// Asks for a description, then opens the editor with the AI's draft.
class TemplateAiScreen extends StatefulWidget {
  const TemplateAiScreen({super.key});

  @override
  State<TemplateAiScreen> createState() => _TemplateAiScreenState();
}

class _TemplateAiScreenState extends State<TemplateAiScreen> {
  final _text = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_text.text.trim().isEmpty) return;
    final settings = context.read<Settings>();
    final llm = context.read<LlmModelManager>();
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final gen = AiFactory.noteGenerator(settings.noteAi, models: llm);
      final draft = await TemplateDrafter.draft(
        generator: gen,
        description: _text.text,
        iconNames: templateIconNames,
      );
      if (!mounted) return;
      navigator.pushReplacement(MaterialPageRoute(
          builder: (_) => TemplateEditorScreen(initial: draft, draft: true)));
    } on AiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: [
          const PageHeader('Describe your template',
              subtitle: 'What should the notes look like?',
              padding: EdgeInsets.fromLTRB(0, 8, 0, 24)),
          TextField(
            controller: _text,
            minLines: 4,
            maxLines: 8,
            autofocus: true,
            decoration: const InputDecoration(
              hintText:
                  'e.g. Notes for my weekly club committee call: decisions, who does what by when, and open questions.',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _generate,
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome),
            label: Text(_busy ? 'Drafting…' : 'Draft template'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: context.colors.danger)),
          ],
          const SizedBox(height: 16),
          Text(
            'Uses the note AI from Options. You can review and edit the draft before saving.',
            style: TextStyle(color: context.colors.muted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// Create or edit a custom template.
class TemplateEditorScreen extends StatefulWidget {
  /// Null for a blank new template.
  final NoteTemplate? initial;

  /// True when [initial] is an unsaved AI draft.
  final bool draft;
  const TemplateEditorScreen({super.key, this.initial, this.draft = false});

  @override
  State<TemplateEditorScreen> createState() => _TemplateEditorScreenState();
}

class _TemplateEditorScreenState extends State<TemplateEditorScreen> {
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final TextEditingController _outline;
  late final TextEditingController _sections;
  late final TextEditingController _tags;
  late String _category;
  late String _icon;
  String? _error;

  @override
  void initState() {
    super.initState();
    final t = widget.initial;
    _name = TextEditingController(text: t?.name ?? '');
    _description = TextEditingController(text: t?.description ?? '');
    _outline = TextEditingController(text: (t?.outline ?? const []).join('\n'));
    _sections =
        TextEditingController(text: (t?.sections ?? const []).join('\n'));
    _tags = TextEditingController(text: (t?.tags ?? const []).join(', '));
    _category = t?.category ?? 'general';
    _icon = t?.icon ?? 'description';
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _outline.dispose();
    _sections.dispose();
    _tags.dispose();
    super.dispose();
  }

  List<String> _lines(String s) =>
      s.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  Future<void> _save() async {
    final name = _name.text.trim();
    final outline = _lines(_outline.text);
    if (name.isEmpty) {
      setState(() => _error = 'Give the template a name.');
      return;
    }
    if (outline.isEmpty) {
      setState(() => _error = 'Add at least one instruction.');
      return;
    }
    final repo = context.read<TemplateRepository>();
    final navigator = Navigator.of(context);
    final old = widget.initial;
    final t = NoteTemplate(
      id: old?.id ?? 'custom_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      description: _description.text.trim(),
      outline: outline,
      sections: _lines(_sections.text),
      tags: _tags.text
          .split(',')
          .map((e) => e.trim().toLowerCase())
          .where((e) => e.isNotEmpty)
          .toList(),
      category: _category,
      icon: _icon,
      example: old?.example ?? '',
      source: old?.source.isNotEmpty == true
          ? old!.source
          : 'Created in LocalScribe.',
      custom: true,
    );
    await repo.saveCustom(t);
    navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isNew = widget.initial == null || widget.draft;
    return Scaffold(
      appBar: AppBar(
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 10)),
              child: const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 48),
        children: [
          PageHeader(isNew ? 'New template' : 'Edit template',
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 20)),
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
                labelText: 'Short description',
                hintText: 'What does the note contain?'),
          ),
          const SizedBox(height: 20),
          Text('Category', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final id in templateCategoryIds)
                ChoiceChip(
                  label: Text(categoryStyle(id).label),
                  avatar: Icon(categoryStyle(id).icon,
                      size: 18, color: categoryStyle(id).color),
                  selected: _category == id,
                  onSelected: (_) => setState(() => _category = id),
                  showCheckmark: false,
                ),
            ],
          ),
          const SizedBox(height: 20),
          Text('Icon', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final name in templateIconNames)
                InkResponse(
                  onTap: () => setState(() => _icon = name),
                  radius: 24,
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: _icon == name ? c.text : c.fill,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(templateIcon(name),
                        size: 22,
                        color: _icon == name ? c.inverse : c.text),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _outline,
            minLines: 5,
            maxLines: 14,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Instructions (one per line)',
              alignLabelWithHint: true,
              hintText:
                  'List the key decisions.\nPut tasks in a table with owner and deadline.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _sections,
            minLines: 2,
            maxLines: 8,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Section headings (one per line)',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
                labelText: 'Search tags',
                hintText: 'comma, separated, words'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: c.danger)),
          ],
        ],
      ),
    );
  }
}
