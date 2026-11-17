#ifndef RUNE_WIN_POPUP_H
#define RUNE_WIN_POPUP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneWinPopupMenu RuneWinPopupMenu;
typedef enum { RuneWinMenuFollowSystem = 1, RuneWinMenuDark = 2, RuneWinMenuLight = 3 } RuneWinMenuScheme;
void rune_win_menu_scheme(RuneWinMenuScheme scheme);
typedef uint32_t (*RuneWinPopupKey)(void *context, uint32_t vk, uint32_t mods, uint32_t shortcut_scalar);
typedef void (*RuneWinPopupDone)(void *context, uint32_t command);

RuneWinPopupMenu *rune_win_popup_create(void);
// A submenu is owned by its parent. Labels are UTF-16 and ampersands are literal.
RuneWinPopupMenu *rune_win_popup_submenu(RuneWinPopupMenu *parent, const uint16_t *title, int enabled);
// Command zero creates a separator.
int rune_win_popup_item(RuneWinPopupMenu *parent, uint32_t command, const uint16_t *label, int enabled, int checked);
void rune_win_popup_dispose(RuneWinPopupMenu *root);

// Call on the owning window thread. Successful posting transfers ownership of root
// and resolves done exactly once (zero on dismissal). On failure the caller owns root.
// Position and size are client DIPs. rtl < 0 follows the native window layout.
int rune_win_popup_show(void *hwnd, RuneWinPopupMenu *root, double x, double y, double width, double height,
                        int rect_anchor, int rtl, uint32_t positioned, void *context,
                        RuneWinPopupKey key, RuneWinPopupDone done);
// Cancels pending or open tracking and delivers its dismissal before returning.
void rune_win_popup_cancel(void *hwnd);

#ifdef __cplusplus
}
#endif
#endif
