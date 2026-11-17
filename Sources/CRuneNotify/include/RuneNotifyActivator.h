#ifndef RUNE_NOTIFY_ACTIVATOR_H
#define RUNE_NOTIFY_ACTIVATOR_H

#include <stdint.h>
#include "RuneNotifyActivation.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Serve calls callback on a COM thread. Its context must outlive every
 * invocation already in flight when the handler is replaced or stopped. */
int32_t rune_notify_serve_activations(const wchar_t *clsid, RuneNotifyActivation callback,
                                      void *context);
/* The next activation is delivered to the waiting thread. S_FALSE means
 * timeout. Temporary registrations are revoked when the last waiter leaves. */
int32_t rune_notify_wait_activation(const wchar_t *clsid, uint32_t timeout_ms,
                                    RuneNotifyActivation callback, void *context);
void rune_notify_stop_activations(const wchar_t *clsid);

#ifdef __cplusplus
}
#endif
#endif
