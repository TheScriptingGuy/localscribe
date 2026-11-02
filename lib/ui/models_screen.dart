import 'package:flutter/material.dart';
import 'package:localscribe_llm/localscribe_llm.dart';
import 'package:localscribe_native/localscribe_native.dart';
import 'package:provider/provider.dart';

import '../services/models/llm_models.dart';
import '../services/models/model_manager.dart';
import '../services/models/whisper_models.dart';
import '../settings/settings.dart';

/// Download, select and delete on-device models: whisper models for
/// transcription, or GGUF chat models for notes and Ask-AI.
class ModelsScreen extends StatelessWidget {
  final String title;
  final String intro;
  final ModelManager manager;
  final String? unsupported;
  final String Function(Settings) selectedOf;
  final void Function(Settings, String file) select;

  const ModelsScreen({
    super.key,
    required this.title,
    required this.intro,
    required this.manager,
    required this.unsupported,
    required this.selectedOf,
    required this.select,
  });

  static Widget whisper(BuildContext context) => ModelsScreen(
        title: 'Transcription models',
        intro: 'Models are downloaded once from the whisper.cpp project on '
            'Hugging Face, checked against their SHA-256 and stored in app '
            'storage. Transcription then runs fully offline.',
        manager: context.read<WhisperModelManager>(),
        unsupported: LocalScribeNative.unsupportedReason,
        selectedOf: (s) => s.transcription.localModel,
        select: (s, f) => s.transcription.localModel = f,
      );

  static Widget llm(BuildContext context) => ModelsScreen(
        title: 'AI note models',
        intro: 'Chat models (GGUF) are downloaded once from their publishers '
            'on Hugging Face, checked against their SHA-256 and stored in app '
            'storage. Notes and Ask-AI then run fully offline. Bigger models '
            'write better notes but are slower and need more memory; on a '
            'long recording a note can take several minutes.',
        manager: context.read<LlmModelManager>(),
        unsupported: LocalLlm.unsupportedReason,
        selectedOf: (s) => s.noteAi.localModel,
        select: (s, f) => s.noteAi.localModel = f,
      );

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    return ListenableBuilder(
      listenable: manager,
      builder: (context, _) {
        final selected = selectedOf(settings);
        return Scaffold(
          appBar: AppBar(title: Text(title)),
          body: ListView(
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              if (unsupported != null)
                MaterialBanner(
                  content: Text(unsupported!),
                  backgroundColor: Theme.of(context).colorScheme.errorContainer,
                  actions: const [SizedBox.shrink()],
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(intro, style: Theme.of(context).textTheme.bodySmall),
              ),
              for (final m in manager.catalog)
                _ModelTile(
                  model: m,
                  manager: manager,
                  selected: m.file == selected,
                  onSelect: () {
                    select(settings, m.file);
                    settings.save();
                  },
                  onDownloaded: () {
                    // First usable model: select it so it just works.
                    final current = manager.byFile(selected);
                    if (current == null || !manager.isInstalled(current)) {
                      select(settings, m.file);
                      settings.save();
                    }
                  },
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ModelTile extends StatelessWidget {
  final DownloadableModel model;
  final ModelManager manager;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onDownloaded;

  const _ModelTile({
    required this.model,
    required this.manager,
    required this.selected,
    required this.onSelect,
    required this.onDownloaded,
  });

  @override
  Widget build(BuildContext context) {
    final installed = manager.isInstalled(model);
    final dl = manager.downloadOf(model);
    final error = dl?.error;
    final active = error == null ? dl : null;

    final Widget trailing;
    if (installed) {
      trailing = IconButton(
        tooltip: 'Delete',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _confirmDelete(context),
      );
    } else if (active != null) {
      trailing = IconButton(
        tooltip: 'Stop',
        icon: const Icon(Icons.close),
        onPressed: active.verifying ? null : () => manager.cancel(model),
      );
    } else {
      trailing = IconButton(
        tooltip: 'Download',
        icon: const Icon(Icons.download),
        onPressed: () async {
          await manager.download(model);
          if (manager.isInstalled(model)) onDownloaded();
        },
      );
    }

    final String status;
    if (active != null) {
      status = active.verifying
          ? 'Verifying…'
          : 'Downloading ${(active.progress * 100).toStringAsFixed(0)}%';
    } else if (error != null) {
      status = error;
    } else {
      status = '${model.sizeLabel} · ${model.note}';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          leading: Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            color: installed
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).disabledColor,
          ),
          title: Text(model.label),
          subtitle: Text(
            status,
            style: error != null
                ? TextStyle(color: Theme.of(context).colorScheme.error)
                : null,
          ),
          trailing: trailing,
          onTap: installed ? onSelect : null,
        ),
        if (active != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
                value: active.verifying ? null : active.progress),
          ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${model.label}?'),
        content: Text('Frees ${model.sizeLabel}. You can download it again.'),
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
    if (ok == true) await manager.delete(model);
  }
}
