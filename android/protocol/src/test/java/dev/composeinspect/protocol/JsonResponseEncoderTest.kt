package dev.composeinspect.protocol

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class JsonResponseEncoderTest {
    @Test fun encodesDeepTreeWithoutUsingCallStack() {
        var node = JSONObject().put("leaf", true)
        repeat(10000) { node = JSONObject().put("children", JSONArray().put(node)) }
        val expected = "{\"children\":[".repeat(10000) + "{\"leaf\":true}" + "]}".repeat(10000) + "\n"
        assertEquals(expected, JsonResponseEncoder.encode(node).toString(Charsets.UTF_8))
    }

    @Test fun preservesValuesEscapingAndSharedObjects() {
        val shared = JSONObject().put("text", "中文\n\"\\😀")
        val input = JSONObject().put("values", JSONArray().put(shared).put(shared)
            .put(JSONObject.NULL).put(true).put(9007199254740993L).put(1.25))
        val encoded = JsonResponseEncoder.encode(input).toString(Charsets.UTF_8)
        assertEquals(input.toString(), JSONObject(encoded).toString())
        assertTrue(encoded.endsWith("\n"))
        assertEquals(1, encoded.count { it == '\n' })
    }

    @Test fun rejectsCycleInsteadOfHanging() {
        val objectValue = JSONObject()
        val children = JSONArray().put(objectValue)
        objectValue.put("children", children)
        assertThrows(IllegalArgumentException::class.java) { JsonResponseEncoder.encode(objectValue) }
    }

    @Test fun enforcesCompleteFrameSizeIncludingNewline() {
        val input = JSONObject().put("value", "x".repeat(100))
        assertThrows(IllegalArgumentException::class.java) { JsonResponseEncoder.encode(input, 50) }
        assertEquals("{}\n", JsonResponseEncoder.encode(JSONObject(), 3).toString(Charsets.UTF_8))
        assertThrows(IllegalArgumentException::class.java) { JsonResponseEncoder.encode(JSONObject(), 2) }
    }
}
