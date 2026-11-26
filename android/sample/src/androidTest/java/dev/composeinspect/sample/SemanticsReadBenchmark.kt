package dev.composeinspect.sample

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import androidx.compose.ui.node.RootForTest
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getAllSemanticsNodes
import androidx.compose.ui.semantics.getOrNull
import dev.composeinspect.collector.ComposeCollector
import dev.composeinspect.protocol.JsonResponseEncoder
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.FutureTask

/** Research-only main-thread comparison on the fixed eager-composition screen. */
class SemanticsReadBenchmark : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }

    private fun <T> onMain(read: () -> T): T {
        val task = FutureTask(read)
        runOnMainSync(task)
        return task.get()
    }

    private fun texts(view: View, result: MutableSet<String>) {
        if (view is RootForTest) {
            for (node in view.semanticsOwner.getAllSemanticsNodes(mergingEnabled = true)) {
                node.config.getOrNull(SemanticsProperties.Text)?.forEach { result.add(it.text) }
            }
        } else if (view is ViewGroup) {
            for (index in 0 until view.childCount) texts(view.getChildAt(index), result)
        }
    }

    override fun onStart() {
        try {
            val intent = Intent().setClassName(targetContext.packageName, MainActivity::class.java.name)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("scenario", "performance")
            val activity = startActivitySync(intent)
            waitForIdleSync()
            val expected = (0 until 24).map { "Card $it" }.toSet()
            val samples = JSONArray()
            fun measure(mode: String, warmup: Boolean) {
                val start = SystemClock.elapsedRealtimeNanos()
                val elapsed: Double
                if (mode == "geometry") {
                    val data = onMain { ComposeCollector.capture(listOf(activity)) }
                    elapsed = (SystemClock.elapsedRealtimeNanos() - start) / 1e6
                    check(data.getBoolean("complete"))
                    val json = JsonResponseEncoder.encode(data).decodeToString()
                    check(data.getBoolean("geometryOnly") && data.getJSONObject("stats").getInt("parameters") == 0)
                    check(json.contains("\"name\":\"PerformanceProbe\""))
                } else {
                    val received = onMain { mutableSetOf<String>().also { texts(activity.window.decorView, it) } }
                    elapsed = (SystemClock.elapsedRealtimeNanos() - start) / 1e6
                    check(received.containsAll(expected))
                }
                if (!warmup) samples.put(JSONObject().put("mode", mode).put("ms", elapsed))
            }
            repeat(22) { round ->
                val first = if (round % 2 == 0) "geometry" else "text"
                measure(first, round < 2)
                measure(if (first == "geometry") "text" else "geometry", round < 2)
            }
            onMain { activity.finish() }
            finish(Activity.RESULT_OK, Bundle().apply {
                putString("stream", JSONObject().put("verifiedLabels", expected.size).put("samples", samples).toString())
            })
        } catch (error: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply { putString("stream", error.stackTraceToString()) })
        }
    }
}
