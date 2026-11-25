package dev.composeinspect.sdk

import android.graphics.Bitmap
import android.graphics.Point
import android.graphics.Rect
import android.view.PixelCopy
import android.view.View
import android.view.WindowManager
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

internal class WindowCopies {
    private val pending = mutableListOf<Pair<JSONObject, CompletableFuture<ByteArray>>>()
    private val size = Point()
    private var pixels = 0L

    @android.annotation.TargetApi(34)
    fun start(root: View, window: JSONObject) {
        val params = root.layoutParams as? WindowManager.LayoutParams
        require(params != null && params.flags and WindowManager.LayoutParams.FLAG_SECURE == 0) {
            "Window does not allow capture"
        }
        pixels += root.width.toLong() * root.height
        require(pixels <= 16_000_000) { "Window image size limit exceeded" }
        root.display.getRealSize(size)
        val position = IntArray(2).also(root::getLocationInWindow)
        val request = PixelCopy.Request.Builder.ofWindow(root)
            .setSourceRect(Rect(position[0], position[1], position[0] + root.width, position[1] + root.height)).build()
        val png = CompletableFuture<ByteArray>()
        pending += window to png
        PixelCopy.request(request, encoder) { result ->
            try {
                check(result.status == PixelCopy.SUCCESS) { "PixelCopy failed: ${result.status}" }
                val bitmap = result.bitmap
                try {
                    val bytes = ByteArrayOutputStream()
                    check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes))
                    png.complete(bytes.toByteArray())
                } finally { bitmap.recycle() }
            } catch (e: Exception) { png.completeExceptionally(e) }
        }
    }

    fun finish(response: JSONObject): List<ByteArray> {
        response.put("displaySize", JSONArray(listOf(size.x, size.y)))
        return pending.map { (window, png) ->
            png.get(5, TimeUnit.SECONDS).also { window.put("pngBytes", it.size) }
        }
    }

    private companion object {
        val encoder = Executors.newSingleThreadExecutor { work -> Thread(work, "CompScope window PNG").apply { isDaemon = true } }
    }
}
