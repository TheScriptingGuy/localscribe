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
import 'theme.dart';

/// Records on the Plaud recorder, started and stopped from the phone, laid
/// out like the Plaud app's recording sheet: Pause | hh:mm:ss | Stop on top,
/// a live "Recording highlights" timeline, and Type / Photo / Highlight
/// below. A short press of the recorder's own button adds a highlight too.
class DeviceRecordScreen extends StatefulWidget {
  final PlaudDeviceCred device;
  const DeviceRecordScreen({super.key, required this.device});

  @override
  State<DeviceRecordScreen> createState() => _DeviceRecordScreenState();
}

/// One line in the timeline: a marker made here, or a recorder-button mark.
class _Entry {
  final RecordingMarker marker;
  final bool fromRecorder;
  _Entry(this.marker, {this.fromRecorder = false});
}

class _DeviceRecordScreenState extends State<DeviceRecordScreen> {
  static const _workOwner = 'plaud-recording';

  final _session = PlaudDeviceSession();
  StreamSubscription<int>? _markSub;
  Timer? _ticker;

  bool _starting = false;
  bool _recording = false;
  bool _stopping = false;
  bool _pausing = false;
  String? _error;

  final _entries = <_Entry>[];
  final _photos = <String, File>{};

  /// The note being typed inline, if any.
  String? _editingId;
  final _noteCtrl = TextEditingController();
  final _noteFocus = FocusNode();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    _noteFocus.addListener(() {
      if (!_noteFocus.hasFocus) _commitNote();
    });
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
    _noteCtrl.dispose();
    _noteFocus.dispose();
    _scroll.dispose();
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

