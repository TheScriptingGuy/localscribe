import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/ai_config.dart';
import '../services/models/model_manager.dart';
import '../services/models/speaker_models.dart';
import '../services/models/whisper_models.dart';
import '../settings/settings.dart';
import 'models_screen.dart';
import 'theme.dart';

/// Spoken-language choices for transcription ('auto' = detect).
const _languages = {
  'auto': 'Detect automatically',
  'en': 'English',
  'nl': 'Dutch',
  'de': 'German',
  'fr': 'French',
  'es': 'Spanish',
  'it': 'Italian',
  'pt': 'Portuguese',
  'pl': 'Polish',
  'sv': 'Swedish',
  'da': 'Danish',
  'no': 'Norwegian',
  'fi': 'Finnish',
  'tr': 'Turkish',
  'ru': 'Russian',
  'uk': 'Ukrainian',
  'zh': 'Chinese',
  'ja': 'Japanese',
  'ko': 'Korean',
  'ar': 'Arabic',
  'hi': 'Hindi',
};

/// Configure both AI pipelines: on-device model OR a custom API URL.
class OptionsScreen extends StatefulWidget {
  const OptionsScreen({super.key});

  @override
  State<OptionsScreen> createState() => _OptionsScreenState();
}

class _OptionsScreenState extends State<OptionsScreen> {
  @override
  Widget build(BuildContext context) {
    final settings = context.watch<Settings>();
    final t = settings.transcription;
    final n = settings.noteAi;
    final sp = settings.speakers;

    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        children: [
          const PageHeader('Options',
              subtitle: 'Where transcription and notes run',
              padding: EdgeInsets.fromLTRB(0, 8, 0, 24)),
          _sectionTitle(context, 'Transcription AI'),
          _modeToggle(
            onDevice: t.onDevice,
            onChanged: (v) {
              t.onDevice = v;
              settings.save();
            },
            onDeviceLabel: 'On-device (whisper.cpp)',
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue:
                _languages.containsKey(t.language) ? t.language : 'auto',
            decoration: const InputDecoration(
                labelText: 'Spoken language', border: OutlineInputBorder()),
            items: _languages.entries
                .map((e) =>
                    DropdownMenuItem(value: e.key, child: Text(e.value)))
                .toList(),
            onChanged: (v) {
              if (v == null) return;
              t.language = v;
              settings.save();
            },
          ),
          if (!t.onDevice) ...[
            _field('API base URL', t.remote.baseUrl,
                hint: 'https://api.openai.com/v1',
                onChanged: (v) => t.remote.baseUrl = v),
            _field('API key', t.remote.apiKey,
                obscure: true, onChanged: (v) => t.remote.apiKey = v),
            _field('Model', t.remote.model,
                hint: 'whisper-1', onChanged: (v) => t.remote.model = v),
            const _Hint(
                'OpenAI-compatible /audio/transcriptions. Works with OpenAI, '
                'Groq, or a self-hosted whisper.cpp HTTP server.'),
          ] else
            _localModelTile(context, t),
          const Divider(height: 40),
          _sectionTitle(context, 'Speaker recognition'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Recognise speakers'),
            subtitle: const Text(
                'Label who is talking (Speaker 1, Speaker 2, …) after '
                'transcribing. Works for any language.'),
            value: sp.enabled,
            onChanged: (v) {
              sp.enabled = v;
              settings.save();
            },
          ),
          if (sp.enabled) ...[
            _modeToggle(
              onDevice: sp.onDevice,
              onChanged: (v) {
                sp.onDevice = v;
                settings.save();
              },
              onDeviceLabel: 'On-device (sherpa-onnx)',
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: sp.numSpeakers <= 8 ? sp.numSpeakers : 0,
              decoration:
                  const InputDecoration(labelText: 'Number of speakers'),
              items: [
                const DropdownMenuItem(
                    value: 0, child: Text('Detect automatically')),
                for (var i = 2; i <= 8; i++)
                  DropdownMenuItem(value: i, child: Text('$i speakers')),
              ],
              onChanged: (v) {
                if (v == null) return;
                sp.numSpeakers = v;
                settings.save();
              },
            ),
            if (sp.onDevice)
              _speakerModelsTile(context)
            else ...[
              _field('Speaker API URL', sp.remote.baseUrl,
                  hint: 'http://192.168.1.20:8090',
                  onChanged: (v) => sp.remote.baseUrl = v),
              _field('API key', sp.remote.apiKey,
                  obscure: true, onChanged: (v) => sp.remote.apiKey = v),
              const _Hint(
                  'A server you host that answers POST /diarize with who '
                  'spoke when. A ready-made one (same models, or pyannote on '
                  'a GPU) is in the LocalScribe repository under '
                  'server/diarization.'),
            ],
          ],
          const Divider(height: 40),
          _sectionTitle(context, 'Note AI  &  Ask-AI chat'),
          _modeToggle(
            onDevice: n.onDevice,
            onChanged: (v) {
              n.onDevice = v;
              settings.save();
            },
            onDeviceLabel: 'On-device (llama.cpp / GGUF) — Phase 4',
          ),
          if (!n.onDevice) ...[
            DropdownButtonFormField<ChatApiFlavor>(
              initialValue: n.remote.flavor,
              decoration: const InputDecoration(
                  labelText: 'Provider', border: OutlineInputBorder()),
              items: ChatApiFlavor.values
                  .map((f) =>
                      DropdownMenuItem(value: f, child: Text(f.label)))
                  .toList(),
              onChanged: (v) {
                if (v == null) return;
                setState(() => n.remote.flavor = v);
                settings.save();
              },
            ),
            const SizedBox(height: 12),
            _field('API base URL', n.remote.baseUrl,
                hint: n.remote.flavor == ChatApiFlavor.anthropic
                    ? 'https://api.anthropic.com'
                    : 'https://api.openai.com/v1',
                onChanged: (v) => n.remote.baseUrl = v),
            _field('API key', n.remote.apiKey,
                obscure: true, onChanged: (v) => n.remote.apiKey = v),
            _field('Model', n.remote.model,
                hint: n.remote.flavor == ChatApiFlavor.anthropic
                    ? 'claude-sonnet-4-5'
                    : 'gpt-4o-mini',
                onChanged: (v) => n.remote.model = v),
            const _Hint(
                'OpenAI-compatible also covers Ollama, LM Studio, llama.cpp '
                'server, vLLM, OpenRouter, Groq — just change the base URL.'),
          ] else
            const _Hint('Downloadable GGUF models arrive in Phase 4.'),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: () async {
              await settings.save();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Settings saved')));
              }
            },
            icon: const Icon(Icons.save),
            label: const Text('Save settings'),
          ),
        ],
      ),
    );
  }

  Widget _localModelTile(BuildContext context, TranscriptionConfig t) {
    final models = context.watch<WhisperModelManager>();
    final selected = whisperModelByFile(t.localModel);
    final model =
        selected != null && models.isInstalled(selected) ? selected : null;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: ListTile(
        leading: Icon(model != null ? Icons.memory : Icons.download_outlined),
        title: Text(model != null
            ? 'Model: ${model.label}'
            : 'No model selected'),
        subtitle: Text(model != null
            ? '${model.sizeLabel} · audio stays on this phone'
            : 'Download a model and tap it to use it offline'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => const ModelsScreen())),
      ),
    );
  }

  Widget _speakerModelsTile(BuildContext context) {
    final m = context.watch<SpeakerModelManager>();
    final error = m.ready || m.downloading ? null : m.error;
    final String status;
    final Widget trailing;
    if (m.ready) {
      status = '${formatBytes(m.totalBytes)} · audio stays on this phone';
      trailing = IconButton(
        tooltip: 'Delete',
        icon: const Icon(Icons.delete_outline),
        onPressed: m.deleteAll,
      );
    } else if (m.downloading) {
      status = 'Downloading ${(m.progress * 100).floor()}%';
      trailing = IconButton(
        tooltip: 'Stop',
        icon: const Icon(Icons.close),
        onPressed: m.cancelAll,
      );
    } else {
      status = error ??
          '${formatBytes(m.totalBytes)} · download once, then works offline';
      trailing = IconButton(
        tooltip: 'Download',
        icon: const Icon(Icons.download),
        onPressed: m.downloadAll,
      );
    }
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(
                m.ready ? Icons.record_voice_over : Icons.download_outlined),
            title: Text(m.ready ? 'Speaker models ready' : 'Speaker models'),
            subtitle: Text(
              status,
              style: error != null
                  ? TextStyle(color: Theme.of(context).colorScheme.error)
                  : null,
            ),
            trailing: trailing,
          ),
          if (m.downloading)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: LinearProgressIndicator(value: m.progress),
            ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(s, style: Theme.of(context).textTheme.titleLarge),
      );

  Widget _modeToggle({
    required bool onDevice,
    required ValueChanged<bool> onChanged,
    required String onDeviceLabel,
  }) =>
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(onDevice ? onDeviceLabel : 'Custom API URL'),
        subtitle: Text(onDevice
            ? 'Run the model locally on the phone'
            : 'Send to the API endpoint you configure'),
        value: onDevice,
        onChanged: onChanged,
      );

  Widget _field(String label, String initial,
      {String? hint,
      bool obscure = false,
      required ValueChanged<String> onChanged}) {
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: TextFormField(
        initialValue: initial,
        obscureText: obscure,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        onChanged: onChanged,
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.outline)),
      );
}
