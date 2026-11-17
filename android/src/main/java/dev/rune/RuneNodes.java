package dev.rune;

import android.graphics.Rect;
import android.os.Build;
import android.os.Bundle;
import android.view.MotionEvent;
import android.view.View;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityNodeProvider;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

final class RuneNodes extends AccessibilityNodeProvider {
    private final RuneActivity.RuneView view;
    private final Map<Integer, Node> nodes = new LinkedHashMap<>();
    private final List<Integer> roots = new ArrayList<>();
    private int a11yFocus = 0, inputFocus = 0, hover = 0;
    private long announcementCount = -1;

    private static final class Node {
        final JSONObject data;
        final int id, parent;
        final Rect rect;
        final List<Integer> children = new ArrayList<>();
        Node(JSONObject data) throws JSONException {
            this.data = data;
            id = data.getInt("id"); parent = data.getInt("parent");
            JSONArray r = data.getJSONArray("rect");
            rect = new Rect(r.getInt(0), r.getInt(1), r.getInt(2), r.getInt(3));
        }
        boolean action(String name) {
            JSONArray list = data.optJSONArray("actions");
            if (list != null) for (int i = 0; i < list.length(); i++) if (name.equals(list.optString(i))) return true;
            return false;
        }
    }

    RuneNodes(RuneActivity.RuneView view) { this.view = view; }

    void update(JSONObject packet) throws JSONException {
        JSONArray source = packet.getJSONArray("nodes");
        int oldFocus = inputFocus;
        Node oldEditor = nodes.get(inputFocus);
        inputFocus = 0;
        nodes.clear();
        roots.clear();
        for (int i = 0; i < source.length(); i++) {
            Node n = new Node(source.getJSONObject(i));
            nodes.put(n.id, n);
            Node parent = nodes.get(n.parent);
            if (parent == null) roots.add(n.id); else parent.children.add(n.id);
            if (n.data.optBoolean("focused")) inputFocus = n.id;
        }
        if (!nodes.containsKey(a11yFocus)) a11yFocus = 0;
        if (!nodes.containsKey(hover)) hover = 0;
        event(HOST_VIEW_ID, AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED);
        if (inputFocus != oldFocus && inputFocus != 0) event(inputFocus, AccessibilityEvent.TYPE_VIEW_FOCUSED);
        if (inputFocus == oldFocus && oldEditor != null) editorEvents(oldEditor, nodes.get(inputFocus));
        long count = packet.optLong("announcementCount");
        if (announcementCount >= 0 && count != announcementCount && !packet.isNull("announcement"))
            view.announceForAccessibility(packet.getString("announcement"));
        announcementCount = count;
    }

