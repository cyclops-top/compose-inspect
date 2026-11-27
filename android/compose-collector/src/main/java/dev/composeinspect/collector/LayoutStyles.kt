package dev.composeinspect.collector

import androidx.compose.ui.platform.InspectableValue
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.*
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import android.view.View
import androidx.compose.ui.layout.LayoutCoordinates
import java.lang.reflect.Field
import java.lang.reflect.Method
import java.util.Collections
import java.util.IdentityHashMap
import org.json.JSONArray
import org.json.JSONObject

/** Capture-local adapter for measured Compose modifier layers. Mirrors the desktop style schema. */
class LayoutStyles internal constructor() {
    private val methods = mutableMapOf<Class<*>, Array<Method>>()
    private val resolvedMethods = mutableMapOf<Class<*>, MutableMap<Pair<String, Int>, Method?>>()
    private val fields = mutableMapOf<Class<*>, MutableMap<String, Field?>>()
    private val measuredBounds = IdentityHashMap<Any, JSONObject>()
    private val argbColors = mutableMapOf<Class<*>, MutableMap<Long, String>>()

    companion object {
        private val cornerNames = listOf("topStart", "topEnd", "bottomStart", "bottomEnd")
        private val physicalCorners = listOf("topLeft", "topRight", "bottomLeft", "bottomRight")
        private val cornerShapes = setOf("RoundedCornerShape", "AbsoluteRoundedCornerShape",
            "CutCornerShape", "AbsoluteCutCornerShape")

        private fun isRectangle(name: String) = name == "androidx.compose.ui.graphics.RectangleShape" ||
            name.startsWith("androidx.compose.ui.graphics.RectangleShapeKt\$RectangleShape\$")

        @JvmStatic fun capture(view: View): JSONObject? = capture(view, null)

        internal fun capture(view: View, included: Set<Any>?): JSONObject? =
            if (view.javaClass.name.endsWith("AndroidComposeView")) LayoutStyles().captureView(view, included) else null

        @JvmStatic fun shape(shape: Any, coords: Any, node: Any): JSONObject =
            LayoutStyles().readShape(shape, coords, node)
    }

    fun encodeShape(shape: Any): JSONObject? {
        val name = shape.javaClass.name
        if (isRectangle(name)) return JSONObject().put("type", name).put("value", "RectangleShape")
        if (!name.startsWith("androidx.compose.foundation.shape.") || shape.javaClass.simpleName !in cornerShapes) return null
        val values = JSONArray()
        for (key in cornerNames) {
            val corner = call(shape, "get" + key.replaceFirstChar { it.uppercaseChar() })
            val encoded = JSONObject().put("type", corner.javaClass.name)
            val configuration = cornerConfiguration(corner)
            if (configuration != null) encoded.put("value", configuration)
            else encoded.put("opaque", true).put("reason", "custom CornerSize")
            values.put(JSONObject().put("name", key).put("value", encoded))
        }
        return JSONObject().put("type", name).put("fields", values)
    }

    private fun captureView(view: View, included: Set<Any>?): JSONObject {
        val result = JSONObject()
        try {
            result.put("version", 1).put("density", view.resources.displayMetrics.density.toDouble())
            val screen = IntArray(2).also(view::getLocationOnScreen)
            val window = IntArray(2).also(view::getLocationInWindow)
            val records = JSONArray()
            val errors = JSONArray()
            visit(call(view, "getRoot"), screen[0] - window[0], screen[1] - window[1],
                records, errors, Collections.newSetFromMap(IdentityHashMap()), included)
            result.put("records", records).put("diagnostics", errors)
        } catch (failure: Throwable) {
            result.put("error", failure.toString())
        }
        return result
    }

