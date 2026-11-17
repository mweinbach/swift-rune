#pragma once

#include <stdbool.h>

bool scroll_bench_observe_presentations(const char *path);
unsigned scroll_bench_wheels_submitted(void);
void scroll_bench_wheel(double delta);
