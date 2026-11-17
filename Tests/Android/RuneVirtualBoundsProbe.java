package dev.rune.probe;

import android.app.Activity;
import android.app.Instrumentation;
import android.graphics.Rect;
import android.view.View;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityNodeProvider;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import org.json.JSONArray;
import org.json.JSONObject;

/** Exercise the on-device node provider with the clipped geometry of a virtual list after a deep scroll. */
final class RuneVirtualBoundsProbe {
    static void run(Instrumentation probe, Activity host) throws Throwable {
        JSONArray nodes = new JSONArray();
        nodes.put(node(1, -1, "group", 0, 0, 200, 200));
        nodes.put(node(2, 1, "list", 0, 40, 160, -1800));
        nodes.put(node(3, 2, "group", 0, 40, 160, -1500));
        nodes.put(node(4, 3, "listitem", 12, 64, 90, 78));
        nodes.put(node(5, 2, "listitem", 14, 90, 98, 104));
        nodes.put(node(6, 3, "listitem", 12, 120, 90, 100));
        byte[] packet = new JSONObject().put("nodes", nodes).toString().getBytes(StandardCharsets.UTF_8);
        Class<?> activity = host.getClassLoader().loadClass("dev.rune.RuneActivity");
        Method update = activity.getDeclaredMethod("updateRuneSnapshot", boolean.class, byte[].class);
        Field field = activity.getDeclaredField("runeView");
        update.setAccessible(true);
        field.setAccessible(true);
        final Throwable[] failure = new Throwable[1];
        probe.runOnMainSync(() -> {
            try {
                View view = (View)field.get(host);
                int[] origin = new int[2];
                view.getLocationOnScreen(origin);
                update.invoke(host, true, packet);
                AccessibilityNodeProvider provider = view.getAccessibilityNodeProvider();
                check(provider, 1, origin, new Rect(0, 0, 200, 200), new Rect(0, 0, 200, 200));
                check(provider, 2, origin, new Rect(12, 64, 98, 104), new Rect(12, 64, 98, 104));
                check(provider, 3, origin, new Rect(12, 64, 90, 78), new Rect(0, 0, 78, 14));
                check(provider, 4, origin, new Rect(12, 64, 90, 78), new Rect(0, 0, 78, 14));
                check(provider, 5, origin, new Rect(14, 90, 98, 104), new Rect(2, 26, 86, 40));
                if (provider.createAccessibilityNodeInfo(6).isVisibleToUser())
                    throw new AssertionError("A leaf outside its ancestor clip is visible");
            } catch (Throwable t) {
                failure[0] = t;
            }
        });
        if (failure[0] != null) throw failure[0];
    }

    private static JSONObject node(int id, int parent, String role, int left, int top, int right, int bottom)
            throws Exception {
        return new JSONObject().put("id", id).put("parent", parent).put("role", role)
            .put("rect", new JSONArray().put(left).put(top).put(right).put(bottom));
    }

    private static void check(AccessibilityNodeProvider provider, int id, int[] origin,
                              Rect screen, Rect relative) {
        AccessibilityNodeInfo info = provider.createAccessibilityNodeInfo(id);
        if (info == null || !info.isVisibleToUser()) throw new AssertionError("Invisible virtual node " + id);
        screen.offset(origin[0], origin[1]);
        Rect observed = new Rect();
        info.getBoundsInScreen(observed);
        if (!observed.equals(screen))
            throw new AssertionError("Node " + id + " screen bounds " + observed + ", expected " + screen);
        info.getBoundsInParent(observed);
        if (!observed.equals(relative))
            throw new AssertionError("Node " + id + " parent bounds " + observed + ", expected " + relative);
    }
}