    private fun visit(node: Any?, dx: Int, dy: Int, records: JSONArray, errors: JSONArray, visited: MutableSet<Any>, included: Set<Any>?) {
        if (node == null || !visited.add(node)) return
        if (included == null || node in included) try {
            val coordinates = call(node, "getCoordinates")
            if (call(coordinates, "isAttached") == true) {
                val record = JSONObject().put("layoutIdentity", System.identityHashCode(node))
                    .put("density", number(call(call(node, "getDensity"), "getDensity")))
                    .put("contentBounds", bounds(coordinates, dx, dy))
                    .put("outerBounds", bounds(call(node, "getOuterCoordinator"), dx, dy))
                val layers = JSONArray()
                val infos = call(node, "getModifierInfo")
                if (infos is Iterable<*>) {
                    for (info in infos) {
                        val modifier = call(info!!, "getModifier")
                        layer(modifier, call(info, "getCoordinates"), node, dx, dy)?.let { layers.put(it) }
                    }
                }
                records.put(record.put("layers", layers))
            }
        } catch (failure: Throwable) {
            if (errors.length() < 8) errors.put(failure.toString())
        }
        val children = call(node, "getChildren")
        val list = children as? Iterable<*> ?: call(children, "asMutableList") as? Iterable<*>
        list?.forEach { visit(it, dx, dy, records, errors, visited, included) }
    }

    private fun layer(modifier: Any, coords: Any, node: Any, dx: Int, dy: Int): JSONObject? {
        val name = modifier.javaClass.name
        val simple = modifier.javaClass.simpleName
        val layout = name.startsWith("androidx.compose.foundation.layout.")
        val kind = when {
            layout && (simple == "PaddingElement" || simple == "PaddingValuesElement") -> "padding"
            name == "androidx.compose.ui.draw.ShadowGraphicsLayerElement" -> "shadow"
            name == "androidx.compose.foundation.BackgroundElement" -> "background"
            name == "androidx.compose.ui.graphics.GraphicsLayerElement" -> "graphicsLayer"
            name.startsWith("androidx.compose.ui.graphics.") && optionalField(modifier, "clip") == true -> "clip"
            simple.contains("Padding") || name.contains("Draw") || name.contains("GraphicsLayer") -> "unsupported"
            else -> return null
        }
        val layer = JSONObject().put("name", name).put("bounds", bounds(coords, dx, dy)).put("kind", kind)
        when (kind) {
            "padding" -> {
                val direction = call(node, "getLayoutDirection")
                val padding = if (simple == "PaddingElement") {
                    val swap = direction.toString() == "Rtl" && field(modifier, "rtlAware") != false
                    val start = number(field(modifier, "start"))
                    val end = number(field(modifier, "end"))
                    JSONObject().put("left", if (swap) end else start)
                        .put("top", number(field(modifier, "top")))
                        .put("right", if (swap) start else end)
                        .put("bottom", number(field(modifier, "bottom")))
                } else {
                    val values = field(modifier, "paddingValues")!!
                    JSONObject().put("left", number(call(values, "calculateLeftPadding", direction)))
                        .put("top", number(call(values, "calculateTopPadding")))
                        .put("right", number(call(values, "calculateRightPadding", direction)))
                        .put("bottom", number(call(values, "calculateBottomPadding")))
                }
                layer.put("padding", padding)
            }
            "background" -> {
                val color = field(modifier, "color")
                val brush = optionalField(modifier, "brush")
                if (brush != null) layer.put("unsupported", "未知的 brush: " + brush.javaClass.name)
                else {
                    layer.put("argb", argb(modifier, color as Number)).put("alpha", number(field(modifier, "alpha")))
                }
                layer.put("shape", readShape(field(modifier, "shape")!!, coords, node))
            }
            "shadow" -> {
                val shadow = JSONObject()
                (optionalField(modifier, "elevation") as? Number)?.toDouble()?.takeIf { it.isFinite() }?.let {
                    shadow.put("elevationDp", it)
                }
                shadow.put("clip", optionalField(modifier, "clip") as? Boolean)
                for (key in listOf("ambientColor", "spotColor")) {
                    (optionalField(modifier, key) as? Number)?.let { shadow.put(key, argb(modifier, it)) }
                }
                layer.put("shadow", shadow)
                optionalField(modifier, "shape")?.let { layer.put("shape", readShape(it, coords, node)) }
            }
            "graphicsLayer" -> {
                val parameters = JSONArray()
                var shape: Shape? = null
                var clipped = false
                var elevated = false
                for ((key, value) in (modifier as InspectableValue).inspectableElements) {
                    if (value == null) continue
                    if (key == "shape") {
                        shape = value as? Shape
                        continue
                    }
                    if (key == "clip") clipped = value == true
                    if (key == "shadowElevation") elevated = (value as? Number)?.toFloat()?.let { it > 0 } == true
                    val display = when (value) {
                        is Color -> "#" + argb(modifier, value.value.toLong())
                        is TransformOrigin -> "${value.pivotFractionX}, ${value.pivotFractionY}"
                        is Number, is Boolean, is BlendMode -> value.toString()
                        is CompositingStrategy -> when (value) {
                            CompositingStrategy.Auto -> "Auto"
                            CompositingStrategy.Offscreen -> "Offscreen"
                            CompositingStrategy.ModulateAlpha -> "ModulateAlpha"
                            else -> value.toString()
                        }
                        else -> if (key == "outsets") value.toString() else value.javaClass.name
                    }
                    parameters.put(JSONObject().put("name", key).put("value", display))
                }
                layer.put("graphicsParameters", parameters)
                if (clipped) layer.put("kind", "clip")
                if (clipped || elevated) shape?.let { layer.put("shape", readShape(it, coords, node)) }
            }
            "clip" -> layer.put("shape", readShape(field(modifier, "shape")!!, coords, node))
            else -> layer.put("unsupported", if (simple.contains("Padding")) "未解析的 padding: $name" else "未解析的绘制: $name")
        }
        return layer
    }

