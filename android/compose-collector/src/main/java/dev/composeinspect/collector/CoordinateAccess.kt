package dev.composeinspect.collector

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.LayoutCoordinates

/** Typed bridge for Java; preserves the packed coordinate representation. */
internal object CoordinateAccess {
    @JvmStatic fun size(coordinates: Any): Long {
        val size = (coordinates as LayoutCoordinates).size
        return (size.width.toLong() shl 32) or (size.height.toLong() and 0xffffffffL)
    }

    @JvmStatic fun localToWindow(coordinates: Any, point: Long): Long {
        val offset = Offset(Float.fromBits((point ushr 32).toInt()), Float.fromBits(point.toInt()))
        val result = (coordinates as LayoutCoordinates).localToWindow(offset)
        return (result.x.toRawBits().toLong() shl 32) or (result.y.toRawBits().toLong() and 0xffffffffL)
    }
}
