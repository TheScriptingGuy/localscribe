import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../models/recording.dart';
import '../services/audio/recording_service.dart';
import '../services/ble/plaud_credentials.dart';
import '../services/ble/plaud_crypto.dart';
import '../services/ble/plaud_device.dart';
import '../services/ble/plaud_import.dart';
import '../services/library/recording_store.dart';
import 'format.dart';
import 'record_widgets.dart';
import 'recording_detail_screen.dart';
import 'theme.dart';

/// Records on the Plaud recorder, started and stopped from the phone like the
/// Plaud app does. The audio streams in over Bluetooth while it records;
/// highlights come from the Highlight button here or a short press of the
/// recorder's own button, and photos and notes can be added along the way.
class DeviceRecordScreen extends StatefulWidget {
  final PlaudDeviceCred device;
  const DeviceRecordScreen({super.key, required this.device});

  @override
  State<DeviceRecordScreen> createState() => _DeviceRecordScreenState();
}

class _DeviceRecordScreenState extends State<DeviceRecordScreen> {
  static const _workOwner = 'plaud-recording';

  final _session = PlaudDeviceSession();
  StreamSubscription<int>? _markSub;
  Timer? _ticker;

  bool _starting = false;
  bool _recording = false;
  bool _stopping = false;
  String? _error;

  /// Moments marked in this app; the recorder's own marks are read from the
  /// audio when the recording is saved.
  final _markers = <RecordingMarker>[];
  final _photos = <String, File>{};
  int _recorderMarks = 0;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    _ticker?.cancel();
    _markSub?.cancel();
    _session.dispose();
    RecordingService.stopWork(_workOwner).catchError((_) {});
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

  Future<void> _start() async {
    if (!await _ensurePermissions()) {
      setState(() => _error = 'Bluetooth permission is required.');
      return;
    }
    if (!mounted) return;
    final cred = context.read<PlaudCredentials>();
    setState(() {
      _starting = true;
      _error = null;
    });
    // Keep the Bluetooth link alive with the screen off.
    try {
      await RecordingService.startWork(_workOwner,
          'Recording on ${widget.device.name}', 'Tap to return to LocalScribe');
    } catch (_) {/* foreground-only then */}
    _markSub = _session.deviceMarks.listen(_onRecorderMark);
    final ok = await _session.startRecording(cred, widget.device);
    if (!mounted) return;
    if (!ok) {
      await RecordingService.stopWork(_workOwner).catchError((_) {});
      setState(() {
        _starting = false;
        _error = _session.message;
      });
      return;
    }
    _ticker = Timer.periodic(
        const Duration(milliseconds: 250), (_) => setState(() {}));
    setState(() {
      _starting = false;
      _recording = true;
    });
  }

