package xyz.xray.vpn

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Small native bridge used by the Dart side (lib/native.dart):
 *  - installedApps: launchable apps for the "bypass apps" picker
 *  - moveToBack: keep the activity (and the Dart SSH tunnel) alive on Back
 *  - battery optimisation + system VPN settings shortcuts
 */
class MainActivity : FlutterActivity() {
    private val channelName = "xyz.xray.vpn/native"
    private var channel: MethodChannel? = null
    private var pendingLink: String? = null

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

    /** vless:// vmess:// trojan:// ss:// hysteria2:// links opened from other apps. */
    private fun captureLink(i: Intent?) {
        if (i?.action == Intent.ACTION_VIEW) {
            i.dataString?.let { pendingLink = it }
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
