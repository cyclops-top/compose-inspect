package dev.composeinspect.collector

import dev.composeinspect.protocol.JsonFields

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

internal data class NodeDto(val name: String?, val kind: String, val inline: Boolean, val sourceInfo: String?,
    val boundsInWindow: List<Int>, val source: SourceDto?, val children: List<NodeDto>) : JsonFields {
    override val jsonKeys get() = KEYS
    override fun jsonValue(index: Int): Any? = when (index) {
        0 -> name
        1 -> kind
        2 -> inline
        3 -> sourceInfo
        4 -> boundsInWindow
        5 -> source
        6 -> emptyList<Any>() // Required by existing snapshot readers.
        7 -> children
        else -> error("Invalid JSON field index")
    }
    override fun includeJsonField(index: Int) = index != 5 || source != null
    companion object {
        private val KEYS = arrayOf("name", "kind", "inline", "sourceInfo", "boundsInWindow", "source", "parameters", "children")
    }
}
