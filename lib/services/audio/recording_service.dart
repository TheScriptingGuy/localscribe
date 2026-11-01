import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Notification button ids, also the messages sent to the UI isolate.
class RecordingAction {
  static const pause = 'pause';
  static const resume = 'resume';
  static const stop = 'stop';
}

/// Android foreground service (type `microphone`) that keeps a recording
/// alive while the screen is off or the app is in the background.
///
/// The audio itself is still captured by the `record` plugin in the app; the
/// service only keeps the process foreground-eligible for the mic and shows
/// the ongoing notification with Pause/Resume and Stop.
class RecordingService {
  static const _serviceId = 701;

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
    if (await FlutterForegroundTask.checkNotificationPermission() !=
        NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
      return;
    }
    await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: 'LocalScribe is recording',
      notificationText: 'Tap to return to the recorder',
      notificationButtons: _buttons(paused: false),
      callback: _startCallback,
    );
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
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
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
