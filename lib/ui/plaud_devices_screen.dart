import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/recording.dart';
import '../services/ble/plaud_credentials.dart';
import '../services/library/recording_store.dart';
import '../services/plaud/plaud_cloud_api.dart';
import 'plaud_import_screen.dart';
import 'theme.dart';

/// Plaud account + devices. Sign in once with email/password and every recorder
/// bound to the account is paired (its SN signature + the shared e2ee key are
/// fetched and stored). The list shows which devices are paired (key material
/// present) and which are physically nearby (advertising over BLE).
class PlaudDevicesScreen extends StatefulWidget {
  const PlaudDevicesScreen({super.key});

  @override
  State<PlaudDevicesScreen> createState() => _PlaudDevicesScreenState();
}

class _PlaudDevicesScreenState extends State<PlaudDevicesScreen> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _ble = FlutterReactiveBle();
  StreamSubscription<DiscoveredDevice>? _scanSub;

  bool _busy = false;
  bool _scanning = false;
  String? _error;
  final Set<String> _nearbyIds = {};
  final Set<String> _nearbySerials = {};

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _scanSub?.cancel();
    super.dispose();
  }

  Future<bool> _ensurePermissions() async {
    final res = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
    return res[Permission.bluetoothScan]?.isGranted != false &&
        res[Permission.bluetoothConnect]?.isGranted != false &&
        (res[Permission.locationWhenInUse]?.isGranted ?? true);
  }

  Future<void> _signIn() async {
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Email and password are required.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final acc = await PlaudCloudApi().loadAccount(email, password);
      if (!mounted) return;
      final pem = acc.privateKeyPem;
      if (pem == null || pem.isEmpty) {
        throw StateError(
            'No e2ee key returned by Plaud (account has no escrowed key yet?).');
      }
      final cred = context.read<PlaudCredentials>();
      await cred.setIdentity(
          userId: acc.userId ?? '', pem: pem, token: acc.accessToken);
      final devs = <PlaudDeviceCred>[];
      for (final d in acc.devices) {
        devs.add(PlaudDeviceCred(
          serial: d.sn,
          name: d.name.isEmpty ? d.modelLabel : d.name,
          publicKey: acc.deviceKeys[d.sn] ?? Uint8List(256),
        ));
      }
      await cred.replaceDevices(devs);
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Signed in — paired ${devs.length} Plaud device(s)')));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<void> _scanNearby() async {
    if (_scanning) return;
    final ok = await _ensurePermissions();
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Bluetooth/Location permission is required')));
      }
      return;
    }
    setState(() {
      _scanning = true;
      _nearbyIds.clear();
      _nearbySerials.clear();
    });
    _scanSub = _ble
        .scanForDevices(
          withServices: const [],
          scanMode: ScanMode.lowLatency,
        )
        .listen((d) {
      var changed = false;
      if (d.name.startsWith('PLAUD') && _nearbyIds.add(d.id)) {
        changed = true;
      }
      final serial = _serialIn(d.manufacturerData);
      if (serial != null && _nearbySerials.add(serial)) {
        changed = true;
      }
      if (changed && mounted) setState(() {});
    }, onError: (_) {});
    await Future<void>.delayed(const Duration(seconds: 8));
    await _scanSub?.cancel();
    _scanSub = null;
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _syncCloud() async {
    final cred = context.read<PlaudCredentials>();
    final token = cred.accessToken;
    if (token == null || token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sign in to Plaud first.')));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = PlaudCloudApi();
      final recs = await api.listRecordings(token);
      // Newest first (start at the most recent recording).
      recs.sort((a, b) => b.startTimeMs.compareTo(a.startTimeMs));
      if (!mounted) return;
      final store = context.read<RecordingStore>();
      final tmp = await getTemporaryDirectory();
      final dio = Dio();
      var saved = 0;
      for (final r in recs) {
        final url = await api.getTempUrl(token, r.id);
        final resp = await dio.get<List<int>>(url,
            options: Options(responseType: ResponseType.bytes));
        final bytes = Uint8List.fromList(resp.data!);
        final f = File(p.join(tmp.path, 'plaud_${r.id}.mp3'));
        await f.writeAsBytes(bytes, flush: true);
        await store.add(
          f,
          title: r.filename.isEmpty ? r.id : r.filename,
          source: RecordingSource.plaud,
          move: true,
        );
        saved++;
      }
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Synced $saved recording(s) from Plaud cloud')));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  /// Pull a device serial out of the manufacturer data. It's 9 raw binary
  /// bytes at a fixed offset (bytes 11-19), not ASCII text — hex-encode them
  /// directly. See `PlaudDevice._serialIn` for the live capture that proved
  /// this offset.
  String? _serialIn(Uint8List data) {
    if (data.length < 20) return null;
    final sb = StringBuffer();
    for (var i = 11; i < 20; i++) {
      sb.write(data[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString().toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final cred = context.watch<PlaudCredentials>();
    return Scaffold(
      appBar: AppBar(title: const Text('Plaud devices')),
      body: cred.userId == null ? _signInBody() : _devicesBody(cred),
    );
  }

  Widget _signInBody() => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Sign in to Plaud to pair every recorder on your account.',
            style: TextStyle(color: Palette.muted, height: 1.4),
          ),
          const SizedBox(height: 8),
          const Text(
            'Your password is sealed with the Plaud server key before it leaves '
            'this device, and only your escrowed e2ee key + device signatures '
            'are stored here. Nothing is sent to LocalScribe.',
            style: TextStyle(color: Palette.faint, height: 1.4, fontSize: 13),
          ),
          const SizedBox(height: 20),
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
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _signIn,
            icon: const Icon(Icons.cloud_done_outlined),
            label: Text(_busy ? 'Signing in…' : 'Sign in & pair devices'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Palette.danger)),
          ],
        ],
      );

  Widget _devicesBody(PlaudCredentials cred) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${cred.devices.length} device(s) on your account',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton.icon(
                onPressed: _scanning ? null : _scanNearby,
                icon: Icon(_scanning ? Icons.bluetooth_searching : Icons.radar),
                label: Text(_scanning ? 'Scanning…' : 'Scan nearby'),
              ),
            ],
          ),
          if (_scanning || _nearbyIds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _scanning
                    ? 'Looking for nearby recorders…'
                    : 'Nearby: ${_nearbyIds.length} recorder(s) advertising',
                style: const TextStyle(color: Palette.muted),
              ),
            ),
          if (cred.devices.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text('No devices on this account.',
                  style: TextStyle(color: Palette.muted)),
            )
          else
            ...cred.devices.map((d) => _deviceCard(d)),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _busy ? null : _syncCloud,
            icon: const Icon(Icons.cloud_download_outlined),
            label: Text(_busy ? 'Syncing…' : 'Sync recordings from Plaud cloud'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Palette.danger)),
          ],
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              await context.read<PlaudCredentials>().clear();
              if (mounted) setState(() {});
            },
            icon: const Icon(Icons.logout, color: Palette.danger),
            label: const Text('Sign out of Plaud',
                style: TextStyle(color: Palette.danger)),
          ),
        ],
      );

  Widget _deviceCard(PlaudDeviceCred d) {
    final paired = d.publicKey.length == 256 && d.publicKey.any((b) => b != 0);
    final nearby = _nearbySerials.contains(d.serial);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: paired
            ? () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => PlaudImportScreen(serial: d.serial)))
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: Palette.fill,
                foregroundColor: Palette.text,
                child: const Icon(Icons.headphones_outlined),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(d.name,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      '${_modelLabel(d.serial)} · ${d.serial}',
                      style: const TextStyle(color: Palette.muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              _badge(paired ? 'Paired' : 'No key', paired ? null : Palette.danger),
              if (nearby) ...[
                const SizedBox(width: 6),
                _badge('Nearby', Palette.text),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _modelLabel(String serial) {
    switch (serial.length >= 3 ? serial.substring(0, 3) : '') {
      case '881':
        return 'Note Pro';
      case '882':
        return 'NotePin S';
      case '880':
        return 'NotePin';
      case '860':
        return 'Plaud One';
      default:
        return 'Plaud Note';
    }
  }

  Widget _badge(String label, Color? color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: color ?? Palette.fill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color == null ? Palette.text : Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}
