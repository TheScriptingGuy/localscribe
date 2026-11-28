package ai.localscribe.wifi

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiNetworkSpecifier
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PatternMatcher
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Joins the Plaud recorder's local-only WPA2 access point using a
 * [WifiNetworkSpecifier], mirroring the official Plaud app's native WifiAgent:
 *  - `setSsidPattern(LITERAL)` on API 30+ (else `setSsid`),
 *  - `removeCapability(NET_CAPABILITY_INTERNET)` (the recorder AP has no internet),
 *  - `bindProcessToNetwork(...)` on availability so the phone's :8081 WebSocket
 *    server is reachable over the AP.
 *
 * `wifi_iot` built the request correctly but never bound the process to the
 * network, so the fast-transfer link could not be established.
 */
class LocalscribeWifiPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var connectivity: ConnectivityManager? = null
    private val main = Handler(Looper.getMainLooper())
    private var callback: ConnectivityManager.NetworkCallback? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        connectivity = binding.applicationContext
            .getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        channel = MethodChannel(binding.binaryMessenger, "localscribe/wifi")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        releaseCallback()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "joinAp" -> {
                val ssid = call.argument<String>("ssid")
                val passphrase = call.argument<String>("passphrase")
                val timeoutMs = call.argument<Int>("timeoutMs") ?: 40_000
                if (ssid == null || passphrase == null) {
                    result.error("args", "ssid and passphrase are required", null)
                } else {
                    joinAp(ssid, passphrase, timeoutMs, result)
                }
            }
            "leaveAp" -> {
                leaveAp()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun joinAp(
        ssid: String,
        passphrase: String,
        timeoutMs: Int,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            result.error("unsupported", "WifiNetworkSpecifier requires Android 10+", null)
            return
        }
        val cm = connectivity
        if (cm == null) {
            result.error("state", "no ConnectivityManager", null)
            return
        }
        releaseCallback()

        val specifier = WifiNetworkSpecifier.Builder().apply {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                setSsidPattern(PatternMatcher(ssid, PatternMatcher.PATTERN_LITERAL))
            } else {
                @Suppress("DEPRECATION")
                setSsid(ssid)
            }
            setWpa2Passphrase(passphrase)
        }.build()

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .setNetworkSpecifier(specifier)
            .build()

        val settled = AtomicBoolean(false)
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cm.bindProcessToNetwork(network)
                if (settled.compareAndSet(false, true)) {
                    main.post { result.success(true) }
                }
            }

            override fun onUnavailable() {
                if (settled.compareAndSet(false, true)) {
                    main.post { result.success(false) }
                }
            }
        }
        callback = cb
        cm.requestNetwork(request, cb, timeoutMs)
    }

    private fun leaveAp() {
        connectivity?.bindProcessToNetwork(null)
        releaseCallback()
    }

    private fun releaseCallback() {
        callback?.let { cb ->
            try {
                connectivity?.unregisterNetworkCallback(cb)
            } catch (_: IllegalArgumentException) {
                // Callback was never registered or already released.
            }
        }
        callback = null
    }
}
