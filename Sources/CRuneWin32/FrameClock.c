#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "include/CRuneWin32.h"

static INIT_ONCE calibration_once = INIT_ONCE_STATIC_INIT;
static double cycles_per_ms;
static _Thread_local uint32_t frame_profile_flags;

uint32_t rune_win_frame_profile_flags(void) { return frame_profile_flags; }
void rune_win_set_frame_profile_flags(uint32_t flags) { frame_profile_flags = flags; }

static BOOL CALLBACK calibrate_thread_clock(PINIT_ONCE once, PVOID parameter, PVOID *context) {
    (void)once; (void)parameter; (void)context;
    LARGE_INTEGER frequency, start, end;
    if (!QueryPerformanceFrequency(&frequency) || frequency.QuadPart <= 0) return TRUE;

#if defined(_M_X64) || defined(__x86_64__)
    USHORT process_machine = 0, native_machine = 0;
    // Emulated x64 instructions can expose a different counter from the native thread.
    if (IsWow64Process2(GetCurrentProcess(), &process_machine, &native_machine)
        && native_machine == IMAGE_FILE_MACHINE_AMD64) {
        if (!QueryPerformanceCounter(&start)) return TRUE;
        ULONGLONG first = __rdtsc();
        Sleep(2);
        if (!QueryPerformanceCounter(&end)) return TRUE;
        ULONGLONG last = __rdtsc();
        if (end.QuadPart > start.QuadPart && last > first) {
            cycles_per_ms = (double)(last - first) * (double)frequency.QuadPart /
                (1000.0 * (double)(end.QuadPart - start.QuadPart));
        }
        return TRUE;
    }
#endif

    // A preemption lowers the measured rate. Look for an uninterrupted millisecond
    // within the same 60 ms calibration budget used by the upstream ARM clock.
    const LONGLONG ticks = (frequency.QuadPart + 999) / 1000;
    HANDLE thread = GetCurrentThread();
    LARGE_INTEGER began;
    if (!QueryPerformanceCounter(&began)) return TRUE;
    volatile uint32_t work = 1;
    for (int round = 0; round < 60; ++round) {
        ULONGLONG first, last;
        if (!QueryPerformanceCounter(&start) || !QueryThreadCycleTime(thread, &first)) return TRUE;
        do {
            // Sample an executing core, including on virtual machines where the pause
            // hint can yield the vCPU and lower its observed cycle rate.
            for (int i = 0; i < 64; ++i) work = work * 33u + 1u;
            if (!QueryPerformanceCounter(&end)) return TRUE;
        } while (end.QuadPart - start.QuadPart < ticks);
        if (!QueryThreadCycleTime(thread, &last) || !QueryPerformanceCounter(&end)) return TRUE;
        if (last > first) {
            double rate = (double)(last - first) * (double)frequency.QuadPart /
                (1000.0 * (double)(end.QuadPart - start.QuadPart));
            if (rate > cycles_per_ms) cycles_per_ms = rate;
        }
        if (round >= 2 && end.QuadPart - began.QuadPart >= 60 * ticks) break;
    }
    return TRUE;
}

double rune_win_thread_cpu_ms(void) {
    InitOnceExecuteOnce(&calibration_once, calibrate_thread_clock, NULL, NULL);
    ULONGLONG cycles;
    if (cycles_per_ms <= 0 || !QueryThreadCycleTime(GetCurrentThread(), &cycles)) return -1.0;
    return (double)cycles / cycles_per_ms;
}
#endif
