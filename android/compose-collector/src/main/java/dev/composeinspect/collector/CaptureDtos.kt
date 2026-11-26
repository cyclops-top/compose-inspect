package dev.composeinspect.collector

import dev.composeinspect.protocol.JsonFields
import org.json.JSONObject

// All values are detached during main-thread collection. Never store tooling/UI objects here.
internal data class SourceDto(val file: String?, val line: Int, val offset: Int, val length: Int, val packageHash: Int) : JsonFields {
    override val jsonKeys get() = KEYS
    override fun jsonValue(index: Int): Any? = when (index) {
        0 -> file
        1 -> line
        2 -> offset
        3 -> length
        4 -> packageHash
        else -> error("Invalid JSON field index")
    }
    override fun includeJsonField(index: Int): Boolean = when (index) {
        0 -> file != null
        else -> true
    }
    companion object { private val KEYS = arrayOf("file", "line", "offset", "length", "packageHash") }
}
internal data class ParameterDto(val name: String?, val value: Any, val inlineClass: String?,
    val fromDefault: Boolean, val static: Boolean, val compared: Boolean, val stable: Boolean,
    val forwardsContent: Boolean? = null) : JsonFields {
    override val jsonKeys get() = KEYS
    override fun jsonValue(index: Int): Any? = when (index) {
        0 -> name
        1 -> value
        2 -> inlineClass
        3 -> fromDefault
        4 -> static
        5 -> compared
        6 -> stable
        7 -> forwardsContent
        else -> error("Invalid JSON field index")
    }
    override fun includeJsonField(index: Int): Boolean = when (index) {
        0 -> name != null
        7 -> forwardsContent != null
        else -> true
    }
    companion object { private val KEYS = arrayOf("name", "value", "inlineClass", "fromDefault", "static", "compared", "stable", "forwardsContent") }
}
internal data class NodeDto(val name: String?, val kind: String, val inline: Boolean, val sourceInfo: String?,
    val boundsInWindow: List<Int>, val source: SourceDto?, val children: List<NodeDto>,
    val layoutIdentity: Int? = null, val interaction: JSONObject? = null, val interactionError: String? = null,
    val parameters: List<ParameterDto> = emptyList()) : JsonFields {
    override val jsonKeys get() = KEYS
    override fun jsonValue(index: Int): Any? = when (index) {
        0 -> name
        1 -> kind
        2 -> layoutIdentity
        3 -> interaction
        4 -> interactionError
        5 -> inline
        6 -> sourceInfo
        7 -> boundsInWindow
        8 -> source
        9 -> parameters
        10 -> children
        else -> error("Invalid JSON field index")
    }
    override fun includeJsonField(index: Int): Boolean = when (index) {
        2 -> layoutIdentity != null
        3 -> interaction != null
        4 -> interactionError != null
        8 -> source != null
        else -> true
    }
    companion object { private val KEYS = arrayOf("name", "kind", "layoutIdentity", "interaction", "interactionError", "inline", "sourceInfo", "boundsInWindow", "source", "parameters", "children") }
}

/** Detached scalar value; null value and omitted flags remain distinct on the wire. */
internal data class ScalarValueDto(val type: String, val value: Any?, val truncated: Boolean? = null) : JsonFields {
    override val jsonKeys get() = KEYS
    override fun jsonValue(index: Int): Any? = when (index) {
        0 -> type; 1 -> value; 2 -> truncated; else -> error("Invalid JSON field index")
    }
    override fun includeJsonField(index: Int) = index != 2 || truncated != null
    companion object { private val KEYS = arrayOf("type", "value", "truncated") }
}
internal data class OpaqueValueDto(val type: String, val reason: String) : JsonFields {
    override val jsonKeys get() = KEYS
    override fun jsonValue(index: Int): Any = when (index) {
        0 -> type; 1 -> true; 2 -> reason; else -> error("Invalid JSON field index")
    }
    companion object { private val KEYS = arrayOf("type", "opaque", "reason") }
}
