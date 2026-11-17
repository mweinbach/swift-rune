#ifndef RUNE_TEST_STARTUP_DRIVER_H
#define RUNE_TEST_STARTUP_DRIVER_H
#include <stddef.h>

int startup_launch_child(const wchar_t *mode);
int startup_observe_paint(void);
int startup_is_painting(void);
int startup_post_key(void);

#endif
