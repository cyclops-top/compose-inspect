package dev.composeinspect.collector

import dev.composeinspect.protocol.Protocol
import org.json.JSONObject
import java.lang.reflect.Modifier
import java.util.Collections
import java.util.IdentityHashMap
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.TextUnitType
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.style.TextDecoration

/** Bounded field inspection, no arbitrary getters or user toString calls. */
class ValueEncoder {
    // One encoder per capture: reuse reflection metadata, never retain application values.
    private val fieldsByClass = HashMap<Class<*>, List<java.lang.reflect.Field>>()
    private val styles = LayoutStyles()
    internal fun encodeCaptured(value: Any?): Any {
        val type = value?.javaClass?.name ?: "null"
        return when (value) {
            null -> ScalarValueDto(type, null)
            is String -> ScalarValueDto(type, value.take(2048), value.length > 2048)
            is Boolean, is Byte, is Short, is Int, is Long -> ScalarValueDto(type, value)
            is Float -> ScalarValueDto(type, if (value.isFinite()) value else value.toString())
            is Double -> ScalarValueDto(type, if (value.isFinite()) value else value.toString())
            is Char -> ScalarValueDto(type, value.toString())
            is Enum<*> -> ScalarValueDto(type, value.name)
            is Function<*> -> OpaqueValueDto(type, "function")
            else -> encode(value)
        }
    }

    fun encode(value: Any?): JSONObject = encode(value, 0, Collections.newSetFromMap(IdentityHashMap()))

    private fun encode(value: Any?, depth: Int, seen: MutableSet<Any>): JSONObject {
        val result = JSONObject().put("type", value?.javaClass?.name ?: "null")
        if (value == null) return result.put("value", JSONObject.NULL)
        when (value) {
            is String -> return result.put("value", value.take(2048)).put("truncated", value.length > 2048)
            is Boolean, is Byte, is Short, is Int, is Long -> return result.put("value", value)
            is Float -> return result.put("value", if (value.isFinite()) value else value.toString())
            is Double -> return result.put("value", if (value.isFinite()) value else value.toString())
            is Char -> return result.put("value", value.toString())
            is Enum<*> -> return result.put("value", value.name)
            is Function<*> -> return result.put("opaque", true).put("reason", "function")
            is Color -> return if (value == Color.Unspecified) result.put("opaque", true).put("reason", "unspecified Color")
                else result.put("value", "#%08X".format(java.util.Locale.ROOT, value.toArgb()))
            is TextUnit -> return if (value.type == TextUnitType.Unspecified || !value.value.isFinite())
                result.put("opaque", true).put("reason", "unspecified TextUnit")
                else result.put("value", JSONObject().put("value", value.value)
                    .put("unit", if (value.type == TextUnitType.Sp) "sp" else "em"))
            is FontWeight -> return result.put("value", value.weight)
            is FontStyle -> return result.put("value", value.toString())
            is TextAlign -> return result.put("value", value.toString())
            is TextOverflow -> return result.put("value", value.toString())
            is TextDecoration -> return result.put("value", value.toString())
            is Dp -> return if (!value.value.isFinite()) result.put("opaque", true).put("reason", "non-finite Dp")
                else result.put("value", JSONObject().put("value", value.value).put("unit", "dp"))
        }
        if (depth >= 3) return result.put("truncated", true).put("reason", "depth limit")
        if (!seen.add(value)) return result.put("truncated", true).put("reason", "cycle")
        try {
            styles.encodeShape(value)?.let { return it }
            fun fields(vararg values: Pair<String, Any?>): JSONObject = result.put("fields", Protocol.array(values.map {
                JSONObject().put("name", it.first).put("value", encode(it.second, depth + 1, seen))
            }))
            when (value) {
                is TextStyle -> return fields(
                    "color" to value.color, "fontSize" to value.fontSize,
                    "fontWeight" to value.fontWeight, "fontStyle" to value.fontStyle,
                    "fontFamily" to value.fontFamily, "letterSpacing" to value.letterSpacing,
                    "lineHeight" to value.lineHeight, "textAlign" to value.textAlign,
                    "background" to value.background, "textDecoration" to value.textDecoration)
                is SpanStyle -> return fields(
                    "color" to value.color, "fontSize" to value.fontSize,
                    "fontWeight" to value.fontWeight, "fontStyle" to value.fontStyle,
                    "fontFamily" to value.fontFamily, "letterSpacing" to value.letterSpacing,
                    "background" to value.background, "textDecoration" to value.textDecoration)
                is FontFamily -> {
                    val name = when (value) {
                        FontFamily.Default -> "Default"
                        FontFamily.SansSerif -> "SansSerif"
                        FontFamily.Serif -> "Serif"
                        FontFamily.Monospace -> "Monospace"
                        FontFamily.Cursive -> "Cursive"
                        else -> null
                    }
                    return if (name != null) result.put("value", name)
                        else result.put("opaque", true).put("reason", "custom font family")
                }
            }
            when (value) {
                is List<*> -> result.put("items", Protocol.array(value.take(20).map { encode(it, depth + 1, seen) }))
                    .put("size", value.size).put("truncated", value.size > 20)
                is Map<*, *> -> result.put("entries", Protocol.array(value.entries.take(20).map {
                    JSONObject().put("key", encode(it.key, depth + 1, seen)).put("value", encode(it.value, depth + 1, seen))
                })).put("size", value.size).put("truncated", value.size > 20)
                else -> {
                    // Android and Compose internals require dedicated semantic renderers.
                    if (value.javaClass.name.startsWith("android.") || value.javaClass.name.startsWith("androidx.") || value.javaClass.name.startsWith("java.")) {
                        result.put("opaque", true).put("reason", "no type adapter")
                    } else {
                        val fields = fieldsByClass.getOrPut(value.javaClass) {
                            value.javaClass.declaredFields.filter { !Modifier.isStatic(it.modifiers) && !it.isSynthetic }
                        }
                        result.put("fields", Protocol.array(fields.take(20).map { field ->
                            JSONObject().put("name", field.name).put("value", try {
                                if (!field.isAccessible) field.isAccessible = true
                                encode(field.get(value), depth + 1, seen)
                            } catch (e: Exception) { JSONObject().put("opaque", true).put("reason", e.javaClass.simpleName) })
                        })).put("truncated", fields.size > 20)
                    }
                }
            }
        } catch (e: Exception) { result.put("opaque", true).put("reason", e.javaClass.simpleName) }
        finally { seen.remove(value) }
        return result
    }
}
