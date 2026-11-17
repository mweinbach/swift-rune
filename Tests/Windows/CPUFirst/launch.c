#include "CPUProbeDriver.h"
#include <string.h>
#include <wchar.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (!strcmp(argv[1], "handoff")) return cpu_probe_launch(L"handoff");
    if (!strcmp(argv[1], "direct")) return cpu_probe_launch(L"direct");
    if (!strcmp(argv[1], "failure")) return cpu_probe_launch(L"failure");
    if (!strcmp(argv[1], "only")) return cpu_probe_launch(L"only");
    return 2;
}
