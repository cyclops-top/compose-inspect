package dev.composeinspect.research

import dev.composeinspect.protocol.JsonFields
import dev.composeinspect.protocol.JsonResponseEncoder
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream

// Research only. Probe inputs are complete detached, bounded snapshots, on a large-stack worker.
private const val INTEGER = -7
private val punctuation = intArrayOf(0, 123, 125, 91, 93, 58, 44, 0, 10)

private class IntBuffer {
    var data = IntArray(1024)
    var size = 0
    fun add(value: Int) {
        if (size == data.size) data = data.copyOf(size * 2)
        data[size++] = value
    }
}

private interface Writer {
    fun symbol(tag: Int)
    fun integer(value: Int)
    fun text(token: String)
}

private class Direct(val fixedNodes: Boolean = false) : Writer {
    val output = ByteArrayOutputStream()
    private val dictionary = HashMap<String, ByteArray>()
    override fun symbol(tag: Int) = output.write(punctuation[-tag])
    override fun integer(value: Int) = output.write(value.toString().toByteArray())
    override fun text(token: String) = output.write(dictionary.getOrPut(token) { token.toByteArray() })
}

private class Plan(val fixedNodes: Boolean = false) : Writer {
    val words = IntBuffer()
    val offsets = IntBuffer().apply { add(0) }
    val utf8 = ByteArrayOutputStream()
    private val ids = HashMap<String, Int>()
    override fun symbol(tag: Int) = words.add(tag)
    override fun integer(value: Int) { words.add(INTEGER); words.add(value) }
    override fun text(token: String) {
        words.add(tokenId(token))
    }
    fun tokenId(token: String): Int = ids.getOrPut(token) {
            utf8.write(token.toByteArray())
            offsets.add(utf8.size())
            offsets.size - 2
    }
}

private fun visit(root: JSONObject, writer: Writer) {
    val quoted = HashMap<String, String>()
    fun quote(s: String) = quoted.getOrPut(s) {
        if (s.all { it >= ' ' && it != '"' && it != '\\' && it != '/' }) "\"" + s + "\"" else JSONObject.quote(s)
    }
    fun string(s: String) = writer.text(quote(s))
    fun value(v: Any?) {
        when (v) {
            null, JSONObject.NULL -> writer.text("null")
            is Int -> writer.integer(v)
            is Number -> writer.text(JSONObject.numberToString(v))
            is Boolean -> writer.text(v.toString())
            is String -> string(v)
            is JsonFields -> {
                if (writer is Direct && writer.fixedNodes && v.jsonKeys.size == 8 && v.jsonKeys[7] == "children") {
                    writer.text("{\"name\":"); value(v.jsonValue(0))
                    writer.text(",\"kind\":"); value(v.jsonValue(1))
                    writer.text(",\"inline\":"); value(v.jsonValue(2))
                    writer.text(",\"sourceInfo\":"); value(v.jsonValue(3))
                    writer.text(",\"boundsInWindow\":"); value(v.jsonValue(4))
                    if (v.includeJsonField(5)) { writer.text(",\"source\":"); value(v.jsonValue(5)) }
                    check((v.jsonValue(6) as List<*>).isEmpty())
                    writer.text(",\"parameters\":[],\"children\":"); value(v.jsonValue(7))
                    writer.symbol(-2)
                    return
                }
                if (writer is Plan && writer.fixedNodes && v.jsonKeys.size == 8 && v.jsonKeys[7] == "children") {
                    // Header produced in Kotlin field order. C++ or Kotlin emits the fixed JSON keys.
                    val words = writer.words
                    fun token(text: String?) = writer.tokenId(text?.let(::quote) ?: "null")
                    words.add(-9)
                    words.add(token(v.jsonValue(0) as String?))
                    words.add(token(v.jsonValue(1) as String))
                    words.add(if (v.jsonValue(2) == true) 1 else 0)
                    words.add(token(v.jsonValue(3) as String?))
                    for (bound in v.jsonValue(4) as List<*>) words.add(bound as Int)
                    val source = v.jsonValue(5) as? JsonFields
                    words.add(if (source == null) 0 else 1)
                    if (source != null) {
                        words.add(if (source.includeJsonField(0)) token(source.jsonValue(0) as String) else -1)
                        for (i in 1..4) words.add(source.jsonValue(i) as Int)
                    }
                    check((v.jsonValue(6) as List<*>).isEmpty())
                    value(v.jsonValue(7))
                    writer.symbol(-2)
                    return
                }
                writer.symbol(-1)
                var first = true
                for (i in v.jsonKeys.indices) if (v.includeJsonField(i)) {
                    if (!first) writer.symbol(-6)
                    first = false
                    string(v.jsonKeys[i]); writer.symbol(-5); value(v.jsonValue(i))
                }
                writer.symbol(-2)
            }
            is JSONObject -> {
                writer.symbol(-1)
                val keys = v.keys()
                while (keys.hasNext()) {
                    val k = keys.next()
                    string(k); writer.symbol(-5); value(v.get(k))
                    if (keys.hasNext()) writer.symbol(-6)
                }
                writer.symbol(-2)
            }
            is JSONArray -> {
                writer.symbol(-3)
                for (i in 0 until v.length()) { if (i > 0) writer.symbol(-6); value(v.get(i)) }
                writer.symbol(-4)
            }
            is List<*> -> {
                writer.symbol(-3)
                for (i in v.indices) { if (i > 0) writer.symbol(-6); value(v[i]) }
                writer.symbol(-4)
            }
            else -> error("Unsupported field: ${v.javaClass}")
        }
    }
    value(root)
    writer.symbol(-8)
}