    private fun argb(modifier: Any, color: Number): String {
        val packed = color.toLong()
        val colors = argbColors.getOrPut(modifier.javaClass) { mutableMapOf() }
        return colors.getOrPut(packed) {
            val type = Class.forName("androidx.compose.ui.graphics.ColorKt", false, modifier.javaClass.classLoader)
            val value = method(type, "toArgb", 1).invoke(null, packed) as Number
            Integer.toHexString(value.toInt()).uppercase().padStart(8, '0')
        }
    }

    private fun readShape(shape: Any, coords: Any, node: Any): JSONObject {
        val name = shape.javaClass.name
        val result = JSONObject().put("name", name).put("kind", "unknown")
        if (isRectangle(name)) return result.put("kind", "rectangle")
        val simple = name.substringAfterLast('.')
        if (shape !is Shape) return result
        val density = call(node, "getDensity")
        val size = (call(coords, "getSize") as Number).toLong()
        val width = (size shr 32).toInt().toFloat()
        val height = size.toInt().toFloat()
        if (!name.startsWith("androidx.compose.foundation.shape.") || simple !in cornerShapes) {
            if (width <= 0 || height <= 0) return result
            try {
                val outline = shape.createOutline(Size(width, height), call(node, "getLayoutDirection") as LayoutDirection, density as Density)
                val path = if (outline is Outline.Generic) outline.path else Path().apply { addOutline(outline) }
                val commands = JSONArray()
                val iterator = PathIterator(path)
                val points = FloatArray(8)
                while (iterator.hasNext()) {
                    val type = iterator.next(points)
                    val indices = when (type) {
                        PathSegment.Type.Move -> 0..1
                        PathSegment.Type.Line -> 2..3
                        PathSegment.Type.Quadratic -> 2..5
                        PathSegment.Type.Cubic -> 2..7
                        PathSegment.Type.Close -> IntRange.EMPTY
                        PathSegment.Type.Done -> break
                        PathSegment.Type.Conic -> return result
                    }
                    if (commands.length() >= 16384) return result
                    val command = JSONArray().put(type.name)
                    for (i in indices) command.put((points[i] / if (i % 2 == 0) width else height).toDouble())
                    commands.put(command)
                }
                return result.put("commands", commands).put("evenOdd", path.fillType == PathFillType.EvenOdd).put("kind", "path")
            } catch (_: Exception) { return result }
        }
        val floatSize = pack(width, height)
        val rtl = !simple.startsWith("Absolute") && call(node, "getLayoutDirection").toString() == "Rtl"
        val corners = cornerNames.map { call(shape, "get" + it.replaceFirstChar { c -> c.uppercaseChar() }) }
        val radii = corners.map { number(call(it, "toPx", floatSize, density)) }.toMutableList()
        // Compose scales each start/end pair against the shortest side.
        for (top in 0..1) {
            val sum = radii[top] + radii[top + 2]
            val scale = if (sum == 0.0) 1.0 else minOf(1.0, minOf(width, height) / sum)
            radii[top] = radii[top] * scale
            radii[top + 2] = radii[top + 2] * scale
        }
        val configuration = JSONObject()
        val pixels = JSONObject()
        for ((index, key) in physicalCorners.withIndex()) {
            val source = if (rtl) index xor 1 else index
            cornerConfiguration(corners[source])?.let { configuration.put(key, it) }
            pixels.put(key, radii[source])
        }
        return result.put("corners", configuration)
            .put("kind", if (simple.contains("Cut")) "cut" else "rounded").put("radiiPx", pixels)
    }

