package dev.composeinspect.payload

import android.app.Activity
import android.app.Application
import android.os.Handler
import android.os.Looper
import dev.composeinspect.collector.ComposableReturns
import dev.composeinspect.collector.ComposeCollector
import dev.composeinspect.protocol.CollectorEntry
import org.json.JSONObject
import java.util.concurrent.FutureTask
import java.util.concurrent.TimeUnit

class DesktopCollector(private val app: Application) : CollectorEntry {
    override fun capabilities() = listOf("composition-tables", "call-source-locations", "gzip-json-v1",
        "skip-overlays-v1", "source-only-v1", "geometry-only-v1", "component-details-v1") +
        if (android.os.Build.VERSION.SDK_INT >= 34) listOf("window-images-v1") else emptyList()

    private val index by lazy {
        val info = app.applicationInfo
        try {
            ComposableReturns.fromInstalledApks(app, listOf(info.sourceDir) + info.splitSourceDirs.orEmpty())
        } catch (e: Exception) {
            android.util.Log.w("ComposeInspect", "Cannot resolve composable return signatures", e)
            ComposableReturns.empty
        }
    }

    override fun capture(activities: Collection<Activity>, options: JSONObject, attachments: MutableList<ByteArray>): JSONObject {
        val windowImages = options.optBoolean("windowImages") && options.getString("command") == "capture-gzip" && android.os.Build.VERSION.SDK_INT >= 34
        val copies = WindowCopies()
        val sourceKeys = options.optJSONArray("sourceKeys")?.let { keys ->
            (0 until keys.length()).mapTo(HashSet()) { keys.getString(it) }
        }
        val waitStarted = android.os.SystemClock.elapsedRealtimeNanos()
        val signatures = index
        val waitMs = (android.os.SystemClock.elapsedRealtimeNanos() - waitStarted) / 1e6
        val queued = android.os.SystemClock.elapsedRealtimeNanos()
        val task = FutureTask {
            val started = android.os.SystemClock.elapsedRealtimeNanos()
            ComposeCollector.capture(activities.toList(), options.optBoolean("skipOverlayWindows", false),
                if (windowImages) copies::start else null, signatures, options.optBoolean("onlySourceNodes"), sourceKeys,
                componentDetails = !options.optBoolean("geometryOnly", true)).apply {
                put("timings", (optJSONObject("timings") ?: JSONObject())
                    .put("returnIndexWaitMs", waitMs)
                    .put("mainThreadQueueMs", (started - queued) / 1e6)
                    .put("collectMs", (android.os.SystemClock.elapsedRealtimeNanos() - started) / 1e6))
            }
        }
        val handler = Handler(Looper.getMainLooper())
        handler.post(task)
        val response = try { task.get(15, TimeUnit.SECONDS) }
        finally { handler.removeCallbacks(task); task.cancel(false) }
        if (windowImages) attachments.addAll(copies.finish(response))
        return response
    }
}
