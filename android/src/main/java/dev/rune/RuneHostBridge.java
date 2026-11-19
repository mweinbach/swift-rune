package dev.rune;

import android.view.View;
import android.view.inputmethod.InputMethodManager;
import org.json.JSONObject;

/** Shared View, IME, and accessibility bridge implemented by RuneActivity.RuneView and RuneSurfaceView. */
interface RuneHostBridge {
    View hostView();
    InputMethodManager ime();
    boolean runeAction(String op, int id, JSONObject args);
    boolean isRuneReaderActive();
    boolean clearFocusOnEditorBlur();
}