    private fun cornerConfiguration(corner: Any): JSONObject? {
        val unit = when (corner.javaClass.name) {
            "androidx.compose.foundation.shape.DpCornerSize" -> "dp"
            "androidx.compose.foundation.shape.PxCornerSize" -> "px"
            "androidx.compose.foundation.shape.PercentCornerSize" -> "%"
            else -> return null
        }
        val value = optionalField(corner, if (unit == "%") "percent" else "size") as? Number ?: return null
        val number = value.toDouble()
        if (!number.isFinite() || number < 0) return null
        return JSONObject().put("value", number).put("unit", unit)
    }

    private fun number(value: Any?) = (value as Number).toDouble()
    private fun pack(x: Float, y: Float) =
        (x.toRawBits().toLong() shl 32) or (y.toRawBits().toLong() and 0xffffffffL)

    private fun bounds(coords: Any, dx: Int, dy: Int): JSONObject = measuredBounds.getOrPut(coords) {
        val size = if (coords is LayoutCoordinates) CoordinateAccess.size(coords)
            else (call(coords, "getSize") as Number).toLong()
        val width = (size shr 32).toInt().toFloat()
        val height = size.toInt().toFloat()
        var minX = Double.POSITIVE_INFINITY
        var minY = Double.POSITIVE_INFINITY
        var maxX = Double.NEGATIVE_INFINITY
        var maxY = Double.NEGATIVE_INFINITY
        for (point in longArrayOf(pack(0f, 0f), pack(width, 0f), pack(width, height), pack(0f, height))) {
            val window = if (coords is LayoutCoordinates) CoordinateAccess.localToWindow(coords, point)
                else (call(coords, "localToWindow", point) as Number).toLong()
            val x = (Float.fromBits((window shr 32).toInt()) + dx).toDouble()
            val y = (Float.fromBits(window.toInt()) + dy).toDouble()
            minX = minOf(minX, x)
            minY = minOf(minY, y)
            maxX = maxOf(maxX, x)
            maxY = maxOf(maxY, y)
        }
        JSONObject().put("x", Math.round(minX)).put("y", Math.round(minY))
            .put("width", Math.round(maxX) - Math.round(minX))
            .put("height", Math.round(maxY) - Math.round(minY))
    }

    private fun optionalField(target: Any, name: String): Any? = try {
        field(target, name)
    } catch (_: Exception) {
        null
    }

    private fun field(target: Any, name: String): Any? {
        val cache = fields.getOrPut(target.javaClass) { mutableMapOf() }
        if (name !in cache) {
            var type: Class<*>? = target.javaClass
            var found: Field? = null
            while (type != null) {
                try {
                    found = type.getDeclaredField(name).apply { isAccessible = true }
                    break
                } catch (_: NoSuchFieldException) {
                    type = type.superclass
                }
            }
            cache[name] = found
        }
        val field = cache[name] ?: throw NoSuchFieldException("${target.javaClass.name}.$name")
        return field.get(target)
    }

    private fun call(target: Any, name: String, vararg args: Any): Any =
        method(target.javaClass, name, args.size).invoke(target, *args)!!

    private fun method(type: Class<*>, name: String, arity: Int): Method {
        val cache = resolvedMethods.getOrPut(type) { mutableMapOf() }
        val key = name to arity
        if (key !in cache) {
            val candidates = methods.getOrPut(type) { type.methods }
            cache[key] = candidates.firstOrNull {
                (it.name == name || it.name.startsWith("$name-") || it.name.startsWith("$name\$")) &&
                    it.parameterTypes.size == arity
            }?.apply { isAccessible = true }
        }
        return cache[key] ?: throw NoSuchMethodException("${type.name}.$name")
    }
}
