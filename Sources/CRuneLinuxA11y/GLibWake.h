#if defined(__linux__) && !defined(__ANDROID__)
#include <glib.h>
#include "CRuneLinuxA11y.h"
typedef struct RuneGLibWatch RuneGLibWatch;
RuneGLibWatch *rune_glib_watch_new(RuneA11yWake wake, void *context);
void rune_glib_watch_arm(RuneGLibWatch *);
void rune_glib_watch_free(RuneGLibWatch *);
#endif