  void _add(_Entry e) {
    setState(() => _entries.add(e));
    // Keep the newest entry in view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
      }
    });
  }

  void _onRecorderMark(int atMs) {
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    _add(_Entry(
        RecordingMarker(
            id: const Uuid().v4(), atMs: atMs, type: MarkerType.flag),
        fromRecorder: true));
  }

  RecordingMarker _newMarker(MarkerType type, {String? text}) =>
      RecordingMarker(
        id: const Uuid().v4(),
        atMs: _session.liveMarkMs,
        type: type,
        text: text,
      );

  void _flag() {
    HapticFeedback.mediumImpact();
    _add(_Entry(_newMarker(MarkerType.flag)));
  }

  Future<void> _photo() async {
    final marker = _newMarker(MarkerType.photo);
    try {
      final shot = await ImagePicker().pickImage(
          source: ImageSource.camera, imageQuality: 85, maxWidth: 1920);
      if (shot == null || !mounted) return;
      _photos[marker.id] = File(shot.path);
      _add(_Entry(marker));
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not take a photo: $e');
    }
  }

  /// Type: a note line appears in the timeline with the cursor in it, like
  /// the Plaud app; it is kept when typing ends, dropped if left empty.
  void _type() {
    _commitNote();
    final m = _newMarker(MarkerType.note);
    _noteCtrl.clear();
    _editingId = m.id;
    _add(_Entry(m));
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _noteFocus.requestFocus());
  }

  void _commitNote() {
    final id = _editingId;
    if (id == null) return;
    _editingId = null;
    final text = _noteCtrl.text.trim();
    final i = _entries.indexWhere((e) => e.marker.id == id);
    if (i < 0) return;
    setState(() {
      if (text.isEmpty) {
        _entries.removeAt(i);
      } else {
        final m = _entries[i].marker;
        _entries[i] = _Entry(RecordingMarker(
            id: m.id, atMs: m.atMs, type: MarkerType.note, text: text));
      }
    });
  }

  Future<void> _togglePause() async {
    if (_pausing) return;
    _commitNote();
    setState(() => _pausing = true);
    if (_session.livePaused) {
      await _session.resumeRecording();
    } else {
      await _session.pauseRecording();
    }
    if (mounted) setState(() => _pausing = false);
  }

  Future<void> _stop() async {
    if (_stopping) return;
    _commitNote();
    final store = context.read<RecordingStore>();
    final pem = context.read<PlaudCredentials>().rsaPrivateKeyPem;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
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
    // Recorder-button marks are read back from the audio itself, so only the
    // ones made in this app are passed along.
    final mine = [
      for (final e in _entries)
        if (!e.fromRecorder) e.marker,
    ];
    final rec = await addPlaudRecording(store, priv, result,
        markers: mine, photos: Map.of(_photos));
    // Like the Plaud app: back to the files list, where it shows up on top.
    navigator.pop();
    messenger.showSnackBar(SnackBar(content: Text('Saved "${rec.title}"')));
  }

  /// The Plaud app's stop sheet.
  Future<void> _confirmStop() async {
    final stop = await showModalBottomSheet<bool>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(
                  child: Text('Stop recording?',
                      style: Theme.of(ctx).textTheme.headlineMedium),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(ctx, false),
                ),
              ]),
              const Divider(height: 24),
              const Text('Your recording will be saved automatically.',
                  style: TextStyle(fontSize: 16)),
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52)),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Stop and save'),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52)),
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Continue recording'),
              ),
            ],
          ),
        ),
      ),
    );
    if (stop == true) await _stop();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _starting || _stopping;
    return PopScope(
      canPop: !_recording && !busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _recording && !_stopping) _confirmStop();
      },
      child: Scaffold(
        appBar: _recording ? null : AppBar(),
        body: SafeArea(
          child: _recording || _stopping ? _live(context) : _idle(context),
        ),
      ),
    );
  }

  /// Before starting (or after a failure).
  Widget _idle(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Record on ${widget.device.name}',
              style: Theme.of(context).textTheme.displaySmall),
          const SizedBox(height: 8),
          Text(
            _starting
                ? _session.message
                : 'Starts the recorder over Bluetooth. A short press of its '
                    'button adds a highlight.',
            style: TextStyle(color: c.muted, fontSize: 15),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: c.danger)),
          ],
          const Spacer(),
          Center(
            child: _starting
                ? const SizedBox(
                    width: 88,
                    height: 88,
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(),
                    ),
                  )
                : RoundButton(
                    tooltip: 'Start recording',
                    icon: Icons.fiber_manual_record,
                    onPressed: _start),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  /// While recording: the Plaud recording sheet.
  Widget _live(BuildContext context) {
    final c = context.colors;
    final paused = _session.livePaused;
    final canMark = !paused && !_stopping;
    return Column(
      children: [
        // Pause | ·ılı 00:00:31 | Stop
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(
            children: [
              SizedBox(
                width: 110,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _stopping || _pausing ? null : _togglePause,
                    child: Text(paused ? 'Resume' : 'Pause',
                        style: const TextStyle(fontSize: 20)),
                  ),
                ),
              ),
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.graphic_eq,
                        size: 22, color: paused ? c.faint : c.text),
                    const SizedBox(width: 6),
                    Text(
                      formatClock(_session.liveElapsed),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                width: 110,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _stopping
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      : TextButton(
                          onPressed: _confirmStop,
                          child: const Text('Stop',
                              style: TextStyle(
                                  fontSize: 20, fontWeight: FontWeight.w700)),
                        ),
                ),
              ),
            ],
          ),
        ),
        if (_session.message.startsWith('Connection lost') || _error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(_error ?? _session.message,
                style: TextStyle(color: c.danger)),
          ),
        Expanded(
          child: _entries.isEmpty ? _hints(context) : _timeline(context),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _CircleAction(
                  icon: Icons.edit_outlined,
                  label: 'Type',
                  onPressed: canMark ? _type : null),
              _CircleAction(
                  icon: Icons.photo_camera_outlined,
                  label: 'Photo',
                  onPressed: canMark ? _photo : null),
              _CircleAction(
                  icon: Icons.flag_outlined,
                  label: 'Highlight',
                  onPressed: canMark ? _flag : null),
            ],
          ),
        ),
      ],
    );
  }

  /// Empty timeline: what each button does.
  Widget _hints(BuildContext context) {
    final c = context.colors;
    Widget hint(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.only(bottom: 28),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                  shape: BoxShape.circle, border: Border.all(color: c.line)),
              child: Icon(icon, color: c.muted),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 22, color: c.muted)),
                  const SizedBox(height: 4),
                  Text(body, style: TextStyle(fontSize: 16, color: c.faint)),
                ],
              ),
            ),
          ]),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      children: [
        hint(Icons.flag_outlined, 'Add a highlight',
            'Mark a key moment, or press the recorder\'s button briefly.'),
        hint(Icons.photo_camera_outlined, 'Add a photo',
            'Capture visual details you want to remember.'),
        hint(Icons.edit_outlined, 'Add a note',
            'Jot down key points or ideas instantly.'),
      ],
    );
  }

  Widget _timeline(BuildContext context) {
    final c = context.colors;
    final store = context.read<RecordingStore>();
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
      children: [
        Text('Recording highlights',
            style: Theme.of(context)
                .textTheme
                .displaySmall
                ?.copyWith(color: c.muted)),
        const SizedBox(height: 24),
        for (final e in _entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 28),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                    switch (e.marker.type) {
                      MarkerType.flag => Icons.flag_outlined,
                      MarkerType.photo => Icons.photo_camera_outlined,
                      MarkerType.note => Icons.edit_outlined,
                    },
                    color: c.text),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          // Rounded, like the Plaud app (29.7 s -> 00:00:30).
                          formatClock(Duration(
                              seconds: (e.marker.atMs / 1000).round())),
                          style: TextStyle(
                              color: c.muted,
                              fontSize: 16,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ])),
                      const SizedBox(height: 6),
                      _entryBody(context, e, store),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _entryBody(BuildContext context, _Entry e, RecordingStore store) {
    const style = TextStyle(fontSize: 20, height: 1.35);
    final m = e.marker;
    switch (m.type) {
      case MarkerType.flag:
        return Text(
            e.fromRecorder ? 'Highlighted on the recorder' : 'Highlighted',
            style: style);
      case MarkerType.note:
        if (_editingId == m.id) {
          return TextField(
            controller: _noteCtrl,
            focusNode: _noteFocus,
            style: style,
            maxLines: null,
            textCapitalization: TextCapitalization.sentences,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _noteFocus.unfocus(),
            decoration: const InputDecoration(
              hintText: 'Type a note',
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              filled: false,
              isDense: true,
              contentPadding: EdgeInsets.zero,
            ),
          );
        }
        return Text(m.text ?? '', style: style);
      case MarkerType.photo:
        final f = _photos[m.id];
        if (f == null) return const Text('Photo', style: style);
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.file(f,
              height: 160, fit: BoxFit.cover, cacheHeight: 480),
        );
    }
  }
}

/// Plaud's round outlined action with a label under it.
class _CircleAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  const _CircleAction(
      {required this.icon, required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = onPressed != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: c.surface,
          shape: CircleBorder(side: BorderSide(color: c.line)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            child: SizedBox(
              width: 80,
              height: 80,
              child: Icon(icon, size: 30, color: enabled ? c.text : c.faint),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label,
            style: TextStyle(
                color: enabled ? c.muted : c.faint, fontSize: 15)),
      ],
    );
  }
}
