package xyz.xray.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import libXray.DialerController
import libXray.LibXray
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

class XrayVpnService : VpnService() {
    companion object {
        const val ACTION_START = "xyz.xray.vpn.START"
        const val ACTION_STOP = "xyz.xray.vpn.STOP"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_EXCLUDE_APP = "excludeApp"
        const val EXTRA_BYPASS_APPS = "bypassApps"
        const val EXTRA_USE_TUN = "useTun"
        private const val CHANNEL_ID = "xray_vpn_active"
        private const val NOTIFICATION_ID = 701
    }

    private var tun: android.os.ParcelFileDescriptor? = null
    private val running = AtomicBoolean(false)
    private val main = Handler(Looper.getMainLooper())
    private var metricsRunnable: Runnable? = null
    private var previousUpload = 0L
    private var previousDownload = 0L
    private var totalUpload = 0L
    private var totalDownload = 0L
    private var lastMetricAt = 0L
    @Volatile private var protectSockets = true

    private val dialerController = object : DialerController {
        override fun protectFd(fd: Long): Boolean {
            if (!protectSockets) return true
            return try { protect(fd.toInt()) } catch (e: Exception) { VpnRuntime.log("protect(fd) failed: ${e.message}"); false }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = super.onBind(intent)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                thread(name = "xray-vpn-stop") { stopTunnel("Disconnected by user") }
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val config = intent.getStringExtra(EXTRA_CONFIG)
                val excludeApp = intent.getBooleanExtra(EXTRA_EXCLUDE_APP, false)
                val bypassApps = intent.getStringExtra(EXTRA_BYPASS_APPS).orEmpty()
                val useTun = intent.getBooleanExtra(EXTRA_USE_TUN, true)
                if (config.isNullOrBlank()) {
                    VpnRuntime.state("failed", "VPN configuration was empty")
                    stopSelf(startId)
                    return START_NOT_STICKY
                }
                ensureNotificationChannel()
                startForeground(NOTIFICATION_ID, notification("Starting secure tunnel"))
                thread(name = "xray-vpn-start") { startTunnel(config, excludeApp, bypassApps, useTun) }
            }
            else -> {
                if (!running.get()) stopSelf(startId)
            }
        }
        return START_STICKY
    }

    private fun startTunnel(configText: String, excludeApp: Boolean, bypassApps: String, useTun: Boolean) {
        stopTunnel("Replacing previous tunnel", emitState = false, removeNotification = false)
        protectSockets = useTun
        VpnRuntime.state("connecting", if (useTun) "Preparing Android TUN interface" else "Preparing local proxy engine")
        try {
            val config = JSONObject(configText)
            var established: android.os.ParcelFileDescriptor? = null
            if (useTun) {
                val builder = Builder()
                    .setSession("XRay Vpn")
                    .setMtu(1500)
                    .addAddress("10.111.0.1", 32)
                    .addAddress("fd00:1111:2222::1", 128)
                    .addDnsServer("1.1.1.1")
                    .addRoute("0.0.0.0", 0)
                    .addRoute("::", 0)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) builder.setMetered(false)
                if (excludeApp) {
                    builder.addDisallowedApplication(packageName)
                    VpnRuntime.log("SSH mode: excluded this app UID to prevent the SSH control socket looping into its own tunnel")
                }
                val bypasses = bypassApps.split(Regex("[\\s,;]+")).map { it.trim() }.filter { it.contains('.') }.distinct()
                for (packageId in bypasses) {
                    try { builder.addDisallowedApplication(packageId); VpnRuntime.log("Bypass app added: $packageId") }
                    catch (e: Exception) { VpnRuntime.log("Could not add bypass package $packageId: ${e.message}") }
                }
                established = builder.establish() ?: throw IllegalStateException("Android refused to establish the TUN interface")
                tun = established
                val env = if (config.optJSONObject("env") != null) config.getJSONObject("env") else JSONObject().also { config.put("env", it) }
                val activeTun = established ?: throw IllegalStateException("TUN interface was not established")
                env.put("xray.tun.fd", activeTun.fd.toString())
            } else {
                val env = if (config.optJSONObject("env") != null) config.getJSONObject("env") else JSONObject().also { config.put("env", it) }
                env.remove("xray.tun.fd")
                tun = null
                VpnRuntime.log("Proxy-only mode: no Android TUN interface will be created; apps must use the local proxy")
            }

            LibXray.registerDialerController(dialerController)
            LibXray.registerListenerController(dialerController)
            try { LibXray.setDNS(dialerController, "1.1.1.1:53") }
            catch (e: Exception) { VpnRuntime.log("DNS protect registration warning: ${e.message}") }

            VpnRuntime.log("Starting official libXray ${config.optJSONObject("log")?.optString("loglevel") ?: "default"} configuration")
            val request = JSONObject().put("apiVersion", 3).put("method", "runXray")
                .put("payload", JSONObject().put("xrayJson", config.toString())).toString()
            val response = JSONObject(LibXray.invoke(request))
            if (!response.optBoolean("success", false)) {
                throw IllegalStateException(response.optString("error", "libXray refused to start the engine"))
            }
            val state = JSONObject(LibXray.invoke(JSONObject().put("apiVersion", 3).put("method", "getXrayState").toString()))
            val isRunning = state.optJSONObject("data")?.optBoolean("running", false) == true
            if (!isRunning) throw IllegalStateException("libXray returned success but did not report a running core")
            running.set(true)
            previousUpload = 0L
            previousDownload = 0L
            totalUpload = 0L
            totalDownload = 0L
            lastMetricAt = System.currentTimeMillis()
            updateNotification("VPN connected")
            VpnRuntime.state("connected", if (useTun) "Native Xray VPN engine running" else "Local proxy engine running")
            VpnRuntime.log(if (useTun) "Native Xray core is running; TUN descriptor ${established?.fd} is attached" else "Native Xray core is running in proxy-only mode")
            startMetricsPolling()
        } catch (e: Exception) {
            VpnRuntime.log("VPN startup failed: ${e.message}")
            try { LibXray.invoke(JSONObject().put("apiVersion", 3).put("method", "stopXray").toString()) } catch (_: Exception) {}
            try { LibXray.resetDNS() } catch (_: Exception) {}
            try { tun?.close() } catch (_: Exception) {}
            tun = null
            running.set(false)
            protectSockets = false
            VpnRuntime.state("failed", e.message ?: "VPN startup failed")
            removeForegroundNotification()
            stopSelf()
        }
    }

    private fun startMetricsPolling() {
        metricsRunnable?.let { main.removeCallbacks(it) }
        val task = object : Runnable {
            override fun run() {
                if (!running.get()) return
                try {
                    val json = URL("http://127.0.0.1:49227/debug/vars").openConnection() as HttpURLConnection
                    json.connectTimeout = 1000
                    json.readTimeout = 1000
                    val body = json.inputStream.bufferedReader().use { it.readText() }
                    json.disconnect()
                    val root = JSONObject(body)
                    val up = findMetric(root, "uplink")
                    val down = findMetric(root, "downlink")
                    val now = System.currentTimeMillis()
                    val elapsed = (now - lastMetricAt).coerceAtLeast(1)
                    val upSpeed = ((up - previousUpload).coerceAtLeast(0L) * 1000L) / elapsed
                    val downSpeed = ((down - previousDownload).coerceAtLeast(0L) * 1000L) / elapsed
                    previousUpload = up
                    previousDownload = down
                    totalUpload = up
                    totalDownload = down
                    lastMetricAt = now
                    VpnRuntime.stats(upSpeed, downSpeed, totalUpload, totalDownload)
                } catch (_: Exception) {
                    // Metrics can be unavailable for a short period during engine startup.
                }
                main.postDelayed(this, 1000)
            }
        }
        metricsRunnable = task
        main.postDelayed(task, 1000)
    }

    private fun findMetric(value: Any?, keyword: String): Long {
        var sum = 0L
        when (value) {
            is JSONObject -> {
                val keys = value.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val child = value.opt(key)
                    val lower = key.lowercase()
                    if (lower.contains("traffic") && lower.contains(keyword) && child is Number) sum += child.toLong()
                    else sum += findMetric(child, keyword)
                }
            }
            is JSONArray -> for (i in 0 until value.length()) sum += findMetric(value.opt(i), keyword)
        }
        return sum
    }

    private fun stopTunnel(reason: String, emitState: Boolean = true, removeNotification: Boolean = true) {
        metricsRunnable?.let { main.removeCallbacks(it) }
        metricsRunnable = null
        try {
            val response = JSONObject(LibXray.invoke(JSONObject().put("apiVersion", 3).put("method", "stopXray").toString()))
            if (!response.optBoolean("success", false)) VpnRuntime.log("libXray stop warning: ${response.optString("error")}")
        } catch (e: Exception) { VpnRuntime.log("libXray stop exception: ${e.message}") }
        try { LibXray.resetDNS() } catch (_: Exception) {}
        try { tun?.close() } catch (e: Exception) { VpnRuntime.log("TUN close warning: ${e.message}") }
        tun = null
        running.set(false)
        protectSockets = false
        previousUpload = 0L
        previousDownload = 0L
        if (removeNotification) removeForegroundNotification()
        if (emitState) VpnRuntime.state("disconnected", reason)
        if (reason == "Disconnected by user" || reason.startsWith("Service destroyed")) stopSelf()
    }

    @Suppress("DEPRECATION")
    private fun removeForegroundNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) stopForeground(STOP_FOREGROUND_REMOVE) else stopForeground(true)
    }

    override fun onDestroy() {
        thread(name = "xray-vpn-destroy") { stopTunnel("Service destroyed", emitState = true) }
        super.onDestroy()
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "VPN connection", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows the active XRay Vpn connection state"
            })
        }
    }

    private fun notification(message: String): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = launch?.let { PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE) }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, CHANNEL_ID) else Notification.Builder(this)
        builder.setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentTitle("XRay Vpn")
            .setContentText(message)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(pending)
        val disconnect = PendingIntent.getService(this, 1, Intent(this, XrayVpnService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        builder.addAction(Notification.Action.Builder(android.R.drawable.ic_media_pause, "Disconnect", disconnect).build())
        return builder.build()
    }

    private fun updateNotification(message: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification(message))
    }
}
