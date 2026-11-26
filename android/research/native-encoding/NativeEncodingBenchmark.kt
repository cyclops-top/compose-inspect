package dev.composeinspect.sample

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.os.Bundle
import dev.composeinspect.collector.ComposeCollector
import dev.composeinspect.research.ResearchEncoder
import dev.composeinspect.protocol.JsonResponseEncoder
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.FutureTask

class NativeEncodingBenchmark : Instrumentation() {
    private lateinit var scenario: String
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        scenario = arguments?.getString("scenario") ?: "performance"
        start()
    }
    override fun onStart() {
        try {
            val activity = startActivitySync(Intent().setClassName(targetContext.packageName, MainActivity::class.java.name)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("scenario", scenario))
            waitForIdleSync()
            val task = FutureTask { ComposeCollector.capture(listOf(activity)) }
            runOnMainSync(task)
            val snapshot = task.get()
            check(snapshot.getBoolean("complete") && snapshot.getBoolean("geometryOnly"))
            val samples = JSONArray()
            val reference = JsonResponseEncoder.encode(snapshot)
            val work = FutureTask {
                val forward = (0 until 7).map { shift -> listOf(0, 1, 6, 2, 5, 3, 4).map { (it + shift) % 7 } }
                val orders = forward + forward.map { it.reversed() }
                for (round in -7 until 28) for (mode in orders[(round + 14) % 14]) {
                    val start = System.nanoTime()
                    var ready = start
                    val bytes = ResearchEncoder.encode(snapshot, mode) { ready = System.nanoTime() }
                    val end = System.nanoTime()
                    check(bytes.contentEquals(reference)) { "Output mismatch in mode $mode" }
                    samples.put(JSONObject().put("round", round).put("mode", mode)
                        .put("packMs", (ready-start)/1e6).put("totalMs", (end-start)/1e6))
                }
            }
            Thread(null, work, "EncodeFixture", 8L * 1024 * 1024).start()
            work.get()
            val result = JSONObject().put("scenario", scenario).put("stats", snapshot.getJSONObject("stats"))
                .put("bytes", reference.size).put("samples", samples)
            targetContext.filesDir.resolve("native-benchmark.json").writeText(result.toString())
            runOnMainSync { activity.finish() }
            finish(Activity.RESULT_OK, Bundle().apply { putString("stream", "Verified ${samples.length()} encodings") })
        } catch (e: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply { putString("stream", e.stackTraceToString()) })
        }
    }
}
