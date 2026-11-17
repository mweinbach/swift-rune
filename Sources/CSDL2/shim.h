#pragma once
#ifdef __linux__
#if __has_include(<SDL.h>)
#include <SDL.h>
#else
#include <SDL2/SDL.h>
#endif
#endif
