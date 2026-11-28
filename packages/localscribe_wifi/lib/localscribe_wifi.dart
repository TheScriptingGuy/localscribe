import 'package:flutter/services.dart';

/// Joins / leaves the Plaud recorder's local-only WPA2 access point through a
/// native `WifiNetworkSpecifier` request (see the Android plugin). This mirrors
/// the official Plaud app's native WifiAgent and, unlike `wifi_iot`, binds the
/// process to the recorder network so the phone's :8081 WebSocket server is
/// reachable over the AP.
class LocalscribeWifi {
  const LocalscribeWifi._();

  static const MethodChannel _channel = MethodChannel('localscribe/wifi');

  /// Joins the WPA2 access point [ssid] with [passphrase]. Returns `true` once
  /// the network is available and the process is bound to it, `false` if the
  /// request is unavailable (wrong SSID/passphrase, no match, or [timeout]).
  static Future<bool> joinAp(
    String ssid,
    String passphrase, {
    Duration timeout = const Duration(seconds: 40),
  }) async {
    final joined = await _channel.invokeMethod<bool>('joinAp', <String, dynamic>{
      'ssid': ssid,
      'passphrase': passphrase,
      'timeoutMs': timeout.inMilliseconds,
    });
    return joined ?? false;
  }

  /// Unbinds the process from the recorder network and releases the request.
  static Future<void> leaveAp() => _channel.invokeMethod<void>('leaveAp');
}
