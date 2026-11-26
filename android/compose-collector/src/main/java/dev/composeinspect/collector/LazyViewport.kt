package dev.composeinspect.collector

import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.grid.LazyGridState
import org.json.JSONArray
import org.json.JSONObject

/** Detach viewport metrics while the sampled composition is on its UI thread. */
internal object LazyViewport {
    private const val LIMIT = 100

    fun capture(component: String?, argument: String?, state: Any?): JSONObject? {
        if (argument != "state") return null
        val result = when {
            component in listOf("LazyColumn", "LazyRow") && state is LazyListState -> {
                val info = state.layoutInfo
                summary(info.viewportStartOffset, info.viewportEndOffset, info.orientation, info.visibleItemsInfo) {
                    item(it.index, it.key, it.offset, it.size)
                }
            }
            component in listOf("LazyVerticalGrid", "LazyHorizontalGrid") && state is LazyGridState -> {
                val info = state.layoutInfo
                val vertical = info.orientation == Orientation.Vertical
                summary(info.viewportStartOffset, info.viewportEndOffset, info.orientation, info.visibleItemsInfo) {
                    item(it.index, it.key, if (vertical) it.offset.y else it.offset.x,
                        if (vertical) it.size.height else it.size.width)
                        .put("x", it.offset.x).put("y", it.offset.y)
                        .put("width", it.size.width).put("height", it.size.height)
                }
            }
            else -> return null
        }
        return JSONObject().put("type", state.javaClass.name).put("viewport", result)
    }

    private inline fun <T> summary(start: Int, end: Int, orientation: Orientation, items: List<T>,
                                    encode: (T) -> JSONObject): JSONObject {
        val rows = JSONArray()
        for (i in 0 until minOf(items.size, LIMIT)) rows.put(encode(items[i]))
        return JSONObject().put("start", start).put("end", end).put("axis", orientation.name)
            .put("count", items.size).put("items", rows)
    }

    private fun item(index: Int, key: Any, offset: Int, size: Int): JSONObject {
        val item = JSONObject().put("index", index).put("offset", offset).put("size", size)
        when (key) {
            is Boolean, is Int, is Long, is Short, is Byte -> item.put("key", key)
            is String -> if (key.length <= 256) item.put("key", key)
        }
        return item
    }
}
