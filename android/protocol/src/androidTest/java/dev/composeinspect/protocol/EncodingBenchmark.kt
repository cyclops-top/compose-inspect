package dev.composeinspect.protocol

import android.app.Activity
import android.app.Instrumentation
import android.os.Bundle
import android.os.SystemClock
import org.json.JSONObject

/** Run explicitly with a real capture fixture; does not interact with the host app. */
class EncodingBenchmark : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        try {
            val raw = context.assets.open("capture.json").bufferedReader().use { it.readText() }
            // Android's fixture JSON parser is recursive; the production collector constructs
            // this object directly. Only fixture loading uses a larger stack, not encoding.
            val load = java.util.concurrent.FutureTask { JSONObject(raw) }
            Thread(null, load, "LoadBenchmarkFixture", 8L * 1024 * 1024).start()
            val tree = load.get()
            val results = mutableListOf<String>()
            repeat(4) { iteration ->
                val started = SystemClock.elapsedRealtimeNanos()
                val encoded = JsonResponseEncoder.encode(tree)
                val encodedAt = SystemClock.elapsedRealtimeNanos()
                val compressed = GzipFrame.encode(encoded)
                val ended = SystemClock.elapsedRealtimeNanos()
                if (iteration == 3) java.io.File(context.filesDir, "response.frame").writeBytes(compressed)
                results += "iteration=$iteration encodeMs=${(encodedAt - started) / 1e6} gzipMs=${(ended - encodedAt) / 1e6} bytes=${encoded.size} gzipBytes=${compressed.size}"
            }
            finish(Activity.RESULT_OK, Bundle().apply { putString("stream", results.joinToString("\n")) })
        } catch (error: Throwable) {
            finish(Activity.RESULT_CANCELED, Bundle().apply { putString("stream", error.toString()) })
        }
    }
}
