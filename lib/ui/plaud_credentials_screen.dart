import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../services/ble/plaud_credentials.dart';
import '../services/ble/plaud_crypto.dart';
import '../services/plaud/plaud_cloud_api.dart';
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

  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _serialCtrl = TextEditingController();

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _serialCtrl.dispose();
    super.dispose();
  }

  Future<void> _importFile() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final picked = await FilePicker.pickFile(type: FileType.any);
      final path = picked?.path;
      if (path == null) {
        setState(() => _busy = false);
        return;
      }
      final bytes = await File(path).readAsBytes();
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

  Future<void> _generateKeypair() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final keys = PlaudCrypto.generateKeyPair();
      final cred = context.read<PlaudCredentials>();
      // Mint a fresh identity key but keep the account user id + paired device
      // keys. The recorder will wrap session/at-rest keys to this new public key.
      await cred.setIdentity(
        userId: cred.userId ?? '',
        pem: keys.privatePem,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('New keypair generated — it will be enrolled on the '
              'next BLE connect.')));
    } catch (e) {
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<void> _signInToPlaud() async {
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    final serial = _serialCtrl.text.trim();
    if (email.isEmpty || password.isEmpty || serial.isEmpty) {
      setState(() => _error = 'Email, password and device serial are required.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final keys = await PlaudCloudApi().loadExistingKey(email, password, serial);
      final pem = keys.privateKeyPem;
      if (pem == null || pem.isEmpty) {
        throw StateError(
            'No private key returned by the Plaud API (response shape changed?). '
            'Check the device serial and try again.');
      }
      final cred = context.read<PlaudCredentials>();
      await cred.setIdentity(userId: keys.userId ?? '', pem: pem);
      if (keys.devicePublicKey != null) {
        await cred.upsertDevice(PlaudDeviceCred(
          serial: serial,
          name: 'Plaud Note',
          publicKey: keys.devicePublicKey!,
        ));
      }
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Plaud key loaded — connect the recorder to use it.')));
    } catch (e) {
      var msg = '$e';
      if (e is DioException) {
        msg = '${e.requestOptions.method} ${e.requestOptions.uri}\n'
            'HTTP ${e.response?.statusCode} (${e.type.name})\n'
            'sent: ${e.requestOptions.data}\n'
            'response: ${e.response?.data}';
      }
      // Persist to external files so the error can be read via adb even though
      // release builds can't write to logcat.
      try {
        final dir = await getExternalFilesDir(null);
        if (dir != null) {
          await File('${dir.path}/plaud_error.txt').writeAsString(msg);
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = msg;
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
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _generateKeypair,
            icon: const Icon(Icons.key_outlined),
            label: Text(_busy ? 'Generating…' : 'Generate new keypair'),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          const Text('Or sign in to Plaud and load your existing key',
              style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          const Text(
            'Fetches your escrowed e2ee key from the Plaud cloud so you can '
            'decrypt existing recordings without re-enrolling. Credentials are '
            'used once and never stored.',
            style: TextStyle(color: Palette.muted, height: 1.4),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            decoration: const InputDecoration(
                labelText: 'Plaud account email', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _passwordCtrl,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
                labelText: 'Password', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _serialCtrl,
            autocorrect: false,
            decoration: const InputDecoration(
                labelText: 'Recorder serial', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _signInToPlaud,
            icon: const Icon(Icons.cloud_download_outlined),
            label: Text(_busy ? 'Signing in…' : 'Sign in & load key'),
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
