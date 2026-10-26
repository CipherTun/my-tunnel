package xyz.xray.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.IpPrefix
import android.net.VpnService
import java.net.InetAddress
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.Process
import android.net.TrafficStats
import libXray.DialerController
import libXray.LibXray
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Owns the TUN and LibXray in a dedicated process. Keeping this process separate
 * lets other Go-based engines live in their own Android service/process safely. */
class XrayVpnService : VpnService() {
    companion object {
        const val ACTION_START = "xyz.xray.vpn.action.START_XRAY"
        const val ACTION_STOP = "xyz.xray.vpn.action.STOP_XRAY"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_REMARK = "remark"
        const val EXTRA_PROXY_ONLY = "proxyOnly"
        const val EXTRA_DISALLOWED_APPS = "disallowedApps"
        const val EXTRA_BYPASS_LAN = "bypassLan"
        const val PREFS = "xray_runtime"
        private const val CHANNEL_ID = "xray_vpn_runtime"
        private const val NOTIFICATION_ID = 2401
        private const val API_VERSION = 3
    }

    private val worker = Executors.newSingleThreadExecutor()
    private val statsWorker = Executors.newSingleThreadScheduledExecutor()
    private var statsFuture: ScheduledFuture<*>? = null
    private var tun: ParcelFileDescriptor? = null
    @Volatile private var stopping = false

