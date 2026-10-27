package xyz.xray.vpn

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.util.Collections

internal object VpnRuntime {
    @Volatile private var sink: EventChannel.EventSink? = null
    @Volatile private var pendingLink: String? = null
    private val main = Handler(Looper.getMainLooper())
    private val logBuffer = Collections.synchronizedList(mutableListOf<String>())

    fun listen(eventSink: EventChannel.EventSink?) {
        sink = eventSink
    }

    fun logs(): List<String> = synchronized(logBuffer) { logBuffer.toList() }

    fun queueLink(link: String) {
        if (link.isBlank()) return
        if (sink == null) pendingLink = link else emit(mapOf("type" to "link", "url" to link))
    }

    fun takePendingLink(): String? {
        val value = pendingLink
        pendingLink = null
        return value
    }

    fun log(message: String) {
        val line = "[${System.currentTimeMillis()}] $message"
        synchronized(logBuffer) {
            logBuffer.add(line)
            while (logBuffer.size > 1500) logBuffer.removeAt(0)
        }
        android.util.Log.i("XRayVpn", message)
        emit(mapOf("type" to "log", "message" to line))
    }

    fun state(value: String, message: String = value) {
        emit(mapOf("type" to "state", "state" to value, "message" to message))
    }

    fun stats(uploadSpeed: Long, downloadSpeed: Long, uploadBytes: Long, downloadBytes: Long) {
        emit(mapOf("type" to "stats", "uploadSpeed" to uploadSpeed, "downloadSpeed" to downloadSpeed,
            "uploadBytes" to uploadBytes, "downloadBytes" to downloadBytes))
    }

    private fun emit(value: Map<String, Any?>) {
        main.post { try { sink?.success(value) } catch (e: Exception) { android.util.Log.w("XRayVpn", "Event delivery failed", e) } }
    }
}
