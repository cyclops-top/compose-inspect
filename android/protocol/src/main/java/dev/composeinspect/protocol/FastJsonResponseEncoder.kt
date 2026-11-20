package dev.composeinspect.protocol

import org.json.JSONArray
import org.json.JSONObject
import java.util.Collections
import java.util.IdentityHashMap

/** Production writer without per-token timing. Kept output-compatible with the diagnostic writer. */
internal object FastJsonResponseEncoder {
    // UTF-8 uses at most three bytes per UTF-16 code unit: stay below the 32 MiB wire limit.
    fun encode(root: JSONObject, maxCharacters: Int = 8 * 1024 * 1024): ByteArray {
        val output = StringBuilder()
        val active = Collections.newSetFromMap(IdentityHashMap<Any, Boolean>())
        val stack = ArrayDeque<Frame>()
        val quotedKeys = HashMap<String, String>()
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
            append(quotedKeys.getOrPut(key) { quote(key) })
        }
        fun value(value: Any?) {
            when (value) {
                null, JSONObject.NULL -> append("null")
                is JsonFields -> {
                    require(active.add(value)) { "SDK response contains a cycle" }
                    append("{")
                    val keys = value.jsonKeys
                    val frame = DtoFrame(value, keys)
                    stack.addLast(frame)
                }
                is List<*> -> {
                    require(active.add(value)) { "SDK response contains a cycle" }
                    append("[")
                    val frame = ListFrame(value)
                    stack.addLast(frame)
                }
                is JSONObject -> {
                    require(active.add(value)) { "SDK response contains a cycle" }
                    append("{")
                    val frame = ObjectFrame(value, value.keys())
                    stack.addLast(frame)
                }
                is JSONArray -> {
                    require(active.add(value)) { "SDK response contains a cycle" }
                    append("[")
                    val frame = ArrayFrame(value)
                    stack.addLast(frame)
                }
                is String -> {
                    require(value.length <= maxCharacters - output.length) { "SDK response exceeds size limit" }
                    append(quotedValues[value] ?: quote(value).also {
                        if (quotedValues.size < 4096) quotedValues[value] = it
                    })
                }
                is Boolean -> append(value.toString())
                is Number -> {
                    append(numberTokens[value] ?: JSONObject.numberToString(value).also {
                        if (numberTokens.size < 4096) numberTokens[value] = it
                    })
                }
                else -> error("Unsupported SDK JSON value: ${value.javaClass.name}")
            }
        }
        value(root)
        while (stack.isNotEmpty()) {
            val frame = stack.last()
            when (frame) {
                is DtoFrame -> if (frame.index < frame.keys.size) {
                    val index = frame.index++
                    if (!frame.value.includeJsonField(index)) continue
                    if (frame.started) append(",")
                    frame.started = true
                    run {
                        val key = frame.keys[index]
                        require(key.length <= maxCharacters - output.length) { "SDK response exceeds size limit" }
                        append(quotedKeys.getOrPut(key) { quote(key) })
                        append(":")
                    }
                    value(frame.value.jsonValue(index))
                } else {
                    append("}")
                    active.remove(frame.value)
                    stack.removeLast()
                }
                is ListFrame -> if (frame.index < frame.value.size) {
                    if (frame.index > 0) append(",")
                    value(frame.value[frame.index++])
                } else {
                    append("]")
                    active.remove(frame.value)
                    stack.removeLast()
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
                }
                is ArrayFrame -> if (frame.index < frame.value.length()) {
                    if (frame.index > 0) append(",")
                    value(frame.value.get(frame.index++))
                } else {
                    append("]")
                    active.remove(frame.value)
                    stack.removeLast()
                }
            }
        }
        append("\n")
        val text = output.toString()
        val bytes = text.toByteArray(Charsets.UTF_8)
        return bytes
    }
    private sealed interface Frame
    private class DtoFrame(var value: JsonFields, var keys: Array<String>, var index: Int = 0, var started: Boolean = false) : Frame
    private class ListFrame(var value: List<*>, var index: Int = 0) : Frame
    private class ObjectFrame(var value: JSONObject, var keys: Iterator<String>, var started: Boolean = false) : Frame
    private class ArrayFrame(var value: JSONArray, var index: Int = 0) : Frame

}
