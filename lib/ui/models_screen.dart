import 'package:flutter/material.dart';
import 'package:localscribe_native/localscribe_native.dart';
import 'package:provider/provider.dart';

import '../services/models/whisper_models.dart';
import '../settings/settings.dart';

/// Download, select and delete on-device whisper models.
class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final models = context.watch<WhisperModelManager>();
    final settings = context.watch<Settings>();
    final selected = settings.transcription.localModel;
    final unsupported = LocalScribeNative.unsupportedReason;

    return Scaffold(
      appBar: AppBar(title: const Text('Transcription models')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          if (unsupported != null)
            MaterialBanner(
              content: Text(unsupported),
              backgroundColor: Theme.of(context).colorScheme.errorContainer,
              actions: const [SizedBox.shrink()],
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Text(
              'Models are downloaded once from the whisper.cpp project on '
              'Hugging Face, checked against their SHA-256 and stored in app '
              'storage. Transcription then runs fully offline.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          for (final m in whisperModels)
            _ModelTile(
              model: m,
              selected: m.file == selected,
              onSelect: () {
                settings.transcription.localModel = m.file;
                settings.save();
              },
              onDownloaded: () {
                // First usable model: select it so transcription just works.
                final current = whisperModelByFile(selected);
                if (current == null || !models.isInstalled(current)) {
                  settings.transcription.localModel = m.file;
                  settings.save();
                }
              },
            ),
        ],
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  final WhisperModel model;
  final bool selected;
  final VoidCallback onSelect;
  final VoidCallback onDownloaded;

  const _ModelTile({
    required this.model,
    required this.selected,
    required this.onSelect,
    required this.onDownloaded,
  });

  @override
  Widget build(BuildContext context) {
    final models = context.watch<WhisperModelManager>();
    final installed = models.isInstalled(model);
    final dl = models.downloadOf(model);
    final error = dl?.error;
    final active = error == null ? dl : null;

    final Widget trailing;
    if (installed) {
      trailing = IconButton(
        tooltip: 'Delete',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _confirmDelete(context, models),
      );
    } else if (active != null) {
      trailing = IconButton(
        tooltip: 'Stop',
        icon: const Icon(Icons.close),
        onPressed: active.verifying ? null : () => models.cancel(model),
      );
    } else {
      trailing = IconButton(
        tooltip: 'Download',
        icon: const Icon(Icons.download),
        onPressed: () async {
          await models.download(model);
          if (models.isInstalled(model)) onDownloaded();
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

  Future<void> _confirmDelete(
      BuildContext context, WhisperModelManager models) async {
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
    if (ok == true) await models.delete(model);
  }
}
