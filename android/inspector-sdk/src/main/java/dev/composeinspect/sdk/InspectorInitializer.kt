package dev.composeinspect.sdk

import android.app.Activity
import android.app.Application
import android.content.pm.ApplicationInfo
import android.net.LocalServerSocket
import android.os.Bundle
import android.os.Process
import android.util.Log
import dev.composeinspect.protocol.Protocol
import dev.composeinspect.protocol.JsonResponseEncoder
import dev.composeinspect.protocol.GzipFrame
import org.json.JSONObject
import java.util.Collections
import java.util.WeakHashMap
import kotlin.concurrent.thread

/** Manifest-merged initialization: the host app has no SDK imports or initialization calls. */
class InspectorInitializer : androidx.startup.Initializer<Boolean> {
    override fun dependencies(): List<Class<out androidx.startup.Initializer<*>>> = emptyList()
    override fun create(context: android.content.Context): Boolean {
        val app = context.applicationContext as? Application ?: return false
        if (app.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE == 0) return false
        // This probe supports the main process only; never create a competing socket in :remote.
        if (android.os.Build.VERSION.SDK_INT >= 28 && Application.getProcessName() != app.packageName) return false
        try {
            androidx.compose.ui.platform.isDebugInspectorInfoEnabled = true
            val collector = CollectorStore(app)
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
                                fun send(response: JSONObject, attachments: List<ByteArray> = emptyList()) {
                                    val json = JsonResponseEncoder.encode(response)
                                    socket.outputStream.write(if (compressed) GzipFrame.encode(json, attachments) else json)
                                }
                                try {
                                    // ADB forwarding originates from shell/root; other apps are rejected.
                                    if (socket.peerCredentials.uid !in setOf(0, 2000, Process.myUid())) return@use
                                    socket.soTimeout = 5000
                                    val input = socket.inputStream.buffered()
                                    val request = java.io.ByteArrayOutputStream()
                                    val maxBytes = 4 * 1024 * 1024
                                    while (request.size() < maxBytes) {
                                        val byte = input.read()
                                        if (byte == -1 || byte == 10) break
                                        request.write(byte)
                                    }
                                    require(request.size() < maxBytes) { "Request too large" }
                                    val options = JSONObject(request.toString("UTF-8"))
                                    val command = options.getString("command")
                                    compressed = command == "capture-gzip"
                                    val attachments = mutableListOf<ByteArray>()
                                    val response = when (command) {
                                        "hello" -> JSONObject().put("collectorABI", 1).put("checksCollectorVersion", true)
                                        "prepare" -> collector.prepare(options)
                                        "install" -> collector.install(options, input)
                                        "capture", "capture-gzip" -> collector.entry(options).capture(activities, options, attachments)
                                        else -> Protocol.error("Unknown command: $command")
                                    }
                                    response.put("protocolVersion", Protocol.VERSION).put("sdkVersion", Protocol.SDK_VERSION)
                                        .put("packageName", app.packageName).put("pid", Process.myPid())
                                    send(response, attachments)
                                } catch (e: LinkageError) {
                                    runCatching { send(Protocol.error("Collector incompatible with host: $e")) }
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
        } catch (e: LinkageError) {
            Log.w("ComposeInspect", "Compose inspection unavailable", e)
            return false
        } catch (e: Exception) {
            Log.e("ComposeInspect", "Initialization unavailable", e)
            return false
        }
    }
}
