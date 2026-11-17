#include "CRuneLinux.h"
#include <GL/gl.h>
#include <stdio.h>

static bool first_frame(RuneLinuxWindowOptions options, int expected_width, int expected_height) {
    RuneLinuxWindow *window = rune_linux_open("Rune first drawable", options);
    if (!window) {
        fprintf(stderr, "%s\n", rune_linux_error());
        return false;
    }
    rune_linux_show(window);
    int width, height, pixels_wide, pixels_high;
    rune_linux_size(window, &width, &height, &pixels_wide, &pixels_high);
    glClearColor(0, 1, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);

    // An asynchronous SDL resize can report the new dimensions while the old drawable is still bound.
    unsigned char corner[4] = {0};
    glReadPixels(pixels_wide - 1, pixels_high - 1, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, corner);
    bool correct = width == expected_width && height == expected_height
        && corner[0] == 0 && corner[1] == 255 && corner[2] == 0 && corner[3] == 255
        && glGetError() == GL_NO_ERROR;
    printf("%dx%d requested, %dx%d window, %dx%d first drawable, RGBA [%u %u %u %u]\n",
           options.width, options.height, width, height, pixels_wide, pixels_high,
           corner[0], corner[1], corner[2], corner[3]);
    rune_linux_close(window);
    return correct;
}

int main(void) {
    const RuneLinuxWindowOptions minimum = {
        .width = 320, .height = 200, .minWidth = 420, .minHeight = 400, .resizable = true
    };
    const RuneLinuxWindowOptions mixed = {
        .width = 100, .height = 900, .minWidth = 110, .minHeight = 30,
        .maxWidth = 640, .maxHeight = 480, .resizable = true
    };
    bool at_minimum = first_frame(minimum, 420, 400);
    bool at_mixed_limits = first_frame(mixed, 110, 480);
    return at_minimum && at_mixed_limits ? 0 : 1;
}
