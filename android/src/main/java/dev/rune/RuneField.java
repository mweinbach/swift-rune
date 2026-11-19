package dev.rune;

import android.os.Build;
import android.text.Editable;
import android.text.InputType;
import android.text.Selection;
import android.text.SpannableStringBuilder;
import android.view.KeyEvent;
import android.view.View;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import org.json.JSONException;
import org.json.JSONObject;

/** Android IMEs use document-relative UTF-16 indices. Password editors publish no model text. */
final class RuneField {
    private final RuneHostBridge host;
    private final View view;
    private String key, text = "";
    private int anchor, focus;
    private boolean secure, multiline;
    private Connection connection;

    RuneField(RuneHostBridge host) {
        this.host = host;
        this.view = host.hostView();
    }
    boolean active() { return key != null; }

    void deactivate() {
        if (connection != null) {
            connection.retire();
            connection = null;
        }
        InputMethodManager ime = host.ime();
        if (ime != null && view.getWindowToken() != null) {
            ime.hideSoftInputFromWindow(view.getWindowToken(), 0);
        }
    }

    void update(JSONObject packet) {
        JSONObject next = packet.optJSONObject("mirror");
        String newKey = next == null ? null : next.optString("key");
        boolean newSecure = next != null && next.optBoolean("secure");
        boolean newMultiline = packet.optBoolean("multiline");
        boolean changed = !java.util.Objects.equals(key, newKey) || secure != newSecure || multiline != newMultiline;
        key = newKey;
        secure = newSecure;
        multiline = newMultiline;
        text = secure || next == null ? "" : next.optString("text");
        anchor = next == null ? 0 : next.optInt("anchor");
        focus = next == null ? 0 : next.optInt("focus");

        InputMethodManager ime = host.ime();
        if (changed) {
            if (connection != null) connection.retire();
            connection = null;
            if (!active()) {
                if (ime != null) {
                    if (view.getWindowToken() != null) ime.hideSoftInputFromWindow(view.getWindowToken(), 0);
                    ime.restartInput(view);
                }
                if (host.clearFocusOnEditorBlur()) view.clearFocus();
            } else {
                view.requestFocus();
                if (ime != null) {
                    ime.restartInput(view);
                    ime.showSoftInput(view, InputMethodManager.SHOW_IMPLICIT);
                }
            }
        } else if (connection != null) {
            if (connection.model.equals(text) && anchor == connection.modelAnchor && focus == connection.modelFocus && connection.composing()) return;
            connection.reset();
            if (ime != null) ime.updateSelection(view, anchor, focus, -1, -1);
        }
    }

    InputConnection connect(EditorInfo info) {
        if (!active()) return null;
        info.inputType = InputType.TYPE_CLASS_TEXT;
        if (secure) {
            info.inputType |= InputType.TYPE_TEXT_VARIATION_PASSWORD | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
            if (Build.VERSION.SDK_INT >= 26) info.imeOptions |= EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING;
        } else if (multiline) info.inputType |= InputType.TYPE_TEXT_FLAG_MULTI_LINE;
        info.imeOptions |= multiline ? EditorInfo.IME_ACTION_NONE : EditorInfo.IME_ACTION_DONE;
        info.initialSelStart = anchor; info.initialSelEnd = focus;
        if (connection != null) connection.retire();
        connection = Build.VERSION.SDK_INT >= 34 ? new ModernConnection() : new Connection();
        return connection;
    }

    private class Connection extends BaseInputConnection {
        private final SpannableStringBuilder buffer = new SpannableStringBuilder();
        private String model = "";
        private int modelAnchor, modelFocus;
        private boolean markedModelRegion;
        Connection() { super(view, true); reset(); }
        @Override public Editable getEditable() { return buffer; }
        void retire() {
            removeComposingSpans(buffer);
            buffer.clear();
            model = "";
            markedModelRegion = false;
        }
        @Override public void closeConnection() {
            super.closeConnection();
            if (connection == this) connection = null;
            retire();
        }
        void reset() {
            removeComposingSpans(buffer);
            markedModelRegion = false;
            buffer.replace(0, buffer.length(), text);
            Selection.setSelection(buffer, Math.min(anchor, buffer.length()), Math.min(focus, buffer.length()));
            model = text;
            modelAnchor = anchor;
            modelFocus = focus;
        }
        boolean composing() { return getComposingSpanStart(buffer) >= 0; }

