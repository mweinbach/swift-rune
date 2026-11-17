#ifndef RUNE_WIN_WINDOW_KEYBOARD_H
#define RUNE_WIN_WINDOW_KEYBOARD_H

#include <windows.h>
#include <stdint.h>

static uint32_t modifiers(void) {
    return (GetKeyState(VK_SHIFT) < 0 ? 1 : 0) | (GetKeyState(VK_CONTROL) < 0 ? 2 : 0) |
           (GetKeyState(VK_MENU) < 0 ? 4 : 0) |
           ((GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0) ? 8 : 0) |
           (GetKeyState(VK_RMENU) < 0 ? 16 : 0);
}

// Resolve shortcut punctuation with the active layout and Shift/Caps Lock, independently
// of Ctrl/Alt. TranslateMessage still owns dead keys and committed text.
static uint32_t shortcut_character(UINT vk, UINT scan, HKL layout) {
    BYTE state[256];
    WCHAR text[8];
    if (!GetKeyboardState(state)) return 0;
    state[VK_CONTROL] = state[VK_LCONTROL] = state[VK_RCONTROL] = 0;
    state[VK_MENU] = state[VK_LMENU] = state[VK_RMENU] = 0;
    state[VK_LWIN] = state[VK_RWIN] = 0;
    // Bit 2 reads the layout without changing the keyboard's pending dead-key state.
    int length = ToUnicodeEx(vk, scan, state, text, ARRAYSIZE(text), 4, layout);
    if (length == 1 && !(text[0] >= 0xd800 && text[0] <= 0xdfff)) return text[0];
    if (length == 2 && text[0] >= 0xd800 && text[0] <= 0xdbff &&
        text[1] >= 0xdc00 && text[1] <= 0xdfff)
        return 0x10000u + (((uint32_t)text[0] - 0xd800u) << 10) + (text[1] - 0xdc00u);
    return 0;
}

#endif
