package dev.composeinspect.protocol

import org.json.JSONArray
import org.json.JSONObject

/** Newline-delimited UTF-8 JSON; one request/response per connection. */
object Protocol {
    const val VERSION = 1
    const val SDK_VERSION = "0.1.2"
    fun socketName(packageName: String) = "composeinspect.$packageName"
    fun array(values: Iterable<Any?>) = JSONArray().apply { values.forEach { put(it) } }
    fun error(message: String) = JSONObject().put("protocolVersion", VERSION).put("error", message)
}
