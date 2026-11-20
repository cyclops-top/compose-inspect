package dev.composeinspect.protocol

import org.json.JSONArray
import org.json.JSONObject
import java.util.Collections
import java.util.IdentityHashMap

/** Fixed DTOs expose fields only while the background encoder visits them. */
interface JsonFields {
    val jsonKeys: Array<String>
    fun jsonValue(index: Int): Any?
    fun includeJsonField(index: Int): Boolean = true
}

/** Iterative encoding avoids org.json's recursive writer overflowing on deep Compose trees. */
object JsonResponseEncoder {
    class Metrics {
        var stringNanos = 0L; var numberNanos = 0L; var keyNanos = 0L
        var textNanos = 0L; var utf8Nanos = 0L; var totalNanos = 0L
        var strings = 0; var numbers = 0; var keys = 0
        var containerEntryNanos = 0L
        val frameNanos = LongArray(4)
        val frameSteps = IntArray(4)
        fun tokenNanos() = stringNanos + numberNanos + keyNanos + containerEntryNanos
        override fun toString() = "totalMs=${totalNanos / 1e6} stringsMs=${stringNanos / 1e6} numbersMs=${numberNanos / 1e6} keysMs=${keyNanos / 1e6} " +
            "toStringMs=${textNanos / 1e6} utf8Ms=${utf8Nanos / 1e6} traversalOtherMs=${(totalNanos-stringNanos-numberNanos-keyNanos-textNanos-utf8Nanos) / 1e6} strings=$strings numbers=$numbers keys=$keys " +
            "containerEntryMs=${containerEntryNanos / 1e6} dtoFrameMs=${frameNanos[0] / 1e6} listFrameMs=${frameNanos[1] / 1e6} " +
            "objectFrameMs=${frameNanos[2] / 1e6} arrayFrameMs=${frameNanos[3] / 1e6} frameSteps=${frameSteps.joinToString(",")}"
    }
    // UTF-8 uses at most three bytes per UTF-16 code unit: stay below the 32 MiB wire limit.
    fun encode(root: JSONObject, maxCharacters: Int = 8 * 1024 * 1024, metrics: Metrics? = null, optimizedDtoKeys: Boolean = false, reuseFrames: Boolean = false, diagnosticPath: Boolean = false): ByteArray {
        if (metrics == null && !optimizedDtoKeys && !reuseFrames && !diagnosticPath) return FastJsonResponseEncoder.encode(root, maxCharacters)
        val totalStarted = if (metrics != null) System.nanoTime() else 0L
        val output = StringBuilder()
        val active = Collections.newSetFromMap(IdentityHashMap<Any, Boolean>())
        val stack = ArrayDeque<Frame>()
        // Per-encoding pools: at most the maximum simultaneously active depth per frame type.
        val dtoFrames = ArrayDeque<DtoFrame>()
        val listFrames = ArrayDeque<ListFrame>()
        val objectFrames = ArrayDeque<ObjectFrame>()
        val arrayFrames = ArrayDeque<ArrayFrame>()
        val quotedKeys = HashMap<String, String>()
        val dtoKeys = IdentityHashMap<Array<String>, Array<String>>()
        val quotedValues = HashMap<String, String>()
        val numberTokens = HashMap<Number, String>()
        fun quote(text: String): String {
            // Most SDK strings are class/field names. Avoid JSONStringer allocation per token.
            return if (text.all { it >= ' ' && it != '"' && it != '\\' && it != '/' }) "\"$text\""
            else JSONObject.quote(text)
        }
        fun append(text: String) {
            require(text.length <= maxCharacters - output.length) { "SDK response exceeds size limit" }
            output.append(text)
        }
        fun keyToken(key: String) {
            val started = if (metrics != null) System.nanoTime() else 0L
            append(quotedKeys.getOrPut(key) { quote(key) })
            if (metrics != null) { metrics.keyNanos += System.nanoTime() - started; metrics.keys++ }
        }
        fun value(value: Any?) {
            when (value) {
                null, JSONObject.NULL -> append("null")
                is JsonFields -> {
                    val started = if (metrics != null) System.nanoTime() else 0L
                    require(active.add(value)) { "SDK response contains a cycle" }
                    append("{")
                    val keys = value.jsonKeys
                    val tokens = if (!optimizedDtoKeys) keys else dtoKeys[keys] ?: Array(keys.size) { index ->
                        val key = keys[index]
                        require(key.length <= maxCharacters) { "SDK response exceeds size limit" }
                        quote(key) + ":"
                    }.also { dtoKeys[keys] = it }
                    val frame = if (reuseFrames && dtoFrames.isNotEmpty()) dtoFrames.removeLast().apply {
                        this.value = value; this.keys = tokens; index = 0; this.started = false
                    } else DtoFrame(value, tokens)
                    stack.addLast(frame)
                    if (metrics != null) metrics.containerEntryNanos += System.nanoTime() - started
                }
                is List<*> -> {
                    val started = if (metrics != null) System.nanoTime() else 0L
                    require(active.add(value)) { "SDK response contains a cycle" }
                    append("[")
                    val frame = if (reuseFrames && listFrames.isNotEmpty()) listFrames.removeLast().apply {
                        this.value = value; index = 0
                    } else ListFrame(value)
                    stack.addLast(frame)
                    if (metrics != null) metrics.containerEntryNanos += System.nanoTime() - started
                }
                is JSONObject -> {
                    val started = if (metrics != null) System.nanoTime() else 0L
                    require(active.add(value)) { "SDK response contains a cycle" }
                    append("{")
                    val frame = if (reuseFrames && objectFrames.isNotEmpty()) objectFrames.removeLast().apply {
                        this.value = value; keys = value.keys(); this.started = false
                    } else ObjectFrame(value, value.keys())
                    stack.addLast(frame)
                    if (metrics != null) metrics.containerEntryNanos += System.nanoTime() - started
                }
                is JSONArray -> {
                    val started = if (metrics != null) System.nanoTime() else 0L
                    require(active.add(value)) { "SDK response contains a cycle" }
                    append("[")
                    val frame = if (reuseFrames && arrayFrames.isNotEmpty()) arrayFrames.removeLast().apply {
                        this.value = value; index = 0
                    } else ArrayFrame(value)
                    stack.addLast(frame)
                    if (metrics != null) metrics.containerEntryNanos += System.nanoTime() - started
                }
                is String -> {
                    val started = if (metrics != null) System.nanoTime() else 0L
                    require(value.length <= maxCharacters - output.length) { "SDK response exceeds size limit" }
                    append(quotedValues[value] ?: quote(value).also {
                        if (quotedValues.size < 4096) quotedValues[value] = it
                    })
                    if (metrics != null) { metrics.stringNanos += System.nanoTime() - started; metrics.strings++ }
                }
                is Boolean -> append(value.toString())
                is Number -> {
                    val started = if (metrics != null) System.nanoTime() else 0L
                    append(numberTokens[value] ?: JSONObject.numberToString(value).also {
                        if (numberTokens.size < 4096) numberTokens[value] = it
                    })
                    if (metrics != null) { metrics.numberNanos += System.nanoTime() - started; metrics.numbers++ }
                }
                else -> error("Unsupported SDK JSON value: ${value.javaClass.name}")
            }
        }
        value(root)
        while (stack.isNotEmpty()) {
            val frame = stack.last()
            val frameStarted = if (metrics != null) System.nanoTime() else 0L
            val tokensBefore = metrics?.tokenNanos() ?: 0L
            try {
            when (frame) {
                is DtoFrame -> if (frame.index < frame.keys.size) {
                    val index = frame.index++
                    if (!frame.value.includeJsonField(index)) continue
                    if (frame.started) append(",")
                    frame.started = true
                    val keyStarted = if (metrics != null) System.nanoTime() else 0L
                    if (optimizedDtoKeys) append(frame.keys[index])
                    else {
                        val key = frame.keys[index]
                        require(key.length <= maxCharacters - output.length) { "SDK response exceeds size limit" }
                        append(quotedKeys.getOrPut(key) { quote(key) })
                        append(":")
                    }
                    if (metrics != null) { metrics.keyNanos += System.nanoTime() - keyStarted; metrics.keys++ }
                    value(frame.value.jsonValue(index))
                } else {
                    append("}")
                    active.remove(frame.value)
                    stack.removeLast()
                    if (reuseFrames) dtoFrames.addLast(frame)
                }
                is ListFrame -> if (frame.index < frame.value.size) {
                    if (frame.index > 0) append(",")
                    value(frame.value[frame.index++])
                } else {
                    append("]")
                    active.remove(frame.value)
                    stack.removeLast()
                    if (reuseFrames) listFrames.addLast(frame)
                }
                is ObjectFrame -> if (frame.keys.hasNext()) {
                    if (frame.started) append(",")
                    frame.started = true
                    val key = frame.keys.next()
                    require(key.length <= maxCharacters - output.length) { "SDK response exceeds size limit" }
                    keyToken(key)
                    append(":")
                    value(frame.value.get(key))
                } else {
                    append("}")
                    active.remove(frame.value)
                    stack.removeLast()
                    if (reuseFrames) objectFrames.addLast(frame)
                }
                is ArrayFrame -> if (frame.index < frame.value.length()) {
                    if (frame.index > 0) append(",")
                    value(frame.value.get(frame.index++))
                } else {
                    append("]")
                    active.remove(frame.value)
                    stack.removeLast()
                    if (reuseFrames) arrayFrames.addLast(frame)
                }
            }
            } finally {
                if (metrics != null) {
                    val kind = when (frame) { is DtoFrame -> 0; is ListFrame -> 1; is ObjectFrame -> 2; is ArrayFrame -> 3 }
                    metrics.frameNanos[kind] += System.nanoTime() - frameStarted - (metrics.tokenNanos() - tokensBefore)
                    metrics.frameSteps[kind]++
                }
            }
        }
        append("\n")
        val textStarted = if (metrics != null) System.nanoTime() else 0L
        val text = output.toString()
        val utf8Started = if (metrics != null) System.nanoTime() else 0L
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (metrics != null) {
            val finished = System.nanoTime()
            metrics.textNanos = utf8Started - textStarted
            metrics.utf8Nanos = finished - utf8Started
            metrics.totalNanos = finished - totalStarted
        }
        return bytes
    }

    private sealed interface Frame
    private class DtoFrame(var value: JsonFields, var keys: Array<String>, var index: Int = 0, var started: Boolean = false) : Frame
    private class ListFrame(var value: List<*>, var index: Int = 0) : Frame
    private class ObjectFrame(var value: JSONObject, var keys: Iterator<String>, var started: Boolean = false) : Frame
    private class ArrayFrame(var value: JSONArray, var index: Int = 0) : Frame
}
