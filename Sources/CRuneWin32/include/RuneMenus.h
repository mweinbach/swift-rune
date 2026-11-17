#ifndef RUNE_WIN_MENUS_H
#define RUNE_WIN_MENUS_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneWinMenu RuneWinMenu;
typedef struct RuneWinMenuDraft RuneWinMenuDraft;
typedef void (*RuneWinMenuSelect)(void *owner, uint32_t command, uint64_t revision);
RuneWinMenu *rune_win_menu_open(void *hwnd, void *owner, RuneWinMenuSelect select);
void rune_win_menu_close(RuneWinMenu *menu);
int rune_win_menu_tracking(RuneWinMenu *menu);
RuneWinMenuDraft *rune_win_menu_begin(void);
int rune_win_menu_section(RuneWinMenuDraft *draft, const uint16_t *title);
int rune_win_menu_item(RuneWinMenuDraft *draft, uint32_t command, const uint16_t *label, int enabled, int checked);
// Passing NULL as draft removes the bar. The caller releases draft on either outcome.
int rune_win_menu_install(RuneWinMenu *menu, RuneWinMenuDraft *draft, uint64_t revision);
void rune_win_menu_dispose(RuneWinMenuDraft *draft);
#ifdef __cplusplus
}
#endif
#endif
