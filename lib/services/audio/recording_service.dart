import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Notification button ids, also the messages sent to the UI isolate.
class RecordingAction {
  static const pause = 'pause';
  static const resume = 'resume';
  static const stop = 'stop';
}

enum _Mode { recording, transcribing }

/// Android foreground service that keeps the app working while the screen is
/// off or the app is in the background: type `microphone` while recording,
/// `dataSync` (plus a wake lock) during on-device transcription.
///
/// The audio itself is still captured by the `record` plugin in the app; the
/// service only keeps the process foreground-eligible for the mic and shows
/// the ongoing notification with Pause/Resume and Stop. Only one service can
/// run, so recording takes precedence over transcription.
class RecordingService {
  static const _serviceId = 701;
  static _Mode? _mode;

  /// Latest transcription status, kept so the transcription notification can
  /// come back if a recording interrupted it.
  static String? _transcribing;

  /// Call once at startup, before runApp.
  static void init() {
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'recording',
        channelName: 'Recording',
        channelDescription: 'Shown while LocalScribe is recording audio',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  static Future<void> start() async {
    await _ensureNotificationPermission();
    // A transcription service has the wrong type for the mic; replace it.
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: 'LocalScribe is recording',
      notificationText: 'Tap to return to the recorder',
      notificationButtons: _buttons(paused: false),
      callback: _startCallback,
    );
    _mode = _Mode.recording;
  }

  /// Keeps an on-device transcription running with the screen off. No-op
  /// while recording (that service already keeps the process alive).
  static Future<void> startTranscribing(String text) async {
    _transcribing = text;
    if (_mode == _Mode.recording) return;
    if (_mode == _Mode.transcribing) return updateTranscribing(text);
    await _ensureNotificationPermission();
    await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: [ForegroundServiceTypes.dataSync],
      notificationTitle: 'LocalScribe is transcribing',
      notificationText: text,
      callback: _startCallback,
    );
    _mode = _Mode.transcribing;
  }

  static Future<void> updateTranscribing(String text) async {
    _transcribing = text;
    if (_mode != _Mode.transcribing) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: 'LocalScribe is transcribing',
      notificationText: text,
    );
  }

  static Future<void> stopTranscribing() async {
    _transcribing = null;
    if (_mode != _Mode.transcribing) return;
    _mode = null;
    await FlutterForegroundTask.stopService();
  }

  static Future<void> _ensureNotificationPermission() async {
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  static Future<void> setPaused(bool paused) async {
    await FlutterForegroundTask.updateService(
      notificationTitle:
          paused ? 'LocalScribe recording paused' : 'LocalScribe is recording',
      notificationText: 'Tap to return to the recorder',
      notificationButtons: _buttons(paused: paused),
    );
  }

  static Future<void> stop() async {
    if (_mode != _Mode.recording) return;
    _mode = null;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
    final pending = _transcribing;
    if (pending != null) await startTranscribing(pending);
  }

  static List<NotificationButton> _buttons({required bool paused}) => [
        paused
            ? const NotificationButton(id: RecordingAction.resume, text: 'Resume')
            : const NotificationButton(id: RecordingAction.pause, text: 'Pause'),
        const NotificationButton(id: RecordingAction.stop, text: 'Stop'),
      ];
}

@pragma('vm:entry-point')
void _startCallback() {
  FlutterForegroundTask.setTaskHandler(_RecordingTaskHandler());
}

/// Runs in the service isolate. It does no work itself; it only relays
/// notification button presses to the recorder screen.
class _RecordingTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) {
    FlutterForegroundTask.sendDataToMain(id);
  }
}
