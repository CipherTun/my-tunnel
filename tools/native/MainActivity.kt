package xyz.xray.vpn

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import libXray.LibXray

/**
 * Small native bridge used by the Dart side (lib/native.dart):
 *  - installedApps: launchable apps for the "bypass apps" picker
 *  - moveToBack: keep the activity (and the Dart SSH tunnel) alive on Back
 *  - battery optimisation + system VPN settings shortcuts
 *  - LibXray API calls and VPN permission / service lifecycle
 *  - nativeLibraryDir: where the DNSTT and Slipstream executables are extracted
 */
class MainActivity : FlutterActivity() {
    private val channelName = "xyz.xray.vpn/native"
    private var channel: MethodChannel? = null
    private var pendingLink: String? = null
    private var vpnPermissionResult: MethodChannel.Result? = null

    companion object {
        private const val VPN_PERMISSION_REQUEST = 6417
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        captureLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureLink(intent)
        val link = pendingLink
        if (link != null) {
            channel?.invokeMethod("onLink", link)
            pendingLink = null
        }
    }

    /** Supported Xray and custom DNS-tunnel share links opened from other apps. */
    private fun captureLink(i: Intent?) {
        if (i?.action == Intent.ACTION_VIEW) {
            i.dataString?.let { pendingLink = it }
        }
    }

    @Deprecated("Deprecated in Android API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_REQUEST) {
            val pending = vpnPermissionResult
            vpnPermissionResult = null
            pending?.success(resultCode == RESULT_OK)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        channel!!.setMethodCallHandler { call, result ->
                when (call.method) {
                    "takeLink" -> {
                        val l = pendingLink
                        pendingLink = null
                        result.success(l)
                    }
                    "startOpenConnect" -> {
                        result.error("engine_not_integrated", "OpenConnect native engine is not packaged. No connection was started. Integrate the Android OpenConnect service and replace this handler.", null)
                    }
                    "startPsiphon" -> {
                        result.error("engine_not_integrated", "Psiphon Android library/service is not packaged. No connection was started. Integrate Psiphon in a separate :psiphon process before enabling this profile.", null)
                    }
                    "externalEngineState" -> {
                        result.success(mapOf("state" to "error", "error" to "Native engine is not integrated"))
                    }
                    "stopExternalEngine" -> {
                        result.success(true)
                    }
                    "libXrayInvoke" -> {
                        try {
                            val request = call.argument<String>("request")
                                ?: throw IllegalArgumentException("Missing LibXray request")
                            result.success(LibXray.invoke(request))
                        } catch (e: Throwable) {
                            result.error("libxray", e.message ?: "LibXray invocation failed", null)
                        }
                    }
                    "requestVpnPermission" -> {
                        try {
                            val prepare = VpnService.prepare(this)
                            if (prepare == null) {
                                result.success(true)
                            } else if (vpnPermissionResult != null) {
                                result.error("vpn_permission", "VPN permission request already in progress", null)
                            } else {
                                vpnPermissionResult = result
                                startActivityForResult(prepare, VPN_PERMISSION_REQUEST)
                            }
                        } catch (e: Throwable) {
                            result.error("vpn_permission", e.message ?: "Unable to request VPN permission", null)
                        }
                    }
                    "startXray" -> {
                        try {
                            val config = call.argument<String>("config")
                                ?: throw IllegalArgumentException("Missing Xray config")
                            val intent = Intent(this, XrayVpnService::class.java).apply {
                                action = XrayVpnService.ACTION_START
                                putExtra(XrayVpnService.EXTRA_CONFIG, config)
                                putExtra(XrayVpnService.EXTRA_REMARK, call.argument<String>("remark") ?: "XRay Vpn")
                                putExtra(XrayVpnService.EXTRA_PROXY_ONLY, call.argument<Boolean>("proxyOnly") ?: false)
                                putExtra(XrayVpnService.EXTRA_DISALLOWED_APPS, call.argument<ArrayList<String>>("disallowedApps") ?: arrayListOf<String>())
                                putExtra(XrayVpnService.EXTRA_BYPASS_LAN, call.argument<Boolean>("bypassLan") ?: false)
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("xray_start", e.message ?: "Unable to start LibXray service", null)
                        }
                    }
                    "stopXray" -> {
                        try {
                            startService(Intent(this, XrayVpnService::class.java).setAction(XrayVpnService.ACTION_STOP))
                            result.success(true)
                        } catch (e: Throwable) {
                            result.error("xray_stop", e.message ?: "Unable to stop LibXray service", null)
                        }
                    }
                    "xrayState" -> {
                        val prefs = getSharedPreferences(XrayVpnService.PREFS, MODE_PRIVATE or MODE_MULTI_PROCESS)
                        result.success(mapOf(
                            "state" to prefs.getString("state", "disconnected"),
                            "error" to prefs.getString("error", ""),
                            "version" to prefs.getString("version", "unknown"),
                            "uploadSpeed" to prefs.getLong("uploadSpeed", 0L),
                            "downloadSpeed" to prefs.getLong("downloadSpeed", 0L),
                            "uploadBytes" to prefs.getLong("uploadBytes", 0L),
                            "downloadBytes" to prefs.getLong("downloadBytes", 0L),
                            "startedAt" to prefs.getLong("startedAt", 0L)
                        ))
                    }
                    "moveToBack" -> {
                        moveTaskToBack(true)
                        result.success(true)
                    }
                    "installedApps" -> {
                        Thread {
                            try {
                                val pm = packageManager
                                val intent = Intent(Intent.ACTION_MAIN)
                                    .addCategory(Intent.CATEGORY_LAUNCHER)
                                val seen = HashSet<String>()
                                val out = ArrayList<Map<String, String>>()
                                for (ri in pm.queryIntentActivities(intent, 0)) {
                                    val pkg = ri.activityInfo.packageName
                                    if (pkg == packageName || !seen.add(pkg)) continue
                                    out.add(
                                        mapOf(
                                            "package" to pkg,
                                            "label" to ri.loadLabel(pm).toString()
                                        )
                                    )
                                }
                                out.sortBy { it["label"]!!.lowercase() }
                                runOnUiThread { result.success(out) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("apps", e.message, null) }
                            }
                        }.start()
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                        result.success(pm.isIgnoringBatteryOptimizations(packageName))
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            val i = Intent(
                                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(i)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "nativeLibraryDir" -> {
                        result.success(applicationInfo.nativeLibraryDir)
                    }
                    "openVpnSettings" -> {
                        try {
                            val action = if (Build.VERSION.SDK_INT >= 24)
                                Settings.ACTION_VPN_SETTINGS else "android.net.vpn.SETTINGS"
                            startActivity(Intent(action))
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
