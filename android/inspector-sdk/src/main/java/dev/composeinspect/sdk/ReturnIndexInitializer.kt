package dev.composeinspect.sdk

import android.app.Activity
import android.content.Context
import android.util.Log
import androidx.core.view.OneShotPreDrawListener
import androidx.startup.Initializer
import dev.composeinspect.collector.ComposableReturns
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async

/** AndroidX Startup owns one index per process. The socket and first draw share its deferred result. */
internal class ReturnIndexInitializer : Initializer<ReturnIndex> {
    override fun create(context: Context) = ReturnIndex(context.applicationContext)
    override fun dependencies(): List<Class<out Initializer<*>>> = emptyList()
}

internal class ReturnIndex(app: Context) {
    private val start = CompletableDeferred<Unit>()
    private val result = CoroutineScope(Dispatchers.IO).async {
        start.await()
        try {
            val info = app.applicationInfo
            val paths = listOf(info.sourceDir) + info.splitSourceDirs.orEmpty()
            ComposableReturns.fromInstalledApks(app, paths)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.w("ComposeInspect", "Cannot resolve composable return signatures", e)
            ComposableReturns.empty
        }
    }

    fun afterDraw(activity: Activity) {
        if (start.isCompleted) return
        val view = activity.window.decorView
        OneShotPreDrawListener.add(view) { view.post { start.complete(Unit) } }
    }

    suspend fun await(): ComposableReturns {
        start.complete(Unit)
        return result.await()
    }
}
