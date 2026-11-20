package com.android.tools.ui.inspector.inspectors.view;

import android.view.View;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

/** Optional, version-tolerant Compose tooling adapter. No Compose classes are linked into the agent. */
final class ComposeStyles {
    static final String ATTRIBUTE = "composeinspect.styleLayers.v1";
    // Capture-local metadata only: never retain app classes or mutable layout values across dumps.
    private final Map<Class<?>, Method[]> methods = new HashMap<>();
    private final Map<Class<?>, Map<String, Method>> resolvedMethods = new HashMap<>();
    private final Map<Class<?>, Map<String, Field>> fields = new HashMap<>();
    private ComposeStyles() {}

    static String capture(View view) {
        if (!view.getClass().getName().endsWith("AndroidComposeView")) return null;
        return new ComposeStyles().captureView(view);
    }

    private String captureView(View view) {
        JSONObject result = new JSONObject();
        JSONArray records = new JSONArray();
        JSONArray errors = new JSONArray();
        try {
            result.put("version", 1);
            result.put("density", view.getResources().getDisplayMetrics().density);
            int[] screen = new int[2];
            int[] window = new int[2];
            view.getLocationOnScreen(screen);
            view.getLocationInWindow(window);
            Object root = call(view, "getRoot");
            visit(root, screen[0] - window[0], screen[1] - window[1], records, errors,
                    Collections.newSetFromMap(new IdentityHashMap<>()));
            result.put("records", records);
            result.put("diagnostics", errors);
        } catch (Throwable failure) {
            try { result.put("error", failure.toString()); } catch (Exception ignored) { }
        }
        return result.toString();
    }

    private void visit(Object node, int dx, int dy, JSONArray records, JSONArray errors,
            Set<Object> visited) throws Exception {
        if (node == null || !visited.add(node)) return;
        try {
            Object coordinates = call(node, "getCoordinates");
            if (Boolean.TRUE.equals(call(coordinates, "isAttached"))) {
                JSONObject record = new JSONObject();
                record.put("contentBounds", bounds(coordinates, dx, dy));
                Object outer = call(node, "getOuterCoordinator");
                record.put("outerBounds", bounds(outer, dx, dy));
                JSONArray layers = new JSONArray();
                Object infos = call(node, "getModifierInfo");
                if (infos instanceof Iterable<?>) {
                    for (Object info : (Iterable<?>) infos) {
                        Object modifier = call(info, "getModifier");
                        Object coords = call(info, "getCoordinates");
                        JSONObject layer = layer(modifier, coords, node, dx, dy);
                        if (layer != null) layers.put(layer);
                    }
                }
                record.put("layers", layers);
                records.put(record);
            }
        } catch (Throwable failure) {
            // A failed record is absent, never replaced with a guessed rectangle or style.
            if (errors.length() < 8) errors.put(failure.toString());
        }
        Object children = call(node, "getChildren");
        if (!(children instanceof Iterable<?>)) children = call(children, "asMutableList");
        if (children instanceof Iterable<?>) {
            for (Object child : (Iterable<?>) children) visit(child, dx, dy, records, errors, visited);
        }
    }

