package dev.composeinspect.collector

import org.junit.Assert.*
import org.junit.Test
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.em

class ValueEncoderTest {
    @Test fun textStyleKeepsUnitsColorAndWeight() {
        val style = androidx.compose.ui.text.TextStyle(
            color = androidx.compose.ui.graphics.Color.Red,
            fontSize = 18.sp,
            fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
            lineHeight = 24.sp,
            letterSpacing = 0.1.em)
        val fields = ValueEncoder().encode(style).getJSONArray("fields")
        fun value(name: String) = (0 until fields.length()).map { fields.getJSONObject(it) }
            .first { it.getString("name") == name }.getJSONObject("value").get("value")
        assertEquals("#FFFF0000", value("color"))
        assertEquals(700, value("fontWeight"))
        assertEquals("sp", (value("fontSize") as org.json.JSONObject).getString("unit"))
        assertEquals(18.0, (value("fontSize") as org.json.JSONObject).getDouble("value"), 0.0)
        assertEquals("em", (value("letterSpacing") as org.json.JSONObject).getString("unit"))
    }

    private class Value(var text: String, var next: Value? = null)

    @Test fun reusedReflectionMetadataStillReadsCurrentValues() {
        val encoder = ValueEncoder()
        val value = Value("before")
        fun text() = encoder.encode(value).getJSONArray("fields").let { fields ->
            (0 until fields.length()).map { fields.getJSONObject(it) }.first { it.getString("name") == "text" }
                .getJSONObject("value").getString("value")
        }
        assertEquals("before", text())
        value.text = "after"
        assertEquals("after", text())
        assertTrue(encoder.encode(Value("other")).toString().contains("other"))
    }

    @Test fun cachedFieldsDoNotSuppressCycleDetectionOrRetainVisitedValues() {
        val encoder = ValueEncoder()
        val value = Value("cycle")
        value.next = value
        assertTrue(encoder.encode(value).toString().contains("cycle"))
        assertTrue(encoder.encode(value).toString().contains("\"truncated\":true"))
        value.next = null
        assertFalse(encoder.encode(value).toString().contains("\"truncated\":true"))
    }
}
