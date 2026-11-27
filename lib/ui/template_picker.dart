import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/note_template.dart';
import '../services/notes/note_jobs.dart';
import '../services/templates/template_repository.dart';
import 'template_style.dart';
import 'theme.dart';

/// Bottom sheet to choose the template for a new note. Returns a template id,
/// or [NoteJobs.autoTemplate] for "Auto", or null when dismissed.
Future<String?> pickTemplate(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _PickerSheet(),
  );
}

class _PickerSheet extends StatefulWidget {
  const _PickerSheet();

  @override
  State<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends State<_PickerSheet> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<TemplateRepository>();
    final c = context.colors;
    final query = _ctrl.text.trim();
    final height = math.max(
        280.0,
        MediaQuery.sizeOf(context).height * 0.85 -
            MediaQuery.viewInsetsOf(context).bottom);

    final children = <Widget>[];
    if (query.isEmpty) {
      final def = repo.defaultTemplate;
      children.add(ListTile(
        leading: const Icon(Icons.auto_awesome),
        title: Text(def == null ? 'Auto' : 'Default: ${def.name}'),
        subtitle: Text(def == null
            ? 'Let the AI pick the best template'
            : 'Set for next use. Change it in the Templates tab.'),
        onTap: () => Navigator.pop(context, NoteJobs.autoTemplate),
      ));
      final recent = repo.recent;
      if (recent.isNotEmpty) {
        children.add(_header('Recently used', c));
        children.addAll(recent.map(_tile));
      }
      final favorites = repo.favorites;
      if (favorites.isNotEmpty) {
        children.add(_header('Favourites', c));
        children.addAll(favorites.map(_tile));
      }
      for (final cat in templateCategoryIds) {
        final items = repo.all.where((t) => t.category == cat).toList();
        if (items.isEmpty) continue;
        children.add(_header(categoryStyle(cat).label, c));
        children.addAll(items.map(_tile));
      }
    } else {
      final results = repo.search(query);
      if (results.isEmpty) {
        children.add(Padding(
          padding: const EdgeInsets.all(24),
          child: Text('No templates match "$query"',
              style: TextStyle(color: c.muted)),
        ));
      } else {
        children.addAll(results.map(_tile));
      }
    }

    return SizedBox(
      height: height,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: TextField(
              controller: _ctrl,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search templates',
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
          Expanded(child: ListView(children: children)),
        ],
      ),
    );
  }

  Widget _header(String label, AppColors c) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 4),
        child: Text(label.toUpperCase(),
            style: TextStyle(
                color: c.muted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.8)),
      );

  Widget _tile(NoteTemplate t) => ListTile(
        leading: Icon(templateIcon(t.icon), color: categoryStyle(t.category).color),
        title: Text(t.name),
        subtitle:
            Text(t.description, maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => Navigator.pop(context, t.id),
      );
}
