package dev.composeinspect.sdk

import android.app.Activity
import android.app.Application
import android.content.ContentProvider
import android.content.ContentValues
import android.content.pm.ApplicationInfo
import android.database.Cursor
import android.net.LocalServerSocket
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import dev.composeinspect.collector.ComposeCollector
import dev.composeinspect.protocol.Protocol
import dev.composeinspect.protocol.JsonResponseEncoder
import dev.composeinspect.protocol.GzipFrame
import org.json.JSONObject
import java.util.Collections
import java.util.WeakHashMap
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

/** Manifest-merged initialization: the host app has no SDK imports or initialization calls. */
class InspectorInitProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        val app = context?.applicationContext as? Application ?: return false
        if (app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return false
        // This probe supports the main process only; never create a competing socket in :remote.
        if (android.os.Build.VERSION.SDK_INT >= 28 && Application.getProcessName() != app.packageName) return false
        try {
            ComposeCollector.enable()
            val activities = Collections.newSetFromMap(WeakHashMap<Activity, Boolean>())
            app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
                override fun onActivityCreated(activity: Activity, state: Bundle?) { activities.add(activity) }
                override fun onActivityDestroyed(activity: Activity) { activities.remove(activity) }
                override fun onActivityStarted(activity: Activity) {}
                override fun onActivityResumed(activity: Activity) {}
                override fun onActivityPaused(activity: Activity) {}
                override fun onActivityStopped(activity: Activity) {}
                override fun onActivitySaveInstanceState(activity: Activity, state: Bundle) {}
            })
            thread(name = "ComposeInspect", isDaemon = true) {
                try {
                    LocalServerSocket(Protocol.socketName(app.packageName)).use { server ->
                        while (!Thread.currentThread().isInterrupted) {
                            server.accept().use { socket ->
                                var compressed = false
                                fun send(response: JSONObject) {
                                    val json = JsonResponseEncoder.encode(response)
                                    socket.outputStream.write(if (compressed) GzipFrame.encode(json) else json)
                                }
                                try {
                                    // ADB forwarding originates from shell/root; other apps are rejected.
                                    if (socket.peerCredentials.uid !in setOf(0, 2000, Process.myUid())) return@use
                                    socket.soTimeout = 5000
                                    val input = socket.inputStream
                                    val request = StringBuilder()
                                    while (request.length < 4096) {
                                        val byte = input.read()
                                        if (byte == -1 || byte == 10) break
                                        request.append(byte.toChar())
                                    }
                                    require(request.length < 4096) { "Request too large" }
                                    val options = JSONObject(request.toString())
                                    val command = options.getString("command")
                                    compressed = command == "capture-gzip"
                                    val response = when (command) {
                                        "hello" -> JSONObject().put("capabilities", Protocol.array(listOf(
                                            "composition-tables", "parameters", "call-source-locations", "gzip-json-v1",
                                            "style-layers-v1", "layout-interactions-v1", "skip-overlays-v1")))
                                        "capture", "capture-gzip" -> {
                                            val queued = android.os.SystemClock.elapsedRealtimeNanos()
                                            val task = FutureTask {
                                                val started = android.os.SystemClock.elapsedRealtimeNanos()
                                                ComposeCollector.capture(activities.toList(), options.optBoolean("skipOverlayWindows", false)).apply {
                                                    put("timings", (optJSONObject("timings") ?: JSONObject())
                                                        .put("mainThreadQueueMs", (started - queued) / 1e6)
                                                        .put("collectMs", (android.os.SystemClock.elapsedRealtimeNanos() - started) / 1e6))
                                                }
                                            }
                                            val handler = Handler(Looper.getMainLooper())
                                            handler.post(task)
                                            try { task.get(15, TimeUnit.SECONDS) }
                                            finally { handler.removeCallbacks(task); task.cancel(false) }
                                        }
                                        else -> Protocol.error("Unknown command: $command")
                                    }
                                    response.put("protocolVersion", Protocol.VERSION).put("sdkVersion", Protocol.SDK_VERSION)
                                        .put("packageName", app.packageName).put("pid", Process.myPid())
                                    send(response)

                                } catch (e: StackOverflowError) {
                                    // A tooling failure must not terminate the host app.
                                    runCatching { send(Protocol.error("SDK capture exceeded stack capacity")) }
                                    Log.w("ComposeInspect", "Capture exceeded stack capacity", e)
                                } catch (e: Exception) {
                                    runCatching { send(Protocol.error(e.toString())) }
                                    Log.w("ComposeInspect", "Request failed", e)
                                }
                            }
                        }
                    }
                } catch (e: Exception) { Log.e("ComposeInspect", "Transport unavailable", e) }
            }
            return true
        } catch (e: Exception) {
            Log.e("ComposeInspect", "Initialization unavailable", e)
            return false
        }
    }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor? = null
    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0
}
