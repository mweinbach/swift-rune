#pragma once
#include <SDL2/SDL_video.h>
#include <stdbool.h>

void rune_linux_release_input_region(void);
void rune_linux_refresh_frame_input(SDL_Window *window, bool closing);
