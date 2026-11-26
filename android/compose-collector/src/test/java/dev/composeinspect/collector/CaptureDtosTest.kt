package dev.composeinspect.collector

import dev.composeinspect.protocol.JsonResponseEncoder
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CaptureDtosTest {
    @Test fun pooledFramesMatchFreshFramesForMixedSiblingsAndDeepTrees() {
        val leaf = NodeDto(null, "call", false, null, listOf(1, 2, 3, 4), null, emptyList())
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

    @Test fun deepDtoTreeUsesIterativeWriterAndHonorsLimit() {
        var node = NodeDto("leaf", "call", false, null, emptyList(), null, emptyList())
        repeat(2000) { node = node.copy(name = "parent", children = listOf(node)) }
        val root = JSONObject().put("node", node)
        val bytes = JsonResponseEncoder.encode(root)
        assertTrue(bytes.size > 2000)
        assertThrows(IllegalArgumentException::class.java) { JsonResponseEncoder.encode(root, 100) }
    }
}
