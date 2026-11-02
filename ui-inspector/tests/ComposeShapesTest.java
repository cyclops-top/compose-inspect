package com.android.tools.ui.inspector.inspectors.view;

import java.lang.reflect.*;
import org.json.JSONObject;

/** Runs against actual Compose classes supplied on the classpath, without changing the target app. */
public final class ComposeShapesTest {
    static final String PACKAGE = "androidx.compose.foundation.shape.";
    public static final class Coordinates {
        public long getSize() { return (200L << 32) | 100L; }
    }
    public static final class Node {
        final boolean rtl;
        Node(boolean rtl) { this.rtl = rtl; }
        public String getLayoutDirection() { return rtl ? "Rtl" : "Ltr"; }
        public Object getDensity() throws Exception {
            Class<?> type = Class.forName("androidx.compose.ui.unit.Density");
            return Proxy.newProxyInstance(type.getClassLoader(), new Class<?>[] { type },
                (proxy, method, args) -> {
                    if (method.isDefault()) return InvocationHandler.invokeDefault(proxy, method, args);
                    if (method.getName().equals("getDensity")) return 2f;
                    if (method.getName().equals("getFontScale")) return 1f;
                    throw new UnsupportedOperationException(method.toString());
                });
        }
    }
    static Object corner(String type, float value) throws Exception {
        Constructor<?> constructor = Class.forName(PACKAGE + type).getDeclaredConstructor(float.class);
        constructor.setAccessible(true);
        return constructor.newInstance(value);
    }
    static Object shape(String type, Object... corners) throws Exception {
        Class<?> corner = Class.forName(PACKAGE + "CornerSize");
        return Class.forName(PACKAGE + type).getConstructor(corner, corner, corner, corner).newInstance(corners[0], corners[1], corners[3], corners[2]);
    }
    static void equal(Object actual, Object expected) {
        if (!actual.equals(expected)) throw new AssertionError(actual + " != " + expected);
    }
    static void near(double actual, double expected) {
        if (Math.abs(actual - expected) > 0.001) throw new AssertionError(actual + " != " + expected);
    }
    public static void main(String[] args) throws Exception {
        int count = 0;
        for (String type : new String[] {"RoundedCornerShape", "CutCornerShape", "AbsoluteRoundedCornerShape", "AbsoluteCutCornerShape"}) {
            for (boolean rtl : new boolean[] {false, true}) {
                Object shape = shape(type, corner("PercentCornerSize", 25), corner("DpCornerSize", 10),
                    corner("PxCornerSize", 5), corner("PercentCornerSize", 50));
                JSONObject result = ComposeStyles.shape(shape, new Coordinates(), new Node(rtl));
                equal(result.getString("kind"), type.contains("Cut") ? "cut" : "rounded");
                boolean mirror = rtl && !type.startsWith("Absolute");
                JSONObject radii = result.getJSONObject("radiiPx"), inputs = result.getJSONObject("corners");
                near(radii.getDouble("topLeft"), mirror ? 20 : 25);
                near(radii.getDouble("topRight"), mirror ? 25 : 20);
                near(radii.getDouble("bottomLeft"), mirror ? 50 : 5);
                near(radii.getDouble("bottomRight"), mirror ? 5 : 50);
                equal(inputs.getJSONObject(mirror ? "topRight" : "topLeft").getString("unit"), "%");
                near(inputs.getJSONObject(mirror ? "topRight" : "topLeft").getDouble("value"), 25);
                Object large = corner("PercentCornerSize", 80);
                JSONObject normalized = ComposeStyles.shape(shape(type, large, large, large, large), new Coordinates(), new Node(rtl));
                near(normalized.getJSONObject("radiiPx").getDouble("topLeft"), 50);
                near(normalized.getJSONObject("corners").getJSONObject("topLeft").getDouble("value"), 80);
                count++;
            }
        }
        Object circle = Class.forName(PACKAGE + "RoundedCornerShapeKt").getMethod("getCircleShape").invoke(null);
        JSONObject result = ComposeStyles.shape(circle, new Coordinates(), new Node(false));
        near(result.getJSONObject("radiiPx").getDouble("topLeft"), 50);
        near(result.getJSONObject("corners").getJSONObject("topLeft").getDouble("value"), 50);
        equal(ComposeStyles.shape(new Object(), new Coordinates(), new Node(false)).getString("kind"), "unknown");
        System.out.println("Compose shape checks passed: " + count + " mixed-unit/direction cases, normalization, CircleShape, unknown shape");
    }
}
