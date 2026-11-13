import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/recording.dart';
import '../services/ble/plaud_container.dart';
import '../services/ble/plaud_credentials.dart';
import '../services/ble/plaud_crypto.dart';
import '../services/ble/plaud_device.dart';
import '../services/library/recording_store.dart';
import 'plaud_devices_screen.dart';
import 'theme.dart';

/// Import recordings straight from the user's Plaud recorder over BLE — no
/// Plaud app, no Plaud servers. Optionally target a specific [serial]; when
/// omitted the first paired device is used.
class PlaudImportScreen extends StatefulWidget {
  final String? serial;
  const PlaudImportScreen({super.key, this.serial});

  @override
  State<PlaudImportScreen> createState() => _PlaudImportScreenState();
}

class _PlaudImportScreenState extends State<PlaudImportScreen> {
  final _session = PlaudDeviceSession();
  bool _running = false;
  int _saved = 0;

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  Future<bool> _ensurePermissions() async {
    final res = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    // On Android 12+ the bluetooth* perms matter; on older, location does.
    return res[Permission.bluetoothScan]?.isGranted != false &&
        res[Permission.bluetoothConnect]?.isGranted != false &&
        (res[Permission.locationWhenInUse]?.isGranted ??
            true); // granted or not-applicable
  }

  Future<void> _sync(PlaudCredentials cred, PlaudDeviceCred dev) async {
    if (!await _ensurePermissions()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Bluetooth/Location permission is required')));
      return;
    }
    setState(() {
      _running = true;
      _saved = 0;
    });
    await _session.sync(cred, dev);
    if (!mounted) return;
    // Persist whatever came down.
    final store = context.read<RecordingStore>();
    final tmp = await getTemporaryDirectory();
    final pem = cred.rsaPrivateKeyPem;
    final priv = (pem == null || pem.isEmpty)
        ? null
        : PlaudCrypto.privateKeyFromPem(pem);
    for (final d in _session.downloads) {
      final stem = 'plaud_${d.fileId.toRadixString(16)}';
      // The container is Opus masked with a ChaCha20 keystream; unmask it and
      // wrap the packets in Ogg so the normal decode → transcribe path works.
      File f;
      try {
        if (priv == null) throw StateError('no RSA key loaded');
        f = File(p.join(tmp.path, '$stem.opus'));
        await f.writeAsBytes(
            PlaudContainer(d.bytes).toOggOpus(priv), flush: true);
      } catch (e) {
        // Keep the raw container rather than losing the recording.
        debugPrint('plaud: container decode failed for $stem: $e');
        f = File(p.join(tmp.path, '$stem.plaud'));
        await f.writeAsBytes(d.bytes, flush: true);
      }
      await store.add(
        f,
        title: 'Plaud Note ${d.fileId.toRadixString(16)}',
        source: RecordingSource.plaud,
        move: true,
      );
      _saved++;
    }
    if (!mounted) return;
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final cred = context.watch<PlaudCredentials>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plaud device'),
        actions: [
          IconButton(
            icon: const Icon(Icons.devices_outlined),
            tooltip: 'Devices',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const PlaudDevicesScreen())),
          ),
        ],
      ),
      body: !cred.isConfigured
          ? _needsCredentials(context)
          : _syncBody(context, cred),
    );
  }

  Widget _needsCredentials(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.cloud_off_outlined,
                size: 48, color: context.colors.muted),
            const SizedBox(height: 16),
            Text(
              'Sign in to Plaud first to connect to your recorder.',
              textAlign: TextAlign.center,
              style: TextStyle(color: context.colors.muted),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PlaudDevicesScreen())),
              child: const Text('Sign in to Plaud'),
            ),
          ]),
        ),
      );

  Widget _syncBody(BuildContext context, PlaudCredentials cred) {
    final dev = (widget.serial != null
            ? cred.deviceBySerial(widget.serial!)
            : null) ??
        (cred.devices.isNotEmpty ? cred.devices.first : null);
    if (dev == null) {
      return Center(
          child: Text('No paired device.',
              style: TextStyle(color: context.colors.muted)));
    }
    return AnimatedBuilder(
      animation: _session,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.memory),
              title: Text(dev.name),
              subtitle: Text('serial ${dev.serial}'),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _running ? null : () => _sync(cred, dev),
              icon: const Icon(Icons.bluetooth_searching),
              label: Text(_running ? 'Syncing…' : 'Connect & sync'),
            ),
            const SizedBox(height: 16),
            Row(children: [
              Text(_statusLabel(_session.status),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Expanded(child: Text(_session.message,
                  style: TextStyle(color: context.colors.muted))),
            ]),
            if (_session.status == PlaudStatus.syncing && _session.progress > 0)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: LinearProgressIndicator(value: _session.progress),
              ),
            if (_saved > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Saved $_saved recording(s) to the library.'),
              ),
            const SizedBox(height: 16),
            const Text('Log', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: context.colors.fill,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                _session.log.isEmpty ? '—' : _session.log.join('\n'),
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 11, height: 1.4),
              ),
            ),
          ],
        );
      },
    );
  }

  String _statusLabel(PlaudStatus s) => switch (s) {
        PlaudStatus.idle => 'Ready',
        PlaudStatus.scanning => 'Scanning',
        PlaudStatus.connecting => 'Connecting',
        PlaudStatus.handshaking => 'Handshake',
        PlaudStatus.syncing => 'Syncing',
        PlaudStatus.done => 'Done',
        PlaudStatus.error => 'Error',
      };
}
