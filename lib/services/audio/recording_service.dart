import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Notification button ids, also the messages sent to the UI isolate.
class RecordingAction {
  static const pause = 'pause';
  static const resume = 'resume';
  static const stop = 'stop';
}

enum _Mode { recording, working }

/// Android foreground service that keeps the app working while the screen is
/// off or the app is in the background: type `microphone` while recording,
/// `dataSync` (plus a wake lock) during on-device transcription or notes.
///
/// The audio itself is still captured by the `record` plugin in the app; the
/// service only keeps the process foreground-eligible for the mic and shows
/// the ongoing notification with Pause/Resume and Stop. Only one service can
/// run, so recording takes precedence over background work.
class RecordingService {
  static const _serviceId = 701;
  static _Mode? _mode;

  /// Background work keeping the service up, by owner (e.g. "transcription",
  /// "notes"): its notification title and text. The most recent update is
  /// shown. Kept so the notification can come back after a recording.
  static final _work = <String, (String, String)>{};

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

  /// Keeps on-device work (transcription, notes) running with the screen
  /// off, until every owner has called [stopWork]. While recording, the
  /// recording service already keeps the process alive.
  static Future<void> startWork(String owner, String title, String text) async {
    _work[owner] = (title, text);
    if (_mode == _Mode.recording) return;
    if (_mode == _Mode.working) return updateWork(owner, title, text);
    _mode = _Mode.working; // before awaiting, so a second owner doesn't start it too
    try {
      await _ensureNotificationPermission();
      await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        serviceTypes: [ForegroundServiceTypes.dataSync],
        notificationTitle: title,
        notificationText: text,
        callback: _startCallback,
      );
    } catch (_) {
      _mode = null;
      rethrow;
    }
  }

  static Future<void> updateWork(String owner, String title, String text) async {
    if (!_work.containsKey(owner)) return;
    _work[owner] = (title, text);
    if (_mode != _Mode.working) return;
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  static Future<void> stopWork(String owner) async {
    if (_work.remove(owner) == null) return;
    if (_mode != _Mode.working) return;
    if (_work.isNotEmpty) {
      final (title, text) = _work.values.last;
      await FlutterForegroundTask.updateService(
          notificationTitle: title, notificationText: text);
      return;
    }
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
    if (_work.isNotEmpty) {
      final owner = _work.keys.last;
      final (title, text) = _work[owner]!;
      await startWork(owner, title, text);
    }
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