private fun replay(words: IntArray, offsets: IntArray, utf8: ByteArray): ByteArray {
    val output = ByteArrayOutputStream()
    val literals = HashMap<String, ByteArray>()
    fun literal(s: String) = output.write(literals.getOrPut(s) { s.toByteArray() })
    fun token(id: Int) = output.write(utf8, offsets[id], offsets[id + 1] - offsets[id])
    fun number(n: Int) = output.write(n.toString().toByteArray())
    var i = 0
    while (i < words.size) {
        val tag = words[i++]
        when {
            tag == -9 -> {
                literal("{\"name\":"); token(words[i++])
                literal(",\"kind\":"); token(words[i++])
                literal(if (words[i++] == 1) ",\"inline\":true" else ",\"inline\":false")
                literal(",\"sourceInfo\":"); token(words[i++])
                literal(",\"boundsInWindow\":["); number(words[i++])
                repeat(3) { output.write(44); number(words[i++]) }
                output.write(93)
                if (words[i++] == 1) {
                    literal(",\"source\":{")
                    val file = words[i++]
                    if (file >= 0) { literal("\"file\":"); token(file); output.write(44) }
                    literal("\"line\":"); number(words[i++])
                    literal(",\"offset\":"); number(words[i++])
                    literal(",\"length\":"); number(words[i++])
                    literal(",\"packageHash\":"); number(words[i++]); output.write(125)
                }
                literal(",\"parameters\":[],\"children\":")
            }
            tag == INTEGER -> number(words[i++])
            tag < 0 -> output.write(punctuation[-tag])
            else -> output.write(utf8, offsets[tag], offsets[tag + 1] - offsets[tag])
        }
    }
    return output.toByteArray()
}

object ResearchEncoder {
    private object Native {
        init { System.loadLibrary("treebench") }
        external fun encode(words: IntArray, offsets: IntArray, utf8: ByteArray): ByteArray
    }

    fun encode(snapshot: JSONObject, mode: Int, packed: (() -> Unit)? = null): ByteArray = when (mode) {
        0 -> JsonResponseEncoder.encode(snapshot)
        1, 6 -> Direct(fixedNodes = mode == 6).let { writer ->
            visit(snapshot, writer)
            writer.output.toByteArray()
        }
        in 2..5 -> {
            val plan = Plan(fixedNodes = mode >= 4)
            visit(snapshot, plan)
            val words = plan.words.data.copyOf(plan.words.size)
            val offsets = plan.offsets.data.copyOf(plan.offsets.size)
            val utf8 = plan.utf8.toByteArray()
            packed?.invoke()
            if (mode % 2 == 0) replay(words, offsets, utf8) else Native.encode(words, offsets, utf8)
        }
        else -> error("Invalid benchmark mode")
    }
}
