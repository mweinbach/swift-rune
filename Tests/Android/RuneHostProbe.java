package dev.rune.probe;

import android.app.Activity;
import android.app.Instrumentation;
import android.accessibilityservice.AccessibilityServiceInfo;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Rect;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.View;
import android.view.ViewGroup;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;

/** Android instrumentation for Rune's Hello window and optional editor fixture. */
public final class RuneHostProbe extends Instrumentation {
    private Bundle args;
    @Override public void onCreate(Bundle args) { this.args = args; start(); }

    @Override public void onStart() {
        Bundle result = new Bundle();
        Activity host = null;
        int status = Activity.RESULT_CANCELED;
        try {
            getUiAutomation(1); // FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES (API 24).
            AccessibilityServiceInfo service = getUiAutomation(1).getServiceInfo();
            service.flags |= AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS;
            getUiAutomation(1).setServiceInfo(service);
            Intent launch = getTargetContext().getPackageManager().getLaunchIntentForPackage(getTargetContext().getPackageName());
            host = startActivitySync(launch);
            if ("text".equals(args.getString("mode")))
                Class.forName("dev.rune.probe.RuneTextProbe").getDeclaredMethod("run", Activity.class).invoke(null, host);
            else if ("images".equals(args.getString("mode")))
                Class.forName("dev.rune.probe.RuneImageProbe").getDeclaredMethod("run", ClassLoader.class).invoke(null, host.getClassLoader());
            else if ("editor".equals(args.getString("mode"))) testEditor(host);
            else testToggle(result);
            result.putString("stream", "PASS " + args.getString("mode", "hello") + "\n");
            status = Activity.RESULT_OK;
        } catch (Throwable failure) {
            result.putString("stream", "FAIL " + android.util.Log.getStackTraceString(failure) + "\n");
        } finally {
            if (host != null) {
                final Activity target = host;
                runOnMainSync(new Runnable() { public void run() { target.finish(); } });
            }
        }
        finish(status, result);
    }

    private AccessibilityNodeInfo find(AccessibilityNodeInfo n, String klass, String label) {
        if (n == null) return null;
        if ((klass == null || klass.equals(String.valueOf(n.getClassName()))) &&
            (label.equals(String.valueOf(n.getText())) || label.equals(String.valueOf(n.getContentDescription())))) return n;
        for (int i = 0; i < n.getChildCount(); i++) {
            AccessibilityNodeInfo child = find(n.getChild(i), klass, label);
            if (child != null) return child;
        }
        return null;
    }
    private AccessibilityNodeInfo waitNode(String klass, String label) {
        long stop = SystemClock.uptimeMillis() + 16000;
        do {
            AccessibilityNodeInfo n = find(getUiAutomation(1).getRootInActiveWindow(), klass, label);
            if (n != null) return n;
            SystemClock.sleep(100);
        } while (SystemClock.uptimeMillis() < stop);
        throw new AssertionError("Missing accessibility node " + klass + " " + label);
    }
    private static void check(boolean value, String message) { if (!value) throw new AssertionError(message); }

    private Bitmap capture(String name, Rect region, Bundle result) throws IOException {
        Bitmap full = getUiAutomation(1).takeScreenshot();
        check(full != null && new Rect(0, 0, full.getWidth(), full.getHeight()).contains(region),
              "Screenshot covers Rune switch " + region);
        File file = new File(getTargetContext().getExternalFilesDir(null), name + ".png");
        try (FileOutputStream output = new FileOutputStream(file)) {
            check(full.compress(Bitmap.CompressFormat.PNG, 100, output), "Write screenshot");
        }
        result.putString(name, file.toString());
        return Bitmap.createBitmap(full, region.left, region.top, region.width(), region.height());
    }

