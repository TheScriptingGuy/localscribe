import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note_template.dart';
import '../services/templates/template_repository.dart';
import 'markdown_view.dart';
import 'template_editor.dart';
import 'template_style.dart';
import 'theme.dart';

/// A template as a tappable card: coloured icon, name, description, category.
class TemplateCard extends StatelessWidget {
  final NoteTemplate template;
  final double? width;
  const TemplateCard({super.key, required this.template, this.width});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final repo = context.watch<TemplateRepository>();
    final style = categoryStyle(template.category);
    final card = Material(
      color: c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: c.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showTemplateDetail(context, template),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(templateIcon(template.icon), color: style.color, size: 26),
                  const Spacer(),
                  if (repo.isDefault(template.id))
                    Icon(Icons.check_circle, size: 18, color: c.text)
                  else if (repo.isFavorite(template.id))
                    Icon(Icons.star, size: 18, color: c.muted),
                ],
              ),
              const SizedBox(height: 10),
              Text(template.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, height: 1.2)),
              const SizedBox(height: 4),
              Expanded(
                child: Text(template.description,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style:
                        TextStyle(color: c.muted, fontSize: 13, height: 1.3)),
              ),
              Text(template.custom ? 'Yours' : style.label,
                  style: TextStyle(color: c.faint, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
    return width == null ? card : SizedBox(width: width, child: card);
  }
}

/// Horizontal strip of cards (or other tiles), edge-to-edge scrolling.
class TemplateCarousel extends StatelessWidget {
  final List<Widget> children;
  const TemplateCarousel({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 190,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        itemCount: children.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) => children[i],
      ),
    );
  }
}

/// Two-column grid of [TemplateCard]s.
class TemplateGrid extends StatelessWidget {
  final List<NoteTemplate> templates;
  final EdgeInsets padding;
  const TemplateGrid({
    super.key,
    required this.templates,
    this.padding = const EdgeInsets.fromLTRB(24, 8, 24, 120),
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: padding,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        mainAxisExtent: 190,
      ),
      itemCount: templates.length,
      itemBuilder: (_, i) => TemplateCard(template: templates[i]),
    );
  }
}

/// Section title with an optional "see all" chevron.
class SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback? onTap;
  const SectionHeader(this.title, {super.key, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
        child: Row(
          children: [
            Text(title, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w300)),
            if (onTap != null) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, color: context.colors.muted),
            ],
          ],
        ),
      ),
    );
  }
}

/// Template details with favourite, "Set for next use" and (for your own
/// templates) edit and delete.
Future<void> showTemplateDetail(BuildContext context, NoteTemplate template) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _TemplateDetail(templateId: template.id, fallback: template),
  );
}

class _TemplateDetail extends StatelessWidget {
  final String templateId;
  final NoteTemplate fallback;
  const _TemplateDetail({required this.templateId, required this.fallback});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TemplateRepository>();
    final c = context.colors;
    final t = repo.byId(templateId) ?? fallback;
    final style = categoryStyle(t.category);
    final isDefault = repo.isDefault(t.id);
    final maxHeight = math.max(
        240.0,
        MediaQuery.sizeOf(context).height * 0.85 -
            MediaQuery.viewInsetsOf(context).bottom);

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(templateIcon(t.icon), color: style.color, size: 30),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(t.name,
                              style: Theme.of(context).textTheme.headlineSmall),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('${style.label}${t.custom ? ' · Yours' : ''}',
                        style: TextStyle(color: c.muted)),
                    if (t.description.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      Text('Description',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 6),
                      Text(t.description,
                          style: TextStyle(color: c.muted, height: 1.4)),
                    ],
                    const SizedBox(height: 20),
                    Text('Preview',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: c.fill,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: t.example.isNotEmpty
                          ? MarkdownView(t.example, compact: true)
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                for (final line in t.outline)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Text('• $line',
                                        style: const TextStyle(height: 1.35)),
                                  ),
                              ],
                            ),
                    ),
                    if (t.sections.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final s in t.sections) Chip(label: Text(s)),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Row(
                children: [
                  IconButton.outlined(
                    tooltip: repo.isFavorite(t.id)
                        ? 'Remove from favourites'
                        : 'Add to favourites',
                    onPressed: () => repo.toggleFavorite(t.id),
                    icon: Icon(
                        repo.isFavorite(t.id) ? Icons.star : Icons.star_outline),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        final messenger = ScaffoldMessenger.of(context);
                        repo.setDefault(isDefault ? null : t.id);
                        Navigator.pop(context);
                        messenger.showSnackBar(SnackBar(
                            content: Text(isDefault
                                ? 'Back to Auto template'
                                : '"${t.name}" will be used for your next notes')));
                      },
                      child: Text(isDefault ? 'Use Auto again' : 'Set for next use'),
                    ),
                  ),
                ],
              ),
            ),
            if (t.custom)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    TextButton.icon(
                      onPressed: () {
                        final navigator = Navigator.of(context);
                        navigator.pop();
                        navigator.push(MaterialPageRoute(
                            builder: (_) => TemplateEditorScreen(initial: t)));
                      },
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit'),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        final navigator = Navigator.of(context);
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: Text('Delete "${t.name}"?'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Cancel')),
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Delete')),
                            ],
                          ),
                        );
                        if (ok != true) return;
                        await repo.deleteCustom(t.id);
                        navigator.pop();
                      },
                      icon: Icon(Icons.delete_outline, color: c.danger),
                      label: Text('Delete', style: TextStyle(color: c.danger)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