        private JSONObject args() throws JSONException {
            return new JSONObject().put("key", key);
        }
        private boolean send(String op, JSONObject payload) {
            if (connection != this || !active()) return false;
            boolean handled = host.runeAction(op, -1, payload);
            if (!handled) host.runeAction("refresh", -1, null);
            return handled;
        }
        private boolean mirror(String op) {
            if (secure || connection != this) return false;
            try {
                JSONObject payload = args().put("base", 0).put("expected", model)
                    .put("anchor", Selection.getSelectionStart(buffer)).put("focus", Selection.getSelectionEnd(buffer));
                if (op.equals("edit")) payload.put("text", buffer.toString());
                if (!send(op, payload)) return false;
                if (op.equals("edit")) model = buffer.toString();
                modelAnchor = Selection.getSelectionStart(buffer);
                modelFocus = Selection.getSelectionEnd(buffer);
                return true;
            } catch (JSONException error) { return false; }
        }
        private boolean selectModel(int start, int end) {
            try {
                if (!send("selection", args().put("base", 0).put("expected", model)
                        .put("anchor", start).put("focus", end))) return false;
                modelAnchor = start;
                modelFocus = end;
                return true;
            }
            catch (JSONException error) { return false; }
        }
        private boolean preedit() {
            int lo = getComposingSpanStart(buffer), hi = getComposingSpanEnd(buffer);
            String marked = lo < 0 || hi < lo ? "" : buffer.subSequence(lo, hi).toString();
            try { return send("preedit", args().put("text", marked)
                        .put("focus", Math.max(0, Math.min(marked.length(), Selection.getSelectionEnd(buffer) - Math.max(lo, 0))))); }
            catch (JSONException error) { return false; }
        }
        @Override public boolean setComposingText(CharSequence value, int cursor) {
            if (connection != this) return false;
            if (markedModelRegion && !selectModel(getComposingSpanStart(buffer), getComposingSpanEnd(buffer))) return false;
            markedModelRegion = false;
            if (!super.setComposingText(value, cursor)) return false;
            return secure || preedit();
        }
        @Override public boolean setComposingRegion(int start, int end) {
            if (connection != this || secure) return false;
            if (composing() && !markedModelRegion && !finishComposingText()) return false;
            if (!super.setComposingRegion(start, end)) return false;
            // An IME can mark existing text without moving the insertion caret.
            markedModelRegion = composing();
            return true;
        }
        private boolean secureCommit(String inserted) {
            try {
                boolean ok = inserted.isEmpty() || send("secureInsert", args().put("text", inserted));
                buffer.clear(); Selection.setSelection(buffer, 0);
                return ok;
            } catch (JSONException error) { return false; }
        }
        @Override public boolean finishComposingText() {
            if (connection != this) return false;
            if (!composing()) return true;
            String draft = secure ? buffer.toString() : "";
            super.finishComposingText();
            markedModelRegion = false;
            return secure ? secureCommit(draft) : mirror("edit");
        }
        @Override public boolean commitText(CharSequence value, int cursor) {
            if (connection != this) return false;
            if (secure) return secureCommit(value.toString());
            markedModelRegion = false;
            return super.commitText(value, cursor) && mirror("edit");
        }
        @Override public boolean setSelection(int start, int end) {
            if (connection != this || !super.setSelection(start, end)) return false;
            return secure || (composing() && !markedModelRegion ? preedit() : mirror("selection"));
        }
        @Override public boolean deleteSurroundingText(int before, int after) { return delete(before, after, false); }
        @Override public boolean deleteSurroundingTextInCodePoints(int before, int after) { return delete(before, after, true); }
        private boolean delete(int before, int after, boolean points) {
            if (connection != this || before < 0 || after < 0) return false;
            if (!secure) {
                boolean ok = points ? super.deleteSurroundingTextInCodePoints(before, after) : super.deleteSurroundingText(before, after);
                return ok && (composing() && !markedModelRegion ? preedit() : mirror("edit"));
            }
            if (composing()) return points ? super.deleteSurroundingTextInCodePoints(before, after) : super.deleteSurroundingText(before, after);
            try {
                return send("secureDelete", args().put("before", before).put("after", after).put("points", points));
            } catch (JSONException error) { return false; }
        }
        @Override public boolean performEditorAction(int action) {
            if (composing() && !finishComposingText()) return false;
            try { return send("return", args()); } catch (JSONException error) { return false; }
        }
        @Override public boolean sendKeyEvent(KeyEvent keyEvent) {
            // Hardware keyboard and editor-synthesized key events use NativeActivity's normal input queue.
            if (connection != this) return false;
            super.sendKeyEvent(keyEvent);
            return true;
        }
    }

    @android.annotation.TargetApi(34)
    private final class ModernConnection extends Connection {
        @Override public boolean replaceText(int start, int end, CharSequence value, int cursor,
                                             android.view.inputmethod.TextAttribute attribute) {
            if (connection != this || start < 0 || end < 0) return false;
            if (secure) return start == 0 && end == 0 && commitText(value, cursor);
            return finishComposingText() && setSelection(start, end) && commitText(value, cursor);
        }
    }
}
