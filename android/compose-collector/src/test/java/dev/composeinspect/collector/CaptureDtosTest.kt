package dev.composeinspect.collector

import dev.composeinspect.protocol.JsonResponseEncoder
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CaptureDtosTest {
    @Test fun pooledFramesMatchFreshFramesForMixedSiblingsAndDeepTrees() {
        val leaf = NodeDto(null, "call", null, null, null, false, null, listOf(1, 2, 3, 4), null, emptyList(), emptyList())
        var deep = leaf
        repeat(2000) { deep = leaf.copy(children = listOf(deep)) }
        val root = JSONObject().put("nodes", listOf(leaf, deep, leaf.copy(name = "last")))
            .put("mixed", org.json.JSONArray().put(JSONObject().put("a", true)).put(JSONObject().put("b", false)))
        assertArrayEquals(JsonResponseEncoder.encode(root), JsonResponseEncoder.encode(root, reuseFrames = true))
        assertThrows(IllegalArgumentException::class.java) { JsonResponseEncoder.encode(root, 100, reuseFrames = true) }
        val cycle = mutableListOf<Any>()
        cycle.add(cycle)
        assertThrows(IllegalArgumentException::class.java) {
            JsonResponseEncoder.encode(JSONObject().put("cycle", cycle), reuseFrames = true)
        }
    }

    @Test fun scalarDtosMatchOriginalEncoder() {
        val encoder = ValueEncoder()
        val values = listOf(null, "", "quote\"\n", "中😀".repeat(800), true, 1.toByte(), 2.toShort(),
            Int.MIN_VALUE, Long.MAX_VALUE, -0.0f, Float.NaN, Double.POSITIVE_INFINITY, '中', { 1 })
        for (value in values) {
            val old = JSONObject(String(JsonResponseEncoder.encode(JSONObject().put("v", encoder.encode(value)))))
            val current = JSONObject(String(JsonResponseEncoder.encode(JSONObject().put("v", encoder.encodeCaptured(value)))))
            val a = old.getJSONObject("v")
            val b = current.getJSONObject("v")
            assertEquals(a.keys().asSequence().toSet(), b.keys().asSequence().toSet())
            a.keys().forEach { key -> assertEquals(a.get(key), b.get(key)) }
        }
    }

    @Test fun preservesNullsOmissionsAndParameterFlags() {
        val node = NodeDto(null, "call", null, null, null, false, null, listOf(-1, 2, 3, 4), null,
            listOf(ParameterDto("a", JSONObject().put("value", "quote\"\n"), null, true, false, true, false)), emptyList())
        val decoded = JSONObject(String(JsonResponseEncoder.encode(JSONObject().put("node", node)))).getJSONObject("node")
        assertTrue(decoded.has("name")); assertTrue(decoded.isNull("name"))
        assertTrue(decoded.isNull("sourceInfo")); assertFalse(decoded.has("source"))
        assertFalse(decoded.has("layoutIdentity")); assertFalse(decoded.has("interaction"))
        assertEquals(-1, decoded.getJSONArray("boundsInWindow").getInt(0))
        val parameter = decoded.getJSONArray("parameters").getJSONObject(0)
        assertTrue(parameter.has("inlineClass")); assertTrue(parameter.isNull("inlineClass"))
        assertTrue(parameter.getBoolean("fromDefault")); assertFalse(parameter.getBoolean("static"))
        assertEquals("quote\"\n", parameter.getJSONObject("value").getString("value"))
    }
    @Test fun deepDtoTreeUsesIterativeWriterAndHonorsLimit() {
        var node = NodeDto("leaf", "call", null, null, null, false, null, emptyList(), null, emptyList(), emptyList())
        repeat(2000) { node = node.copy(name = "parent", children = listOf(node)) }
        val root = JSONObject().put("node", node)
        val bytes = JsonResponseEncoder.encode(root)
        assertTrue(bytes.size > 2000)
        assertThrows(IllegalArgumentException::class.java) { JsonResponseEncoder.encode(root, 100) }
    }
}
