import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInput;
import 'package:flutter_reactive_ble/flutter_reactive_ble.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/recording.dart';
import '../services/ble/plaud_container.dart';
import '../services/ble/plaud_credentials.dart';
import '../services/ble/plaud_crypto.dart';
import '../services/ble/plaud_import.dart';
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
      // Tell the autofill service the sign-in worked so it offers to save.
      TextInput.finishAutofillContext(shouldSave: true);
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Signed in — paired ${devs.length} Plaud device(s)')));
    } catch (e) {
      // Don't let the password manager save credentials that just failed.
      TextInput.finishAutofillContext(shouldSave: false);
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
        final head = bytes
            .take(16)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(' ');
        developer.log(
            'cloud file ${r.id}: ${bytes.length} B, '
            'type=${resp.headers.value('content-type')}, head=$head',
            name: 'PlaudSync');

        var durationMs = r.durationMs;
        var markers = const <RecordingMarker>[];
        File f;
        final container = PlaudContainer(bytes);
        if (container.looksValid) {
          // Private Cloud Sync stores the recorder's end-to-end encrypted
          // PLAUD.AI container as-is; unmask it with the account's RSA key,
          // exactly like a BLE download.
          final pem = cred.rsaPrivateKeyPem;
          if (pem == null || pem.isEmpty) {
            throw StateError(
                'Recording ${r.id} is end-to-end encrypted, but no Plaud key '
                'is loaded. Sign in again to fetch it.');
          }
          final audio = container.decode(PlaudCrypto.privateKeyFromPem(pem));
          if (audio.packets.isEmpty) {
            throw StateError(
                'Could not decrypt recording ${r.id} with the loaded Plaud key.');
          }
          durationMs = audio.durationMs;
          markers = recorderMarkers(audio.markMs);
          f = File(p.join(tmp.path, 'plaud_${r.id}.opus'));
          await f.writeAsBytes(PlaudContainer.oggOpusOf(audio.packets),
              flush: true);
        } else if (_isRawPlaudOpus(bytes)) {
          // The cloud usually serves the recorder's audio already decrypted
          // but still as bare 80-byte Opus units (no container). Wrap them in
          // Ogg so the player and transcriber can read them.
          final packets = <Uint8List>[];
          final marks = <int>[];
          for (var off = 0;
              off + PlaudContainer.unitSize <= bytes.length;
              off += PlaudContainer.unitSize) {
            final pkt = Uint8List.fromList(
                bytes.sublist(off, off + PlaudContainer.unitSize));
            if (pkt[0] == PlaudContainer.markToc) {
              marks.add(packets.length * PlaudContainer.unitMs);
              pkt[0] = _plaudToc;
            }
            packets.add(pkt);
          }
          durationMs = packets.length * PlaudContainer.unitMs;
          markers = recorderMarkers(marks);
          f = File(p.join(tmp.path, 'plaud_${r.id}.opus'));
          await f.writeAsBytes(PlaudContainer.oggOpusOf(packets), flush: true);
        } else {
          f = File(p.join(tmp.path, 'plaud_${r.id}${_audioExt(bytes)}'));
          await f.writeAsBytes(bytes, flush: true);
        }
        // The file list carries the duration (ms); fall back to probing the
        // file if the server didn't report one.
        if (durationMs <= 0) {
          final probe = AudioPlayer();
          try {
            durationMs = (await probe.setFilePath(f.path))?.inMilliseconds ?? 0;
          } catch (_) {
            // Unknown to the player; still transcribable.
          } finally {
            await probe.dispose();
          }
        }
        await store.add(
          f,
          title: r.filename.isEmpty ? r.id : r.filename,
          source: RecordingSource.plaud,
          durationMs: durationMs,
          markers: markers,
          createdAt: r.startTimeMs > 0
              ? DateTime.fromMillisecondsSinceEpoch(r.startTimeMs)
              : null,
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

  /// Opus TOC of every Plaud recorder packet (CELT WB, mono, 20 ms).
  static const int _plaudToc = 0xb8;

  /// Bare Plaud Opus stream: a whole number of 80-byte units, each starting
  /// with the recorder's TOC (or the highlight-mark TOC). Checks every unit,
  /// so a random file can't pass by chance.
  static bool _isRawPlaudOpus(Uint8List b) {
    const n = PlaudContainer.unitSize;
    if (b.isEmpty || b.length % n != 0) return false;
    for (var off = 0; off < b.length; off += n) {
      final toc = b[off];
      if (toc != _plaudToc && toc != PlaudContainer.markToc) return false;
    }
    return true;
  }

  /// Pick a file extension from the audio's magic bytes. `is_opus=1` returns
  /// Ogg Opus, not MP3, and a wrong extension trips up decoders.
  static String _audioExt(Uint8List b) {
    bool at(int o, List<int> sig) {
      if (b.length < o + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (b[o + i] != sig[i]) return false;
      }
      return true;
    }

    if (at(0, const [0x4F, 0x67, 0x67, 0x53])) return '.ogg'; // OggS
    if (at(0, const [0x52, 0x49, 0x46, 0x46])) return '.wav'; // RIFF
    if (at(4, const [0x66, 0x74, 0x79, 0x70])) return '.m4a'; // ftyp
    return '.mp3';
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
          Text(
            'Sign in to Plaud to pair every recorder on your account.',
            style: TextStyle(color: context.colors.muted, height: 1.4),
          ),
          const SizedBox(height: 8),
          Text(
            'Your password is sealed with the Plaud server key before it leaves '
            'this device, and only your escrowed e2ee key + device signatures '
            'are stored here. Nothing is sent to LocalScribe.',
            style: TextStyle(
                color: context.colors.faint, height: 1.4, fontSize: 13),
          ),
          const SizedBox(height: 20),
          // Grouping the two fields lets password managers (Bitwarden,
          // 1Password, Google, Samsung Pass, …) fill both at once and offer to
          // save the credentials after a successful sign-in.
          AutofillGroup(
            child: Column(
              children: [
                TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autocorrect: false,
                  autofillHints: const [
                    AutofillHints.username,
                    AutofillHints.email,
                  ],
                  decoration: const InputDecoration(
                      labelText: 'Plaud account email',
                      border: OutlineInputBorder()),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _passwordCtrl,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _busy ? null : _signIn(),
                  decoration: const InputDecoration(
                      labelText: 'Password', border: OutlineInputBorder()),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _signIn,
            icon: const Icon(Icons.cloud_done_outlined),
            label: Text(_busy ? 'Signing in…' : 'Sign in & pair devices'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: context.colors.danger)),
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
                style: TextStyle(color: context.colors.muted),
              ),
            ),
          if (cred.devices.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text('No devices on this account.',
                  style: TextStyle(color: context.colors.muted)),
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
            Text(_error!, style: TextStyle(color: context.colors.danger)),
          ],
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () async {
              await context.read<PlaudCredentials>().clear();
              if (mounted) setState(() {});
            },
            icon: Icon(Icons.logout, color: context.colors.danger),
            label: Text('Sign out of Plaud',
                style: TextStyle(color: context.colors.danger)),
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
                backgroundColor: context.colors.fill,
                foregroundColor: context.colors.text,
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
                      style: TextStyle(color: context.colors.muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              paired
                  ? _badge('Paired', null, null)
                  : _badge('No key', context.colors.danger, Colors.white),
              if (nearby) ...[
                const SizedBox(width: 6),
                _badge('Nearby', context.colors.text, context.colors.inverse),
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

  Widget _badge(String label, Color? bg, Color? fg) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: bg ?? context.colors.fill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: fg ?? context.colors.text,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
}
