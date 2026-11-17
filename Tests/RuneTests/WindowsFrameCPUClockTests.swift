#if os(Windows)
import Dispatch
import Rune
import Testing
import WinSDK

@Suite("Windows frame CPU accounting")
struct WindowsFrameCPUClockTests {
    private func work(forNanoseconds duration: UInt64) {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < duration {}
    }

    private func schedulerCPU() throws -> Double {
        var created = FILETIME(), exited = FILETIME(), kernel = FILETIME(), user = FILETIME()
        try #require(GetThreadTimes(GetCurrentThread(), &created, &exited, &kernel, &user))
        func milliseconds(_ value: FILETIME) -> Double {
            Double(UInt64(value.dwHighDateTime) << 32 | UInt64(value.dwLowDateTime)) / 10_000
        }
        return milliseconds(kernel) + milliseconds(user)
    }

    @Test func shortFramePhasesAndLongTermCPUAgree() throws {
        let before = threadCpuMs()
        let diagnostic = try #require(PerfWarn.threadCpuMs())
        #expect(diagnostic >= before)
        #expect(threadCpuMs() >= diagnostic)

        // Several sub-tick paint phases must advance independently between scheduler ticks.
        let samples = FrameProfiling.withRecording {
            _ = takeFramePhases()
            var shortWall = 0, shortCPU = 0
            for _ in 0..<160 {
                measureFramePhase(.paint) { work(forNanoseconds: 1_000_000) }
                let phases = takeFramePhases()
                guard phases[FramePhase.paint.rawValue] < 8 else { continue }
                shortWall += 1
                let cpu = phases[FRAME_PHASES + FramePhase.paint.rawValue]
                if cpu > 0 && cpu < 8 { shortCPU += 1 }
                if shortWall == 20 { break }
            }
            return (shortWall: shortWall, shortCPU: shortCPU)
        }
        try #require(samples.shortWall >= 10)
        #expect(samples.shortCPU * 4 >= samples.shortWall * 3)

        let idle = threadCpuMs()
        Sleep(80)
        #expect(threadCpuMs() - idle < 20)

        // The scheduler's coarse CPU total is an independent reference over a longer run.
        let referenceStart = try schedulerCPU()
        let busyStart = threadCpuMs()
        let wallStart = DispatchTime.now().uptimeNanoseconds
        var reference = 0.0
        repeat {
            work(forNanoseconds: 25_000_000)
            reference = try schedulerCPU() - referenceStart
        } while reference < 350 && DispatchTime.now().uptimeNanoseconds - wallStart < 10_000_000_000
        let measured = threadCpuMs() - busyStart
        try #require(reference >= 350, "The scheduler must observe multiple accounting ticks.")
        #expect(measured > 0)
        #expect(abs(measured - reference) <= reference * 0.2,
                "Calibrated clock measured \(measured) ms against the scheduler's \(reference) ms.")
    }
}
#endif
