import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ble/plaud_credentials.dart';
import 'theme.dart';

/// Import the user's own Plaud credentials (RSA key + device public keys) once,
/// from a JSON file placed on the phone. Everything stays in app-private
/// storage; nothing is bundled in the app or sent anywhere.
///
/// Expected JSON:
/// {
///   "userId": "…",
///   "rsaPrivateKeyPem": "-----BEGIN PRIVATE KEY-----\n…",
///   "devices": [ {"serial":"…","name":"Plaud Note","publicKeyHex":"3ad4…"} ]
/// }
class PlaudCredentialsScreen extends StatefulWidget {
  const PlaudCredentialsScreen({super.key});

  @override
  State<PlaudCredentialsScreen> createState() => _PlaudCredentialsScreenState();
}

class _PlaudCredentialsScreenState extends State<PlaudCredentialsScreen> {
  String? _error;
  bool _busy = false;

  Future<void> _importFile() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
      if (res == null) {
        setState(() => _busy = false);
        return;
      }
      final bytes = res.files.single.bytes ??
          await File(res.files.single.path!).readAsBytes();
      final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final cred = context.read<PlaudCredentials>();
      await cred.setIdentity(
        userId: (j['userId'] ?? '').toString(),
        pem: (j['rsaPrivateKeyPem'] ?? '').toString(),
      );
      for (final d in ((j['devices'] as List?) ?? const [])) {
        final m = Map<String, dynamic>.from(d);
        await cred.upsertDevice(PlaudDeviceCred(
          serial: (m['serial'] ?? '').toString(),
          name: (m['name'] ?? 'Plaud Note').toString(),
          publicKey: _unhex((m['publicKeyHex'] ?? '').toString()),
        ));
      }
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Credentials imported')));
    } catch (e) {
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cred = context.watch<PlaudCredentials>();
    return Scaffold(
      appBar: AppBar(title: const Text('Plaud credentials')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Connect to your own Plaud recorder without the Plaud app. Import a '
            'credentials file (your RSA key + device key) exported from your '
            'phone. It is stored only on this device.',
            style: TextStyle(color: Palette.muted, height: 1.4),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _importFile,
            icon: const Icon(Icons.file_open_outlined),
            label: Text(_busy ? 'Importing…' : 'Import credentials file (.json)'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Palette.danger)),
          ],
          const SizedBox(height: 24),
          const Text('Status', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          _row('Identity', cred.userId == null ? 'not set' : cred.userId!),
          _row('RSA key',
              (cred.rsaPrivateKeyPem?.isNotEmpty ?? false) ? 'imported' : 'missing'),
          const SizedBox(height: 8),
          if (cred.devices.isEmpty)
            const Text('No devices', style: TextStyle(color: Palette.muted))
          else
            ...cred.devices.map((d) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.memory),
                  title: Text(d.name),
                  subtitle: Text('serial ${d.serial} · key ${d.publicKey.length}B'),
                )),
          if (cred.isConfigured) ...[
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () => cred.clear(),
              icon: const Icon(Icons.delete_outline, color: Palette.danger),
              label: const Text('Remove credentials',
                  style: TextStyle(color: Palette.danger)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          SizedBox(width: 90, child: Text(k, style: const TextStyle(color: Palette.muted))),
          Expanded(child: Text(v)),
        ]),
      );
}

Uint8List _unhex(String s) {
  final clean = s.replaceAll(RegExp(r'\s'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}
