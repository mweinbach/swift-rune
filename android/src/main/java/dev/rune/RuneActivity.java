package dev.rune;

import android.app.NativeActivity;
import android.content.Context;
import android.os.Bundle;
import android.util.Log;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityManager;
import android.view.accessibility.AccessibilityNodeProvider;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import java.nio.charset.StandardCharsets;
import org.json.JSONException;
import org.json.JSONObject;

/** A NativeActivity with a virtual accessibility hierarchy and a system IME connection. */
public class RuneActivity extends NativeActivity {
    private long peer;
    private RuneView runeView;
    private AccessibilityManager manager;
    private final AccessibilityManager.AccessibilityStateChangeListener observing = new AccessibilityManager.AccessibilityStateChangeListener() {
        @Override public void onAccessibilityStateChanged(boolean enabled) {
            if (runeView != null) runeAction("refresh", -1, null);
        }
    };

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        manager = (AccessibilityManager)getSystemService(ACCESSIBILITY_SERVICE);
        runeView = new RuneView(this);
        // Keep the window's NativeActivity surface and input queue. This transparent
        // sibling supplies editor/accessibility APIs while all drawing stays native.
        addContentView(runeView, new ViewGroup.LayoutParams(-1, -1));
        manager.addAccessibilityStateChangeListener(observing);
        runeAction("refresh", -1, null);
    }

    @Override protected void onDestroy() {
        if (manager != null) manager.removeAccessibilityStateChangeListener(observing);
        super.onDestroy();
        peer = 0;
    }

    // Registered at NativeActivity startup, including for apps with arbitrary Swift library names.
    private native boolean nativeRuneAction(long peer, String op, int id, byte[] json);
    final Class<?> runeHostClass() { return RuneActivity.class; }
    final void setRunePeer(long p) { peer = p; }
    final boolean isRuneReaderActive() { return runeView != null && manager != null && manager.isEnabled(); }

    final boolean runeAction(String op, int id, JSONObject args) {
        return peer != 0 && nativeRuneAction(peer, op, id, args == null ? null : args.toString().getBytes(StandardCharsets.UTF_8));
    }

    final void updateRuneSnapshot(boolean tree, byte[] bytes) {
        if (runeView == null) return;
        try {
            JSONObject data = new JSONObject(new String(bytes, StandardCharsets.UTF_8));
            if (tree) runeView.nodes.update(data); else runeView.field.update(data);
        } catch (JSONException failure) {
            Log.e("SwiftRune", "Invalid semantic snapshot", failure);
        }
    }

    static final class RuneView extends View implements RuneHostBridge {
        final RuneActivity activity;
        final RuneNodes nodes;
        final RuneField field;
        RuneView(RuneActivity context) {
            super(context);
            activity = context;
            nodes = new RuneNodes(this);
            field = new RuneField(this);
            setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_YES);
            setFocusableInTouchMode(true);
        }
        @Override public AccessibilityNodeProvider getAccessibilityNodeProvider() { return nodes; }
        @Override public boolean dispatchHoverEvent(MotionEvent ev) {
            return nodes.hover(ev) || super.dispatchHoverEvent(ev);
        }
        @Override public boolean onCheckIsTextEditor() { return field != null && field.active(); }
        @Override public InputConnection onCreateInputConnection(EditorInfo info) { return field.connect(info); }
        @Override public View hostView() { return this; }
        @Override public InputMethodManager ime() { return (InputMethodManager)getContext().getSystemService(Context.INPUT_METHOD_SERVICE); }
        @Override public boolean runeAction(String op, int id, JSONObject args) { return activity.runeAction(op, id, args); }
        @Override public boolean isRuneReaderActive() { return activity.isRuneReaderActive(); }
        @Override public boolean clearFocusOnEditorBlur() { return true; }
    }
}
