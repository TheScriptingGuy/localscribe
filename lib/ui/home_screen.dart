import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note_template.dart';
import '../services/ai/ai_factory.dart';
import '../services/ai/ai_types.dart';
import '../services/notes/note_generator.dart';
import '../services/templates/prompt_builder.dart';
import '../services/templates/template_repository.dart';
import '../settings/settings.dart';

/// Phase 1 home: browse templates and run a transcript -> note test end-to-end
/// against the configured note-AI URL. (Recording/BLE wiring lands in Phase 2+.)
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final templates = context.read<TemplateRepository>();
    return Scaffold(
      appBar: AppBar(title: const Text('LocalScribe')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.science_outlined),
              title: const Text('Transcript → Note (test)'),
              subtitle: const Text(
                  'Paste a transcript, pick a template, generate a note via your configured AI URL.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const GenerateNoteScreen())),
            ),
          ),
          const SizedBox(height: 16),
          Text('Templates', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          ...templates.all.map((t) => _TemplateTile(template: t)),
        ],
      ),
    );
  }
}

class _TemplateTile extends StatelessWidget {
  final NoteTemplate template;
  const _TemplateTile({required this.template});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        title: Text(template.name),
        subtitle: Text(template.description,
            maxLines: 2, overflow: TextOverflow.ellipsis),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Chip(
                    label: Text(template.verbatim
                        ? 'recovered verbatim'
                        : template.custom
                            ? 'custom'
                            : 'reconstructed'),
                    visualDensity: VisualDensity.compact,
                  ),
                ]),
                const SizedBox(height: 8),
                const Text('Outline (synthesized into the prompt):',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                ...template.outline.map((o) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('• $o'),
                    )),
                if (template.source.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(template.source,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
        ],
      ),
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
      final NoteGenerator gen = AiFactory.noteGenerator(settings.noteAi);
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