    private void testToggle(Bundle result) throws IOException {
        waitNode(null, "Lights off");
        AccessibilityNodeInfo before = waitNode("android.widget.Switch", "Lights");
        check(before.isCheckable() && !before.isChecked(), "Expected unchecked switch");
        Rect rect = new Rect();
        before.getBoundsInScreen(rect);
        check(before.performAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS), "Accessibility focus");
        Bitmap off = capture("rune-off", rect, result);
        check(before.performAction(AccessibilityNodeInfo.ACTION_CLICK), "Switch ACTION_CLICK");
        waitNode(null, "Lights on");
        check(waitNode("android.widget.Switch", "Lights").isChecked(), "Checked value after click");
        SystemClock.sleep(300);
        Bitmap on = capture("rune-on", rect, result);
        check(!off.sameAs(on), "Native switch pixels change");
        result.putString("switchBounds", rect.toShortString());
    }

    private static View editor(View root) {
        if (root.onCheckIsTextEditor()) return root;
        if (root instanceof ViewGroup) {
            ViewGroup group = (ViewGroup)root;
            for (int i = 0; i < group.getChildCount(); i++) {
                View child = editor(group.getChildAt(i));
                if (child != null) return child;
            }
        }
        return null;
    }
    private InputConnection connection(final Activity host, final boolean secure) {
        final InputConnection[] session = new InputConnection[1];
        for (int i = 0; i < 100 && session[0] == null; i++) {
            runOnMainSync(new Runnable() { public void run() {
                View edited = editor(host.getWindow().getDecorView());
                if (edited != null) {
                    EditorInfo info = new EditorInfo();
                    InputConnection c = edited.onCreateInputConnection(info);
                    boolean password = (info.inputType & android.text.InputType.TYPE_MASK_VARIATION) ==
                        android.text.InputType.TYPE_TEXT_VARIATION_PASSWORD;
                    if (c != null && secure == password) session[0] = c;
                }
            } });
            if (session[0] == null) SystemClock.sleep(60);
        }
        check(session[0] != null, "Native input connection");
        return session[0];
    }

    private void testEditor(final Activity host) {
        AccessibilityNodeInfo field = waitNode("android.widget.EditText", "Draft");
        check(field.isMultiLine() && field.performAction(AccessibilityNodeInfo.ACTION_FOCUS), "Focus multiline field");
        Throwable[] failure = new Throwable[1];
        final InputConnection c = connection(host, false);
        runOnMainSync(new Runnable() { public void run() {
            try {
                check(c.setComposingText("に", 1), "First preedit");
                check(c.setComposingText("日本", 1), "Replace marked text");
                check(c.commitText("日本語🚀", 1), "Unicode commit");
                check(c.deleteSurroundingTextInCodePoints(1, 0), "Delete surrogate pair");
                check(c.setSelection(1, 2), "UTF-16 selection");
                check(c.commitText("文", 1), "Replace selected text");
            } catch (Throwable f) { failure[0] = f; }
        } });
        if (failure[0] != null) throw new AssertionError(failure[0]);
        field = waitNode("android.widget.EditText", "日文語");
        check(field.getTextSelectionStart() == 2 && field.getTextSelectionEnd() == 2, "Caret after replacement");
        check(!getUiAutomation(1).getRootInActiveWindow().findAccessibilityNodeInfosByText("日文語").isEmpty(),
              "Accessibility service searches Rune field text");
        if (android.os.Build.VERSION.SDK_INT >= 34) {
            runOnMainSync(new Runnable() { public void run() {
                try { check(c.replaceText(0, 1, "改", 1, null), "Replace an autocorrect range"); }
                catch (Throwable f) { failure[0] = f; }
            } });
            if (failure[0] != null) throw new AssertionError(failure[0]);
            waitNode("android.widget.EditText", "改文語");
        }
        final String longText = new String(new char[3600]).replace('\0', 'a') + "🚀";
        Bundle fill = new Bundle();
        fill.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, longText);
        check(field.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, fill), "Fill a long document");
        field = waitNode("android.widget.EditText", longText);
        check(field.getTextSelectionEnd() == longText.length(), "Document-relative UTF-16 caret");
        final InputConnection document = connection(host, false);
        runOnMainSync(new Runnable() { public void run() {
            try {
                check(document.getTextBeforeCursor(10000, 0).toString().equals(longText), "Complete editor context");
                check(document.setComposingRegion(0, 1), "Mark model text while preserving the distant caret");
            } catch (Throwable f) { failure[0] = f; }
        } });
        if (failure[0] != null) throw new AssertionError(failure[0]);
        field = waitNode("android.widget.EditText", longText);
        check(field.getTextSelectionEnd() == longText.length(), "Marking a region preserves selection");
        runOnMainSync(new Runnable() { public void run() {
            try {
                check(document.finishComposingText() && document.setSelection(0, 0), "Select document start");
                check(document.commitText("Ω", 1), "Insert at document start");
            } catch (Throwable f) { failure[0] = f; }
        } });
        if (failure[0] != null) throw new AssertionError(failure[0]);
        waitNode("android.widget.EditText", "Ω" + longText);
        AccessibilityNodeInfo secret = waitNode("android.widget.EditText", "Secret");
        check(secret.isPassword() && (secret.getText() == null || secret.getText().length() == 0), "Password redaction");
        Bundle payload = new Bundle();
        payload.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "猫🚀");
        check(secret.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, payload), "Set secure field value");
        final InputConnection password = connection(host, true);
        runOnMainSync(new Runnable() { public void run() {
            try {
                check(!c.commitText("stale", 1), "Old field cannot edit new field");
                check(password.getTextBeforeCursor(100, 0).length() == 0, "Secret context is hidden from the IME");
                check(password.deleteSurroundingTextInCodePoints(1, 0), "Secure emoji deletion");
                check(password.commitText("🐈", 1), "Secure commit");
            } catch (Throwable f) { failure[0] = f; }
        } });
        if (failure[0] != null) throw new AssertionError(failure[0]);
        waitNode(null, "Password edit confirmed");
    }
}
