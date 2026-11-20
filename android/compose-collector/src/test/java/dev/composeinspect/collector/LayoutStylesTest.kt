package dev.composeinspect.collector

import androidx.compose.foundation.shape.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import org.junit.Assert.*
import org.junit.Test

class LayoutStylesTest {
    class MovingCoordinates(var x: Float) {
        var conversions = 0
        fun getSize(): Long = (100L shl 32) or 80L
        fun localToWindow(point: Long): Long {
            conversions++
            val px = Float.fromBits((point shr 32).toInt()) + x
            return (px.toRawBits().toLong() shl 32) or (point and 0xffffffffL)
        }
    }

    @Test fun sharedCoordinatesAreMeasuredOnceButNeverReusedAcrossCaptures() {
        val bounds = LayoutStyles::class.java.getDeclaredMethod("bounds", Any::class.java, Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
            .apply { isAccessible = true }
        val coordinates = MovingCoordinates(12f)
        val capture = LayoutStyles()
        val first = bounds.invoke(capture, coordinates, 3, 4) as org.json.JSONObject
        val second = bounds.invoke(capture, coordinates, 3, 4)
        assertSame(first, second)
        assertEquals(4, coordinates.conversions)
        assertEquals(15, first.getInt("x"))
        assertEquals(100, first.getInt("width"))
        coordinates.x = 25f
        val next = bounds.invoke(LayoutStyles(), coordinates, 3, 4) as org.json.JSONObject
        assertEquals(28, next.getInt("x"))
        assertEquals(8, coordinates.conversions)
    }

    class Coordinates {
        fun getSize(): Long = (100L shl 32) or 80L
    }
    class Node(private val direction: LayoutDirection) {
        fun getDensity() = Density(2f)
        fun getLayoutDirection() = direction
    }

    @Test fun resolvesMixedUnitsAndDirectionWithoutLosingConfiguration() {
        val shape = RoundedCornerShape(CornerSize(10.dp), CornerSize(25), CornerSize(8f), CornerSize(6.dp))
        val raw = LayoutStyles.shape(shape, Coordinates(), Node(LayoutDirection.Rtl))
        val radii = raw.getJSONObject("radiiPx")
        assertEquals(20.0, radii.getDouble("topLeft"), 0.001)
        assertEquals(20.0, radii.getDouble("topRight"), 0.001)
        assertEquals(8.0, radii.getDouble("bottomLeft"), 0.001)
        assertEquals(12.0, radii.getDouble("bottomRight"), 0.001)
        assertEquals("%", raw.getJSONObject("corners").getJSONObject("topLeft").getString("unit"))
        assertEquals("dp", raw.getJSONObject("corners").getJSONObject("topRight").getString("unit"))
    }

    @Test fun normalizesCircleAndKeepsAbsoluteCornersInRTL() {
        val circle = LayoutStyles.shape(CircleShape, Coordinates(), Node(LayoutDirection.Ltr))
        assertEquals(40.0, circle.getJSONObject("radiiPx").getDouble("topLeft"), 0.001)
        val absolute = AbsoluteCutCornerShape(topLeft = 2.dp, topRight = 6.dp, bottomRight = 10.dp, bottomLeft = 14.dp)
        val raw = LayoutStyles.shape(absolute, Coordinates(), Node(LayoutDirection.Rtl))
        assertEquals("cut", raw.getString("kind"))
        assertEquals(4.0, raw.getJSONObject("radiiPx").getDouble("topLeft"), 0.001)
        assertEquals(12.0, raw.getJSONObject("radiiPx").getDouble("topRight"), 0.001)
    }

    @Test fun shapeAndBoxedColorParametersAreInspectable() {
        val encoder = ValueEncoder()
        val shape = encoder.encode(RoundedCornerShape(12.dp))
        assertFalse(shape.optBoolean("opaque"))
        val corner = shape.getJSONArray("fields").getJSONObject(0).getJSONObject("value").getJSONObject("value")
        assertEquals(12.0, corner.getDouble("value"), 0.001)
        assertEquals("dp", corner.getString("unit"))
        assertEquals("RectangleShape", encoder.encode(RectangleShape).getString("value"))
        assertEquals("#80445566", encoder.encode(Color(0x80445566)).getString("value"))
        assertTrue(encoder.encode(Color.Unspecified).getBoolean("opaque"))
        assertTrue(encoder.encode(Dp.Unspecified).getBoolean("opaque"))
        assertEquals("unknown", LayoutStyles.shape(Any(), Coordinates(), Node(LayoutDirection.Ltr)).getString("kind"))
    }
}
