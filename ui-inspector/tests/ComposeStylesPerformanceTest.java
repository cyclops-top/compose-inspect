package com.android.tools.ui.inspector.inspectors.view;

import java.lang.reflect.*;
import org.json.JSONObject;

/** Behavioral regressions: skip irrelevant coordinates and never cache mutable values. */
public final class ComposeStylesPerformanceTest {
    public static final class IrrelevantModifier {}
    public static final class DrawModifier {}
    public static final class Coordinates {
        int calls;
        public long getSize() { calls++; return (20L << 32) | 10L; }
        public long localToWindow(long point) { calls++; return point; }
    }
    public static class Parent { private int value = 1; }
    public static final class Child extends Parent {
        int current = 2;
        public int getValue$test() { return current; }
    }
    public static void main(String[] args) throws Exception {
        Constructor<?> constructor = ComposeStyles.class.getDeclaredConstructor();
        constructor.setAccessible(true);
        Object adapter = constructor.newInstance();
        Method layer = ComposeStyles.class.getDeclaredMethod("layer", Object.class, Object.class, Object.class, int.class, int.class);
        layer.setAccessible(true);
        Coordinates coords = new Coordinates();
        if (layer.invoke(adapter, new IrrelevantModifier(), coords, null, 0, 0) != null || coords.calls != 0)
            throw new AssertionError("Irrelevant modifier performed coordinate work");
        JSONObject result = (JSONObject) layer.invoke(adapter, new DrawModifier(), coords, null, 0, 0);
        if (!result.getString("kind").equals("unsupported") || coords.calls != 5)
            throw new AssertionError("Supported diagnostic layer lost its geometry");
        Method call = ComposeStyles.class.getDeclaredMethod("call", Object.class, String.class, Object[].class);
        call.setAccessible(true);
        Child target = new Child();
        if (!call.invoke(adapter, target, "getValue", new Object[0]).equals(2)) throw new AssertionError();
        target.current = 3;
        if (!call.invoke(adapter, target, "getValue", new Object[0]).equals(3)) throw new AssertionError("Cached mutable method value");
        Method field = ComposeStyles.class.getDeclaredMethod("field", Object.class, String.class);
        field.setAccessible(true);
        if (!field.invoke(adapter, target, "value").equals(1)) throw new AssertionError();
        Field value = Parent.class.getDeclaredField("value"); value.setAccessible(true); value.set(target, 4);
        if (!field.invoke(adapter, target, "value").equals(4)) throw new AssertionError("Cached mutable field value");
        for (int i = 0; i < 2; i++) {
            try { field.invoke(adapter, target, "missing"); throw new AssertionError(); }
            catch (InvocationTargetException expected) {
                if (!(expected.getCause() instanceof NoSuchFieldException)) throw expected;
            }
        }
        System.out.println("Compose style performance regressions passed");
    }
}
