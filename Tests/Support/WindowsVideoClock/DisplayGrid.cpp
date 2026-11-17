// Standalone live DWM probe: cl /EHsc DisplayGrid.cpp
#define NOMINMAX
#include <windows.h>
#include <dwmapi.h>
#include <cmath>
#include <cstdio>
#include "../../../Sources/CRuneMedia/WindowsVideoClock.cpp"

int main() {
    auto dll = LoadLibraryW(L"dwmapi.dll");
    auto timing = dll ? reinterpret_cast<decltype(&DwmGetCompositionTimingInfo)>(
        GetProcAddress(dll, "DwmGetCompositionTimingInfo")) : nullptr;
    DWM_TIMING_INFO info{};
    info.cbSize = sizeof(info);
    LARGE_INTEGER frequency;
    if (!timing || FAILED(timing(nullptr, &info)) || !QueryPerformanceFrequency(&frequency) ||
        !info.qpcRefreshPeriod) {
        std::fprintf(stderr, "DWM timing unavailable in this desktop session\n");
        return 2;
    }
    const double period = double(info.qpcRefreshPeriod) / frequency.QuadPart;
    if (std::fabs(rune_media_refresh_period() - period) > 0.0001) return 3;

    // Compare both public calculations to the real cached DWM anchor using a
    // separate QPC measurement. A VM may change vblank phase between DWM reads;
    // the player intentionally uses one reading for a full second.
    int onGrid = 0, wakeOnGrid = 0;
    for (int i = 0; i < 100; ++i) {
        LARGE_INTEGER before, after;
        LONGLONG sampledAt;
        const auto anchor = sample(sampledAt);
        QueryPerformanceCounter(&before);
        const double lead = rune_media_present_lead();
        const double wake = rune_media_refresh_wake(0.040);
        QueryPerformanceCounter(&after);
        if (lead <= 0.00199 || lead > 0.00201 + period) return 4;
        if (!anchor.period || anchor.lastRead > before.QuadPart ||
            before.QuadPart - anchor.lastRead > 2 * frequency.QuadPart) return 6;
        const double start = double(before.QuadPart - anchor.blank) / frequency.QuadPart;
        const double cost = double(after.QuadPart - before.QuadPart) / frequency.QuadPart;
        if (std::fabs(std::remainder(start + lead, period)) < cost + 0.0005) ++onGrid;
        const double presentation = wake + 0.002 + period * 0.5;
        if (presentation >= 0.040 - cost && presentation <= 0.040 + period + cost &&
            std::fabs(std::remainder(start + presentation, period)) < cost + 0.0005) ++wakeOnGrid;
        Sleep(2);
    }
    std::printf("DWM refresh %.3f Hz, %d/100 snapped display targets, %d/100 picture deadlines\n",
                1.0 / period, onGrid, wakeOnGrid);
    return onGrid >= 95 && wakeOnGrid >= 95 ? 0 : 5;
}
