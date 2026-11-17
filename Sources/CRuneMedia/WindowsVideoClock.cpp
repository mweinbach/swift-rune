#ifdef _WIN32
#include "include/RuneVideoClock.h"
#include <windows.h>
#include <dwmapi.h>
#include <cmath>
#include <mutex>

namespace {

struct Grid {
    LONGLONG period = 0;
    LONGLONG frequency = 0;
    LONGLONG blank = 0;
    LONGLONG lastRead = 0;
};

Grid sample(LONGLONG &now) {
    static Grid saved;
    static std::mutex lock;
    std::lock_guard<std::mutex> guard(lock);
    LARGE_INTEGER clock;
    if (!QueryPerformanceCounter(&clock)) return {};
    now = clock.QuadPart;
    if (saved.frequency && now - saved.lastRead < saved.frequency) return saved;

    // Only video playback needs DWM's presentation grid. Some server and remote
    // sessions cannot report it, so keep the last successful reading.
    static auto timing = []() -> decltype(&DwmGetCompositionTimingInfo) {
        HMODULE dll = LoadLibraryExW(L"dwmapi.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        return dll ? reinterpret_cast<decltype(&DwmGetCompositionTimingInfo)>(
            GetProcAddress(dll, "DwmGetCompositionTimingInfo")) : nullptr;
    }();
    LARGE_INTEGER frequency;
    DWM_TIMING_INFO info{};
    info.cbSize = sizeof(info);
    if (!timing || FAILED(timing(nullptr, &info)) || !QueryPerformanceFrequency(&frequency) ||
        frequency.QuadPart <= 0 || !QueryPerformanceCounter(&clock)) return saved;

    now = clock.QuadPart;
    const double period = double(info.qpcRefreshPeriod) / double(frequency.QuadPart);
    if (period >= 0.002 && period < 0.100)
        saved = {static_cast<LONGLONG>(info.qpcRefreshPeriod), frequency.QuadPart,
                 static_cast<LONGLONG>(info.qpcVBlank), now};
    return saved;
}
}

double rune_media_present_lead(void) {
    LONGLONG now = 0;
    const Grid grid = sample(now);
    if (!grid.period) return 0;
    // Pick the first vblank at least 2 ms after frame construction begins.
    const LONGLONG build = (grid.frequency + 499) / 500;
    const LONGLONG elapsed = now + build - grid.blank;
    if (elapsed <= 0) return double(grid.blank - now) / double(grid.frequency);
    const LONGLONG phase = elapsed % grid.period;
    return double(build + (phase ? grid.period - phase : 0)) / double(grid.frequency);
}

double rune_media_refresh_period(void) {
    LONGLONG now = 0;
    const Grid grid = sample(now);
    return grid.period ? double(grid.period) / double(grid.frequency) : 1.0 / 60.0;
}

double rune_media_refresh_wake(double seconds_until_picture) {
    LONGLONG now = 0;
    const Grid grid = sample(now);
    if (!grid.period) return std::fmax(0.001, seconds_until_picture);
    const double period = double(grid.period) / grid.frequency;
    const double sinceBlank = double(now - grid.blank) / grid.frequency;
    const double target = std::ceil((sinceBlank + seconds_until_picture) / period) * period;
    // Start between the two refreshes so snap selects target despite timer jitter.
    return std::fmax(0.001, target - sinceBlank - 0.002 - period * 0.5);
}
#endif
