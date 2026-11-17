#ifndef RUNE_NOTIFY_TOAST_H
#define RUNE_NOTIFY_TOAST_H

#include "RuneNotifyActivation.h"
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Presentation modes are normal (0), silent notification-center delivery (1),
   or high priority (2). Return an HRESULT. The callback context must outlive the toast. */
int32_t rune_notify_windows_show(const wchar_t *app_id, const wchar_t *xml, const wchar_t *tag,
                                 int presentation, RuneNotifyActivation activate, void *context);
int32_t rune_notify_windows_remove(const wchar_t *app_id, const wchar_t *tag);

#ifdef __cplusplus
}
#endif
#endif