    private JSONObject layer(Object modifier, Object coords, Object node, int dx, int dy) throws Exception {
        String name = modifier.getClass().getName();
        String simple = modifier.getClass().getSimpleName();
        // Reject irrelevant modifiers before any coordinate reflection or JSON allocation.
        boolean padding = name.startsWith("androidx.compose.foundation.layout.")
                && (simple.equals("PaddingElement") || simple.equals("PaddingValuesElement"));
        boolean background = name.equals("androidx.compose.foundation.BackgroundElement");
        boolean clip = name.startsWith("androidx.compose.ui.graphics.")
                && Boolean.TRUE.equals(optionalField(modifier, "clip"));
        if (!padding && !background && !clip && !simple.contains("Padding")
                && !name.contains("Draw") && !name.contains("GraphicsLayer")) return null;
        JSONObject layer = new JSONObject();
        layer.put("name", name);
        layer.put("bounds", bounds(coords, dx, dy));
        if (name.startsWith("androidx.compose.foundation.layout.") && simple.equals("PaddingElement")) {
            layer.put("kind", "padding");
            boolean rtl = String.valueOf(call(node, "getLayoutDirection")).equals("Rtl");
            boolean relative = !Boolean.FALSE.equals(field(modifier, "rtlAware"));
            double start = number(field(modifier, "start"));
            double end = number(field(modifier, "end"));
            layer.put("padding", new JSONObject().put("left", rtl && relative ? end : start)
                    .put("top", number(field(modifier, "top")))
                    .put("right", rtl && relative ? start : end)
                    .put("bottom", number(field(modifier, "bottom"))));
        } else if (name.startsWith("androidx.compose.foundation.layout.") && simple.equals("PaddingValuesElement")) {
            layer.put("kind", "padding");
            Object values = field(modifier, "paddingValues");
            Object direction = call(node, "getLayoutDirection");
            layer.put("padding", new JSONObject()
                    .put("left", number(call(values, "calculateLeftPadding", direction)))
                    .put("top", number(call(values, "calculateTopPadding")))
                    .put("right", number(call(values, "calculateRightPadding", direction)))
                    .put("bottom", number(call(values, "calculateBottomPadding"))));
        } else if (name.equals("androidx.compose.foundation.BackgroundElement")) {
            layer.put("kind", "background");
            Object color = field(modifier, "color");
            Object brush = optionalField(modifier, "brush");
            if (brush != null) layer.put("unsupported", "未知的 brush: " + brush.getClass().getName());
            else {
                long packed = ((Number) color).longValue();
                Class<?> colorKt = Class.forName("androidx.compose.ui.graphics.ColorKt", false, modifier.getClass().getClassLoader());
                int argb = ((Number) staticCall(colorKt, "toArgb", packed)).intValue();
                layer.put("argb", String.format(java.util.Locale.ROOT, "%08X", argb));
                layer.put("alpha", number(field(modifier, "alpha")));
            }
            layer.put("shape", readShape(field(modifier, "shape"), coords, node));
        } else if (clip) {
            layer.put("kind", "clip");
            layer.put("shape", readShape(field(modifier, "shape"), coords, node));
        } else if (simple.contains("Padding")) {
            layer.put("kind", "unsupported");
            layer.put("unsupported", "未解析的 padding: " + name);
        } else if (name.contains("Draw") || name.contains("GraphicsLayer")) {
            layer.put("kind", "unsupported");
            layer.put("unsupported", "未解析的绘制: " + name);
        } else return null;
        return layer;
    }

    static JSONObject shape(Object shape, Object coords, Object node) throws Exception {
        return new ComposeStyles().readShape(shape, coords, node);
    }

