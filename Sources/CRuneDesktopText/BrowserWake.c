#if defined(__wasi__)
#include "RuneDesktopText.h"

#if defined(RUNE_BROWSER_TEXT)
__attribute__((import_module("rune_text"), import_name("wake")))
extern void rune_host_wake(double seconds);
#endif

void rune_browser_host_wake(double seconds) {
#if defined(RUNE_BROWSER_TEXT)
    rune_host_wake(seconds);
#else
    (void)seconds;
#endif
}
#endif
