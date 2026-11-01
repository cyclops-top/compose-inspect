package com.android.tools.ui.inspector.inspectors.view;

import android.view.View;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.Collections;
import java.util.IdentityHashMap;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

/** Optional, version-tolerant Compose tooling adapter. No Compose classes are linked into the agent. */
final class ComposeStyles {
    static final String ATTRIBUTE = "composeinspect.styleLayers.v1";
    private ComposeStyles() {}

    static String capture(View view) {
        if (!view.getClass().getName().endsWith("AndroidComposeView")) return null;
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

    private static void visit(Object node, int dx, int dy, JSONArray records, JSONArray errors,
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

    private static JSONObject layer(Object modifier, Object coords, Object node, int dx, int dy) throws Exception {
        String name = modifier.getClass().getName();
        String simple = modifier.getClass().getSimpleName();
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
            layer.put("shape", shape(field(modifier, "shape"), coords, node));
        } else if (name.startsWith("androidx.compose.ui.graphics.") && Boolean.TRUE.equals(optionalField(modifier, "clip"))) {
            layer.put("kind", "clip");
            layer.put("shape", shape(field(modifier, "shape"), coords, node));
        } else if (simple.contains("Padding")) {
            layer.put("kind", "unsupported");
            layer.put("unsupported", "未解析的 padding: " + name);
        } else if (name.contains("Draw") || name.contains("GraphicsLayer")) {
            layer.put("kind", "unsupported");
            layer.put("unsupported", "未解析的绘制: " + name);
        } else return null;
        return layer;
    }

    private static JSONObject shape(Object shape, Object coords, Object node) throws Exception {
        String name = shape.getClass().getName();
        JSONObject result = new JSONObject().put("name", name).put("kind", "unknown");
        if (name.equals("androidx.compose.ui.graphics.RectangleShape")
                || name.startsWith("androidx.compose.ui.graphics.RectangleShapeKt$RectangleShape$"))
            return result.put("kind", "rectangle");
        if (!name.equals("androidx.compose.foundation.shape.RoundedCornerShape")) return result;
        Object density = call(node, "getDensity");
        long size = ((Number) call(coords, "getSize")).longValue();
        float width = (int) (size >> 32), height = (int) size;
        long floatSize = pack(width, height);
        boolean rtl = String.valueOf(call(node, "getLayoutDirection")).equals("Rtl");
        double ts = number(call(call(shape, "getTopStart"), "toPx", floatSize, density));
        double te = number(call(call(shape, "getTopEnd"), "toPx", floatSize, density));
        double bs = number(call(call(shape, "getBottomStart"), "toPx", floatSize, density));
        double be = number(call(call(shape, "getBottomEnd"), "toPx", floatSize, density));
        // CornerBasedShape normalizes each start/end pair against the minimum dimension.
        double startScale = Math.min(1, ratio(Math.min(width, height), ts + bs));
        double endScale = Math.min(1, ratio(Math.min(width, height), te + be));
        ts *= startScale; bs *= startScale; te *= endScale; be *= endScale;
        return result.put("kind", "rounded").put("radiiPx", new JSONObject()
                .put("topLeft", (rtl ? te : ts)).put("topRight", (rtl ? ts : te))
                .put("bottomLeft", (rtl ? be : bs)).put("bottomRight", (rtl ? bs : be)));
    }
    private static double ratio(double size, double sum) { return sum == 0 ? 1 : size / sum; }
    private static double number(Object value) { return ((Number) value).doubleValue(); }
    private static long pack(float x, float y) {
        return ((long) Float.floatToRawIntBits(x) << 32) | (Float.floatToRawIntBits(y) & 0xffffffffL);
    }
    private static JSONObject bounds(Object coords, int dx, int dy) throws Exception {
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
    private static Object optionalField(Object target, String name) {
        try { return field(target, name); } catch (Exception ignored) { return null; }
    }
    private static Object field(Object target, String name) throws Exception {
        for (Class<?> cls = target.getClass(); cls != null; cls = cls.getSuperclass()) {
            try { Field f = cls.getDeclaredField(name); f.setAccessible(true); return f.get(target); }
            catch (NoSuchFieldException ignored) { }
        }
        throw new NoSuchFieldException(target.getClass().getName() + "." + name);
    }
    private static Object call(Object target, String name, Object... args) throws Exception {
        return invoke(target.getClass(), target, name, args);
    }
    private static Object staticCall(Class<?> cls, String name, Object... args) throws Exception {
        return invoke(cls, null, name, args);
    }
    private static Object invoke(Class<?> cls, Object target, String name, Object... args) throws Exception {
        for (Method m : cls.getMethods()) {
            String actual = m.getName();
            if ((actual.equals(name) || actual.startsWith(name + "-") || actual.startsWith(name + "$"))
                    && m.getParameterTypes().length == args.length) {
                m.setAccessible(true);
                return m.invoke(target, args);
            }
        }
        throw new NoSuchMethodException(cls.getName() + "." + name);
    }
}
