package xyz.xray.vpn

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import android.net.Uri
import android.provider.Settings
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import libXray.LibXray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    companion object {
        private const val CONTROL = "xyz.xray.vpn/control"
        private const val EVENTS = "xyz.xray.vpn/events"
        private const val VPN_PERMISSION_REQUEST = 7612
    }

    private var permissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingLink(intent)
    }

    private fun handleIncomingLink(intent: Intent?) {
        val link = intent?.dataString
        if (link != null && intent.action == Intent.ACTION_VIEW) VpnRuntime.queueLink(link)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CONTROL).setMethodCallHandler { call, result ->
            when (call.method) {
                "prepareVpn" -> prepareVpn(result)
                "startVpn" -> {
                    val config = call.argument<String>("config")
                    if (config.isNullOrBlank()) {
                        result.error("INVALID_CONFIG", "Xray configuration is empty", null)
                    } else {
                        val intent = Intent(this, XrayVpnService::class.java).apply {
                            action = XrayVpnService.ACTION_START
                            putExtra(XrayVpnService.EXTRA_CONFIG, config)
                            putExtra(XrayVpnService.EXTRA_EXCLUDE_APP, call.argument<Boolean>("excludeApp") ?: false)
                            putExtra(XrayVpnService.EXTRA_BYPASS_APPS, call.argument<String>("bypassApps") ?: "")
                            putExtra(XrayVpnService.EXTRA_USE_TUN, call.argument<Boolean>("useTun") ?: true)
                        }
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("START_SERVICE_FAILED", e.message ?: "Could not start VPN service", null)
                        }
                    }
                }
                "stopVpn" -> {
                    val intent = Intent(this, XrayVpnService::class.java).setAction(XrayVpnService.ACTION_STOP)
                    try { startService(intent); result.success(null) }
                    catch (e: Exception) { result.error("STOP_SERVICE_FAILED", e.message, null) }
                }
                "invokeLibXray" -> {
                    val request = call.argument<String>("request")
                    if (request.isNullOrBlank()) result.error("INVALID_REQUEST", "libXray request is empty", null)
                    else Thread {
                        try {
                            val response = LibXray.invoke(request)
                            runOnUiThread { result.success(response) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("LIBXRAY_ERROR", e.message ?: "libXray invocation failed", null) }
                        }
                    }.start()
                }
                "readLogs" -> result.success(VpnRuntime.logs())
                "takeInitialLink" -> result.success(VpnRuntime.takePendingLink())
                "openSystemSettings" -> {
                    try {
                        when (call.argument<String>("page")) {
                            "vpn" -> startActivity(Intent(Settings.ACTION_VPN_SETTINGS))
                            "battery" -> startActivity(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")))
                            "app" -> startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                            else -> throw IllegalArgumentException("Unknown settings page")
                        }
                        result.success(true)
                    } catch (e: Exception) { result.error("SETTINGS_FAILED", e.message ?: "Could not open Android settings", null) }
                }
                "listApps" -> {
                    try {
                        val apps = packageManager.getInstalledApplications(PackageManager.GET_META_DATA)
                            .filter { it.packageName != packageName && packageManager.getLaunchIntentForPackage(it.packageName) != null }
                            .map { app -> mapOf("label" to app.loadLabel(packageManager).toString(), "package" to app.packageName,
                                "system" to ((app.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0)) }
                            .sortedBy { (it["label"] as String).lowercase() }
                        result.success(apps)
                    } catch (e: Exception) { result.error("APP_LIST_FAILED", e.message ?: "Could not list installed apps", null) }
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) = VpnRuntime.listen(events)
            override fun onCancel(arguments: Any?) = VpnRuntime.listen(null)
        })
    }

    private fun prepareVpn(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        if (permissionResult != null) {
            result.error("PERMISSION_PENDING", "VPN permission request is already active", null)
            return
        }
        permissionResult = result
        startActivityForResult(intent, VPN_PERMISSION_REQUEST)
    }

    @Deprecated("Deprecated in Android but retained for compatibility with the VpnService consent activity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_REQUEST) {
            val result = permissionResult
            permissionResult = null
            result?.success(resultCode == Activity.RESULT_OK)
        }
    }
}