    private void editorEvents(Node old, Node current) {
        if (current == null || current.data.optBoolean("secure") || current.data.isNull("selection")) return;
        String before = old.data.optString("value"), after = current.data.optString("value");
        if (!before.equals(after)) {
            int start = 0, oldEnd = before.length(), newEnd = after.length();
            while (start < oldEnd && start < newEnd && before.charAt(start) == after.charAt(start)) start++;
            while (oldEnd > start && newEnd > start && before.charAt(oldEnd - 1) == after.charAt(newEnd - 1)) {
                oldEnd--; newEnd--;
            }
            AccessibilityEvent change = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED);
            change.setBeforeText(before);
            change.getText().add(after);
            change.setFromIndex(start);
            change.setRemovedCount(oldEnd - start);
            change.setAddedCount(newEnd - start);
            deliver(current.id, change);
        }
        JSONArray selection = current.data.optJSONArray("selection"), prior = old.data.optJSONArray("selection");
        int start = selection.optInt(0), end = selection.optInt(1);
        if (prior == null || start != prior.optInt(0) || end != prior.optInt(1)) {
            AccessibilityEvent change = AccessibilityEvent.obtain(AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED);
            change.setFromIndex(start);
            change.setToIndex(end);
            change.setItemCount(after.length());
            change.getText().add(after);
            deliver(current.id, change);
        }
    }

    @Override public AccessibilityNodeInfo createAccessibilityNodeInfo(int id) {
        if (id == HOST_VIEW_ID) {
            AccessibilityNodeInfo info = AccessibilityNodeInfo.obtain(view);
            view.onInitializeAccessibilityNodeInfo(info);
            for (int child : roots) info.addChild(view, child);
            return info;
        }
        Node n = nodes.get(id);
        if (n == null) return null;
        JSONObject d = n.data;
        AccessibilityNodeInfo info = AccessibilityNodeInfo.obtain();
        info.setSource(view, id);
        if (n.parent == HOST_VIEW_ID) info.setParent(view); else info.setParent(view, n.parent);
        for (int child : n.children) info.addChild(view, child);
        info.setPackageName(view.getContext().getPackageName());
        String role = d.optString("role"), name = d.optString("name");
        boolean editor = role.equals("textbox") || role.equals("password-input") || role.equals("multiline-text-input");
        info.setClassName(className(role));
        info.setEnabled(!d.optBoolean("disabled"));
        info.setPassword(d.optBoolean("secure"));
        info.setSelected(d.optBoolean("selected"));
        if (!d.isNull("liveRegion")) info.setLiveRegion("assertive".equals(d.optString("liveRegion"))
            ? View.ACCESSIBILITY_LIVE_REGION_ASSERTIVE : View.ACCESSIBILITY_LIVE_REGION_POLITE);
        info.setFocusable(d.optBoolean("focusable"));
        info.setFocused(d.optBoolean("focused"));
        info.setAccessibilityFocused(id == a11yFocus);
        info.addAction(id == a11yFocus ? AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS : AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS);
        if (editor) {
            info.setEditable(!d.optBoolean("readOnly"));
            info.setMultiLine(role.equals("multiline-text-input"));
            if (!d.optBoolean("secure")) {
                info.setText(d.optString("value"));
                JSONArray selection = d.optJSONArray("selection");
                if (selection != null) info.setTextSelection(selection.optInt(0), selection.optInt(1));
            }
            if (!name.isEmpty()) info.setContentDescription(name);
            if (Build.VERSION.SDK_INT >= 26 && !d.isNull("help")) info.setHintText(d.optString("help"));
        } else if (role.equals("text") || role.equals("label") || role.equals("heading")) info.setText(name);
        else if (!name.isEmpty()) info.setContentDescription(name);
        if (Build.VERSION.SDK_INT >= 28) {
            info.setHeading(role.equals("heading"));
            if (!name.isEmpty() && (role.equals("dialog") || role.equals("alertdialog"))) info.setPaneTitle(name);
        }
        if (!d.isNull("checked")) {
            info.setCheckable(true);
            info.setChecked("true".equals(d.optString("checked")));
            if (Build.VERSION.SDK_INT >= 30 && "mixed".equals(d.optString("checked"))) info.setStateDescription("Mixed");
        }
        if (n.action("press")) { info.setClickable(true); info.addAction(AccessibilityNodeInfo.ACTION_CLICK); }
        if (n.action("focus")) info.addAction(AccessibilityNodeInfo.ACTION_FOCUS);
        if (n.action("increment")) info.addAction(AccessibilityNodeInfo.ACTION_SCROLL_FORWARD);
        if (n.action("decrement")) info.addAction(AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD);
        JSONObject range = d.optJSONObject("range");
        if (range != null) {
            info.setRangeInfo(AccessibilityNodeInfo.RangeInfo.obtain(AccessibilityNodeInfo.RangeInfo.RANGE_TYPE_FLOAT,
                (float)range.optDouble("min"), (float)range.optDouble("max"), (float)range.optDouble("value")));
            if (n.action("set-value")) info.addAction(AccessibilityNodeInfo.AccessibilityAction.ACTION_SET_PROGRESS);
        }
        if (editor && n.action("set-value")) {
            info.addAction(AccessibilityNodeInfo.ACTION_SET_TEXT);
            if (!info.isPassword()) info.addAction(AccessibilityNodeInfo.ACTION_SET_SELECTION);
        }
        Node parent = nodes.get(n.parent);
        Rect relative = new Rect(n.rect);
        if (parent != null) relative.offset(-parent.rect.left, -parent.rect.top);
        info.setBoundsInParent(relative);
        int[] origin = new int[2]; view.getLocationOnScreen(origin);
        Rect screen = new Rect(n.rect); screen.offset(origin[0], origin[1]);
        info.setBoundsInScreen(screen);
        Rect visible = new Rect();
        info.setVisibleToUser(view.isShown() && view.getLocalVisibleRect(visible) && Rect.intersects(visible, n.rect));
        return info;
    }

    @Override public AccessibilityNodeInfo findFocus(int kind) {
        int id = kind == AccessibilityNodeInfo.FOCUS_ACCESSIBILITY ? a11yFocus : inputFocus;
        return id == 0 ? null : createAccessibilityNodeInfo(id);
    }

    @Override public List<AccessibilityNodeInfo> findAccessibilityNodeInfosByText(String query, int root) {
        List<AccessibilityNodeInfo> result = new ArrayList<>();
        if (query == null || query.isEmpty()) return result;
        String needle = query.toLowerCase(Locale.ROOT);
        if (root == HOST_VIEW_ID) {
            for (int id : roots) find(id, needle, result);
        } else find(root, needle, result);
        return result;
    }

    private void find(int id, String needle, List<AccessibilityNodeInfo> result) {
        Node node = nodes.get(id);
        if (node == null) return;
        JSONObject data = node.data;
        if (data.optString("name").toLowerCase(Locale.ROOT).contains(needle) ||
            (!data.optBoolean("secure") && data.optString("value").toLowerCase(Locale.ROOT).contains(needle)))
            result.add(createAccessibilityNodeInfo(id));
        for (int child : node.children) find(child, needle, result);
    }

    @Override public boolean performAction(int id, int action, Bundle args) {
        if (id == HOST_VIEW_ID) return view.performAccessibilityAction(action, args);
        Node n = nodes.get(id);
        if (n == null) return false;
        if (action == AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS) {
            if (id == a11yFocus) return false;
            if (a11yFocus != 0) event(a11yFocus, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED);
            a11yFocus = id; event(id, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED); return true;
        }
        if (action == AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS) {
            if (id != a11yFocus) return false;
            a11yFocus = 0; event(id, AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED); return true;
        }
        if (n.data.optBoolean("disabled")) return false;
        JSONObject payload = new JSONObject();
        String op;
        try {
            switch (action) {
            case AccessibilityNodeInfo.ACTION_CLICK: op = "press"; break;
            case AccessibilityNodeInfo.ACTION_FOCUS: op = "focus"; break;
            case AccessibilityNodeInfo.ACTION_SCROLL_FORWARD: op = "increment"; break;
            case AccessibilityNodeInfo.ACTION_SCROLL_BACKWARD: op = "decrement"; break;
            case AccessibilityNodeInfo.ACTION_SET_TEXT:
                if (args == null || args.getCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE) == null) return false;
                op = "set-value"; payload.put("text", args.getCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE).toString());
                break;
            case android.R.id.accessibilityActionSetProgress:
                if (args == null || !args.containsKey(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE)) return false;
                op = "set-value"; payload.put("number", args.getFloat(AccessibilityNodeInfo.ACTION_ARGUMENT_PROGRESS_VALUE)); break;
            case AccessibilityNodeInfo.ACTION_SET_SELECTION:
                if (args == null || n.data.optBoolean("secure") || !n.action("set-value")) return false;
                payload.put("anchor", args.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, -1));
                payload.put("focus", args.getInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, -1));
                return view.activity.runeAction("selectText", id, payload);
            default: return false;
            }
        } catch (JSONException error) { return false; }
        if (!n.action(op) || !view.activity.runeAction(op, id, payload)) return false;
        if (action == AccessibilityNodeInfo.ACTION_CLICK) event(id, AccessibilityEvent.TYPE_VIEW_CLICKED);
        return true;
    }

    boolean hover(MotionEvent e) {
        if (!view.activity.isRuneReaderActive()) return false;
        int kind = e.getActionMasked();
        if (kind != MotionEvent.ACTION_HOVER_MOVE && kind != MotionEvent.ACTION_HOVER_ENTER && kind != MotionEvent.ACTION_HOVER_EXIT) return false;
        int touched = 0;
        if (kind != MotionEvent.ACTION_HOVER_EXIT)
            for (Node n : nodes.values()) if (n.rect.contains((int)e.getX(), (int)e.getY())) touched = n.id;
        if (touched != hover) {
            if (touched != 0) event(touched, AccessibilityEvent.TYPE_VIEW_HOVER_ENTER);
            if (hover != 0) event(hover, AccessibilityEvent.TYPE_VIEW_HOVER_EXIT);
            hover = touched;
        }
        return touched != 0;
    }

    private void event(int id, int kind) {
        AccessibilityEvent e = AccessibilityEvent.obtain(kind);
        if (kind == AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED)
            e.setContentChangeTypes(AccessibilityEvent.CONTENT_CHANGE_TYPE_SUBTREE);
        deliver(id, e);
    }

    private void deliver(int id, AccessibilityEvent e) {
        if (view.getParent() == null || !view.activity.isRuneReaderActive()) return;
        e.setPackageName(view.getContext().getPackageName());
        Node n = nodes.get(id);
        if (n != null) e.setClassName(className(n.data.optString("role")));
        if (id == HOST_VIEW_ID) e.setSource(view); else e.setSource(view, id);
        view.getParent().requestSendAccessibilityEvent(view, e);
    }

    private static String className(String role) {
        switch (role) {
        case "button": return "android.widget.Button";
        case "menubar": return "android.widget.Toolbar";
        case "switch": return "android.widget.Switch";
        case "checkbox": case "menu-item-check-box": return "android.widget.CheckBox";
        case "radio": case "menu-item-radio": return "android.widget.RadioButton";
        case "textbox": case "multiline-text-input": case "password-input": return "android.widget.EditText";
        case "slider": return "android.widget.SeekBar";
        case "progressbar": return "android.widget.ProgressBar";
        case "img": case "icon": return "android.widget.ImageView";
        case "list": case "listbox": return "android.widget.ListView";
        case "scroll-view": return "android.widget.ScrollView";
        case "dialog": return "android.app.Dialog";
        case "alertdialog": return "android.app.AlertDialog";
        case "text": case "label": case "heading": case "link": return "android.widget.TextView";
        default: return "android.view.View";
        }
    }
}