    private JSONObject readShape(Object shape, Object coords, Object node) throws Exception {
        String name = shape.getClass().getName();
        JSONObject result = new JSONObject().put("name", name).put("kind", "unknown");
        if (name.equals("androidx.compose.ui.graphics.RectangleShape")
                || name.startsWith("androidx.compose.ui.graphics.RectangleShapeKt$RectangleShape$"))
            return result.put("kind", "rectangle");
        String simple = name.substring(name.lastIndexOf('.') + 1);
        if (!name.startsWith("androidx.compose.foundation.shape.")
                || !(simple.equals("RoundedCornerShape") || simple.equals("AbsoluteRoundedCornerShape")
                || simple.equals("CutCornerShape") || simple.equals("AbsoluteCutCornerShape"))) return result;
        Object density = call(node, "getDensity");
        long size = ((Number) call(coords, "getSize")).longValue();
        float width = (int) (size >> 32), height = (int) size;
        long floatSize = pack(width, height);
        boolean rtl = !simple.startsWith("Absolute") && String.valueOf(call(node, "getLayoutDirection")).equals("Rtl");
        double ts = number(call(call(shape, "getTopStart"), "toPx", floatSize, density));
        double te = number(call(call(shape, "getTopEnd"), "toPx", floatSize, density));
        double bs = number(call(call(shape, "getBottomStart"), "toPx", floatSize, density));
        double be = number(call(call(shape, "getBottomEnd"), "toPx", floatSize, density));
        // CornerBasedShape normalizes each start/end pair against the minimum dimension.
        double startScale = Math.min(1, ratio(Math.min(width, height), ts + bs));
        double endScale = Math.min(1, ratio(Math.min(width, height), te + be));
        ts *= startScale; bs *= startScale; te *= endScale; be *= endScale;
        JSONObject configuration = new JSONObject();
        String[] keys = {"topLeft", "topRight", "bottomLeft", "bottomRight"};
        String[] getters = rtl ? new String[] {"getTopEnd", "getTopStart", "getBottomEnd", "getBottomStart"}
                : new String[] {"getTopStart", "getTopEnd", "getBottomStart", "getBottomEnd"};
        for (int i = 0; i < keys.length; i++) {
            JSONObject corner = cornerConfiguration(call(shape, getters[i]));
            if (corner != null) configuration.put(keys[i], corner);
        }
        return result.put("corners", configuration)
                .put("kind", simple.contains("Cut") ? "cut" : "rounded").put("radiiPx", new JSONObject()
                .put("topLeft", (rtl ? te : ts)).put("topRight", (rtl ? ts : te))
                .put("bottomLeft", (rtl ? be : bs)).put("bottomRight", (rtl ? bs : be)));
    }
    // Original units are optional: custom CornerSize remains measured without inventing its input.
    private JSONObject cornerConfiguration(Object corner) throws Exception {
        String name = corner.getClass().getName();
        String unit, fieldName;
        if (name.equals("androidx.compose.foundation.shape.DpCornerSize")) { unit = "dp"; fieldName = "size"; }
        else if (name.equals("androidx.compose.foundation.shape.PxCornerSize")) { unit = "px"; fieldName = "size"; }
        else if (name.equals("androidx.compose.foundation.shape.PercentCornerSize")) { unit = "%"; fieldName = "percent"; }
        else return null;
        Object value = optionalField(corner, fieldName);
        if (!(value instanceof Number)) return null;
        double number = number(value);
        if (!Double.isFinite(number) || number < 0) return null;
        return new JSONObject().put("value", number).put("unit", unit);
    }
    private double ratio(double size, double sum) { return sum == 0 ? 1 : size / sum; }
    private double number(Object value) { return ((Number) value).doubleValue(); }
    private long pack(float x, float y) {
        return ((long) Float.floatToRawIntBits(x) << 32) | (Float.floatToRawIntBits(y) & 0xffffffffL);
    }
    private JSONObject bounds(Object coords, int dx, int dy) throws Exception {
        long size = ((Number) call(coords, "getSize")).longValue();
        float w = (int) (size >> 32), h = (int) size;
        double minX = Double.POSITIVE_INFINITY, minY = minX, maxX = -minX, maxY = -minX;
        for (long point : new long[] {pack(0, 0), pack(w, 0), pack(w, h), pack(0, h)}) {
            long window = ((Number) call(coords, "localToWindow", point)).longValue();
            double x = Float.intBitsToFloat((int) (window >> 32)) + dx;
            double y = Float.intBitsToFloat((int) window) + dy;
            minX = Math.min(minX, x); minY = Math.min(minY, y);
            maxX = Math.max(maxX, x); maxY = Math.max(maxY, y);
        }
        return new JSONObject().put("x", Math.round(minX)).put("y", Math.round(minY))
                .put("width", Math.round(maxX) - Math.round(minX))
                .put("height", Math.round(maxY) - Math.round(minY));
    }
    private Object optionalField(Object target, String name) {
        try { return field(target, name); } catch (Exception ignored) { return null; }
    }
    private Object field(Object target, String name) throws Exception {
        Class<?> type = target.getClass();
        Map<String, Field> cache = fields.computeIfAbsent(type, ignored -> new HashMap<>());
        if (!cache.containsKey(name)) {
            Field found = null;
            for (Class<?> cls = type; cls != null; cls = cls.getSuperclass()) {
                try { found = cls.getDeclaredField(name); found.setAccessible(true); break; }
                catch (NoSuchFieldException ignored) { }
            }
            cache.put(name, found);
        }
        Field found = cache.get(name);
        if (found == null) throw new NoSuchFieldException(type.getName() + "." + name);
        return found.get(target);
    }
    private Object call(Object target, String name, Object... args) throws Exception {
        return invoke(target.getClass(), target, name, args);
    }
    private Object staticCall(Class<?> cls, String name, Object... args) throws Exception {
        return invoke(cls, null, name, args);
    }
    private Object invoke(Class<?> cls, Object target, String name, Object... args) throws Exception {
        Map<String, Method> cache = resolvedMethods.computeIfAbsent(cls, ignored -> new HashMap<>());
        String key = name + "/" + args.length;
        if (!cache.containsKey(key)) {
            Method found = null;
            // Preserve the existing first-match and Kotlin mangled-name behavior.
            for (Method method : methods.computeIfAbsent(cls, Class::getMethods)) {
                String actual = method.getName();
                if ((actual.equals(name) || actual.startsWith(name + "-") || actual.startsWith(name + "$"))
                        && method.getParameterTypes().length == args.length) {
                    method.setAccessible(true);
                    found = method;
                    break;
                }
            }
            cache.put(key, found);
        }
        Method found = cache.get(key);
        if (found == null) throw new NoSuchMethodException(cls.getName() + "." + name);
        return found.invoke(target, args);
    }
}