  void _onRecorderMark(int atMs) {
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    setState(() => _recorderMarks++);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 2),
          content: Text('Highlight from the recorder at '
              '${formatDuration(Duration(milliseconds: atMs))}')));
  }

  RecordingMarker _newMarker(MarkerType type, {String? text}) =>
      RecordingMarker(
        id: const Uuid().v4(),
        atMs: _session.liveElapsed.inMilliseconds,
        type: type,
        text: text,
      );

  void _flag() {
    HapticFeedback.mediumImpact();
    setState(() => _markers.add(_newMarker(MarkerType.flag)));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(
              'Highlight marked at ${formatDuration(_session.liveElapsed)}')));
  }

  Future<void> _photo() async {
    final marker = _newMarker(MarkerType.photo);
    try {
      final shot = await ImagePicker().pickImage(
          source: ImageSource.camera, imageQuality: 85, maxWidth: 1920);
      if (shot == null || !mounted) return;
      setState(() {
        _markers.add(marker);
        _photos[marker.id] = File(shot.path);
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not take a photo: $e');
    }
  }

  Future<void> _note() async {
    final marker = _newMarker(MarkerType.note);
    final ctrl = TextEditingController();
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            24, 0, 24, 24 + MediaQuery.viewInsetsOf(ctx).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                'Add a note at ${formatDuration(Duration(milliseconds: marker.atMs))}',
                style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration:
                  const InputDecoration(hintText: 'Key point, idea or reminder'),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                child: const Text('Add note'),
              ),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (text == null || text.isEmpty || !mounted) return;
    setState(() => _markers.add(RecordingMarker(
        id: marker.id, atMs: marker.atMs, type: MarkerType.note, text: text)));
  }

  Future<void> _stop() async {
    if (_stopping) return;
    final store = context.read<RecordingStore>();
    final pem = context.read<PlaudCredentials>().rsaPrivateKeyPem;
    final navigator = Navigator.of(context);
    setState(() => _stopping = true);
    _ticker?.cancel();
    final result = await _session.stopRecording();
    await RecordingService.stopWork(_workOwner).catchError((_) {});
    if (!mounted) return;
    if (result == null) {
      setState(() {
        _stopping = false;
        _recording = false;
        _error = '${_session.message}\n\nThe recording stays on the recorder; '
            'sync it later from Plaud devices.';
      });
      return;
    }
    final priv = (pem == null || pem.isEmpty)
        ? null
        : PlaudCrypto.privateKeyFromPem(pem);
    final rec = await addPlaudRecording(store, priv, result,
        markers: _markers, photos: Map.of(_photos));
    navigator.pushReplacement(MaterialPageRoute(
        builder: (_) => RecordingDetailScreen(recordingId: rec.id)));
  }

  Future<void> _confirmLeave() async {
    final stop = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop recording?'),
        content: const Text(
            'The recorder is still recording. Stop it and save the recording here?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep recording')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Stop and save')),
        ],
      ),
    );
    if (stop == true) await _stop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final elapsed = _recording ? _session.liveElapsed : Duration.zero;
    final received = Duration(milliseconds: _session.liveReceivedMs);
    final marks = _markers.length + _recorderMarks;
    final busy = _starting || _stopping;

    return PopScope(
      canPop: !_recording && !busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _recording && !_stopping) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _stopping
                      ? 'Saving…'
                      : _recording
                          ? 'Recording'
                          : 'Record on ${widget.device.name}',
                  style: Theme.of(context).textTheme.displaySmall,
                ),
                const SizedBox(height: 8),
                Row(children: [
                  if (_recording && !_stopping) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                          color: c.danger, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      busy || _recording
                          ? _session.message
                          : 'Starts the recorder over Bluetooth. A short press '
                              'of its button adds a highlight.',
                      style: TextStyle(color: c.muted, fontSize: 15),
                    ),
                  ),
                ]),
                const Spacer(),
                Center(
                  child: Text(
                    formatDuration(elapsed),
                    style: Theme.of(context).textTheme.displayLarge?.copyWith(
                      fontWeight: FontWeight.w200,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                if (_recording)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Received ${formatDuration(received)} over Bluetooth',
                        style: TextStyle(color: c.muted, fontSize: 13),
                      ),
                    ),
                  ),
                if (_recording && !_stopping) ...[
                  const SizedBox(height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      MarkerButton(
                          icon: Icons.flag_outlined,
                          label: 'Highlight',
                          onPressed: _flag),
                      MarkerButton(
                          icon: Icons.photo_camera_outlined,
                          label: 'Photo',
                          onPressed: _photo),
                      MarkerButton(
                          icon: Icons.edit_note,
                          label: 'Note',
                          onPressed: _note),
                    ],
                  ),
                  if (marks > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Center(
                        child: Text(
                          '$marks marked moment${marks == 1 ? '' : 's'}',
                          style: TextStyle(color: c.muted, fontSize: 13),
                        ),
                      ),
                    ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(_error!, style: TextStyle(color: c.danger)),
                ],
                const Spacer(),
                Center(
                  child: busy
                      ? const SizedBox(
                          width: 88,
                          height: 88,
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: CircularProgressIndicator(),
                          ),
                        )
                      : _recording
                          ? RoundButton(
                              tooltip: 'Stop and save',
                              icon: Icons.stop_rounded,
                              onPressed: _stop)
                          : RoundButton(
                              tooltip: 'Start recording',
                              icon: Icons.fiber_manual_record,
                              onPressed: _start),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
