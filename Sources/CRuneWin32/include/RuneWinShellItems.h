#ifndef RUNE_WIN_SHELL_ITEMS_H
#define RUNE_WIN_SHELL_ITEMS_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct RuneWinTraySpec RuneWinTraySpec;
typedef struct RuneWinTray RuneWinTray;
typedef void (*RuneWinTrayEvent)(void *context, const uint16_t *item_id);
typedef void (*RuneWinTrayRelease)(void *context);
RuneWinTraySpec *rune_win_tray_spec(const uint16_t *tooltip, const uint8_t *rgba, uint32_t width, uint32_t height);
RuneWinTraySpec *rune_win_tray_spec_keeping_icon(const uint16_t *tooltip);
void rune_win_tray_item(RuneWinTraySpec *, const uint16_t *id, const uint16_t *label, int enabled);
// Open consumes the spec and context on all paths. A null event id means primary activation.
RuneWinTray *rune_win_tray_open(RuneWinTraySpec *, void *context, RuneWinTrayEvent, RuneWinTrayRelease, uint32_t *error);
void rune_win_tray_update(RuneWinTray *, RuneWinTraySpec *);
void rune_win_tray_close(RuneWinTray *);
void rune_win_trays_remove_all(void);

// A draft stays on one worker thread. Begin and dispose balance its COM apartment.
typedef struct RuneWinJumpDraft RuneWinJumpDraft;
int32_t rune_win_jump_begin(RuneWinJumpDraft **draft, const uint16_t *lead);
int32_t rune_win_jump_item(RuneWinJumpDraft *, const uint16_t *title, const uint16_t *argument, const uint16_t *description);
int32_t rune_win_jump_category(RuneWinJumpDraft *, const uint16_t *name);
int32_t rune_win_jump_commit(RuneWinJumpDraft *);
void rune_win_jump_dispose(RuneWinJumpDraft *);
#ifdef __cplusplus
}
#endif
#endif