    private val prefs by lazy { getSharedPreferences(PREFS, MODE_PRIVATE or MODE_MULTI_PROCESS) }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> worker.execute { stopCore(); stopForegroundCompat(); stopSelf(startId) }
            ACTION_START -> {
                val config = intent.getStringExtra(EXTRA_CONFIG)
                val remark = intent.getStringExtra(EXTRA_REMARK) ?: "XRay Vpn"
                val proxyOnly = intent.getBooleanExtra(EXTRA_PROXY_ONLY, false)
                val disallowed = intent.getStringArrayListExtra(EXTRA_DISALLOWED_APPS) ?: arrayListOf()
                val bypassLan = intent.getBooleanExtra(EXTRA_BYPASS_LAN, false)
                if (config.isNullOrBlank()) {
                    writeState("error", "Missing Xray configuration")
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                stopping = false
                startForegroundCompat(notification("Connecting", remark))
                writeState("connecting", "")
                worker.execute { startCore(config, remark, proxyOnly, disallowed, bypassLan, startId) }
            }
            else -> {
                stopSelf(startId)
                return START_NOT_STICKY
            }
        }
        return START_NOT_STICKY
    }

    private fun startCore(
        rawConfig: String,
        remark: String,
        proxyOnly: Boolean,
        disallowedApps: List<String>,
        bypassLan: Boolean,
        startId: Int,
    ) {
        synchronized(this) {
            if (stopping) return
            shutdownCore()
            try {
                val config = JSONObject(rawConfig)
                if (!proxyOnly) {
                    val builder = Builder()
                        .setSession(remark)
                        .setMtu(1500)
                        .setBlocking(true)
                        .addAddress("10.77.0.2", 30)
                        .addRoute("0.0.0.0", 0)
                        .addAddress("fd77:7777:7777::2", 126)
                        .addRoute("::", 0)
                        .addDnsServer("1.1.1.1")
                        .addDnsServer("2606:4700:4700::1111")

                    for (pkg in disallowedApps.distinct()) {
                        try { builder.addDisallowedApplication(pkg) } catch (_: Exception) { }
                    }
                    if (bypassLan && Build.VERSION.SDK_INT >= 33) {
                        for (cidr in listOf("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fc00::/7", "fe80::/10")) {
                            try { builder.excludeRoute(
                                IpPrefix(
                                    InetAddress.getByName(cidr.substringBefore('/')),
                                    cidr.substringAfter('/').toInt()
                                )
                            ) } catch (_: Exception) { }
                        }
                    }
                    tun = builder.establish() ?: error("Android could not establish the VPN TUN. Check VPN permission.")
                    val inbounds = config.optJSONArray("inbounds") ?: JSONArray()
                    val kept = JSONArray()
                    for (i in 0 until inbounds.length()) {
                        val item = inbounds.optJSONObject(i) ?: continue
                        if (!item.optString("protocol").equals("tun", true)) kept.put(item)
                    }
                    kept.put(JSONObject()
                        .put("tag", "app-tun")
                        .put("protocol", "tun")
                        .put("settings", JSONObject().put("name", "xraytun0").put("mtu", 1500)))
                    config.put("inbounds", kept)
                    val env = config.optJSONObject("env") ?: JSONObject()
                    env.put("xray.tun.fd", tun!!.fd.toString())
                    config.put("env", env)
                }

                val controller = object : DialerController {
                    override fun protectFd(fd: Long): Boolean = protect(fd.toInt())
                }
                LibXray.registerDialerController(controller)
                LibXray.registerListenerController(controller)
                if (!proxyOnly) LibXray.setDNS(controller, "1.1.1.1:53")

                val request = JSONObject()
                    .put("apiVersion", API_VERSION)
                    .put("method", "runXray")
                    .put("payload", JSONObject().put("xrayJson", config.toString()))
                val response = JSONObject(LibXray.invoke(request.toString()))
                if (!response.optBoolean("success")) {
                    error(response.optString("error").ifBlank { "LibXray failed to start Xray" })
                }

                val version = runCatching {
                    val versionResponse = JSONObject(LibXray.invoke(JSONObject().put("apiVersion", API_VERSION).put("method", "xrayVersion").toString()))
                    val rawData = versionResponse.opt("data")
                    val versionData = when (rawData) {
                        is JSONObject -> rawData
                        is String -> JSONObject(rawData)
                        else -> JSONObject()
                    }
                    versionData.optString("version", "unknown")
                }.getOrDefault("unknown")
                val rx = TrafficStats.getUidRxBytes(Process.myUid()).coerceAtLeast(0L)
                val tx = TrafficStats.getUidTxBytes(Process.myUid()).coerceAtLeast(0L)
                prefs.edit()
                    .putString("state", "connected")
                    .putString("error", "")
                    .putString("version", version)
                    .putLong("startedAt", System.currentTimeMillis())
                    .putLong("baseRx", rx)
                    .putLong("baseTx", tx)
                    .putLong("previousRx", rx)
                    .putLong("previousTx", tx)
                    .putLong("uploadSpeed", 0L)
                    .putLong("downloadSpeed", 0L)
                    .putLong("uploadBytes", 0L)
                    .putLong("downloadBytes", 0L)
                    .apply()
                startStats()
                getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification("Connected", remark))
            } catch (e: Throwable) {
                shutdownCore()
                writeState("error", e.message ?: e.javaClass.simpleName)
                getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification("Connection error", e.message ?: "LibXray failed"))
                stopSelf(startId)
            }
        }
    }

    private fun startStats() {
        statsFuture?.cancel(false)
        statsFuture = statsWorker.scheduleAtFixedRate({
            try {
                val stateResponse = JSONObject(LibXray.invoke(
                    JSONObject().put("apiVersion", API_VERSION).put("method", "getXrayState").toString()
                ))
                val rawState = stateResponse.opt("data")
                val stateData = when (rawState) {
                    is JSONObject -> rawState
                    is String -> JSONObject(rawState)
                    else -> JSONObject()
                }
                if (stateResponse.optBoolean("success") && !stateData.optBoolean("running", true)) {
                    writeState("error", "LibXray stopped unexpectedly")
                    return@scheduleAtFixedRate
                }
            } catch (_: Throwable) { }
            val rx = TrafficStats.getUidRxBytes(Process.myUid()).coerceAtLeast(0L)
            val tx = TrafficStats.getUidTxBytes(Process.myUid()).coerceAtLeast(0L)
            val oldRx = prefs.getLong("previousRx", rx)
            val oldTx = prefs.getLong("previousTx", tx)
            val baseRx = prefs.getLong("baseRx", rx)
            val baseTx = prefs.getLong("baseTx", tx)
            prefs.edit()
                .putLong("downloadSpeed", (rx - oldRx).coerceAtLeast(0L))
                .putLong("uploadSpeed", (tx - oldTx).coerceAtLeast(0L))
                .putLong("downloadBytes", (rx - baseRx).coerceAtLeast(0L))
                .putLong("uploadBytes", (tx - baseTx).coerceAtLeast(0L))
                .putLong("previousRx", rx)
                .putLong("previousTx", tx)
                .apply()
        }, 1, 1, TimeUnit.SECONDS)
    }

    private fun stopCore() {
        synchronized(this) { shutdownCore(); writeState("disconnected", "") }
    }

    private fun shutdownCore() {
        statsFuture?.cancel(false)
        statsFuture = null
        runCatching {
            LibXray.invoke(JSONObject().put("apiVersion", API_VERSION).put("method", "stopXray").toString())
        }
        runCatching { LibXray.resetDNS() }
        runCatching { tun?.close() }
        tun = null
    }

    private fun writeState(state: String, error: String) {
        prefs.edit().putString("state", state).putString("error", error).apply()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "XRay VPN", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun notification(status: String, remark: String): Notification {
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        return builder.setContentTitle("XRay Vpn · $status")
            .setContentText(remark)
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(open)
            .setOngoing(status == "Connected" || status == "Connecting")
            .build()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= 24) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    override fun onRevoke() {
        stopping = true
        worker.execute { stopCore(); stopForegroundCompat(); stopSelf() }
        super.onRevoke()
    }

    override fun onDestroy() {
        stopping = true
        shutdownCore()
        worker.shutdownNow()
        statsWorker.shutdownNow()
        super.onDestroy()
    }
}
