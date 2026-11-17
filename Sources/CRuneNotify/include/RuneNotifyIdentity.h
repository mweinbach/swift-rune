#ifndef RUNE_NOTIFY_IDENTITY_H
#define RUNE_NOTIFY_IDENTITY_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t rune_notify_win_identity(const wchar_t *id, const wchar_t *name, const wchar_t *icon,
                                 const wchar_t *scheme, int write_registry);
int rune_notify_win_has_activator(const wchar_t *id);
int rune_notify_win_focused(void);
void rune_notify_win_front(void);

#ifdef __cplusplus
}
#endif
#endif
