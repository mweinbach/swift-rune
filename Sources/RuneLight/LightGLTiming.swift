#if canImport(CRuneGL)
import CRuneGL

/// Maps the completed intervals of one GPU lighting frame onto the common diagnostics.
final class LightGLTiming {
    enum Stage: UInt32 {
        case raster, field, shadows, scene, fluence, firstCascade
    }
    private var handle: OpaquePointer?
    private var intervals = [RuneGLTimerInterval](repeating: .init(), count: Int(RuneGLTimerMaxIntervals))

    init?(resolve: RuneGLResolve) {
        guard let handle = rune_gl_timer_open(resolve) else { return nil }
        self.handle = handle
    }

    func begin() -> Bool { rune_gl_timer_begin(handle) != 0 }
    func mark(_ label: UInt32) { rune_gl_timer_mark(handle, label) }
    func end() { rune_gl_timer_end(handle) }
    func cancel() { rune_gl_timer_cancel(handle) }

    func close(contextIsCurrent: Bool) {
        guard let handle else { return }
        if contextIsCurrent { rune_gl_timer_close(handle) } else { rune_gl_timer_abandon(handle) }
        self.handle = nil
    }
    deinit { close(contextIsCurrent: true) }

    func read(wait: Bool) -> LightTimings? {
        let capacity = Int32(intervals.count)
        let count = rune_gl_timer_read(handle, wait ? 1 : 0, &intervals, capacity)
        guard count > 0 else { return nil }
        var timing = LightTimings()
        for interval in intervals.prefix(Int(count)) {
            let ms = interval.milliseconds
            timing.total += ms
            switch Stage(rawValue: interval.label) {
            case .raster: timing.raster += ms
            case .field: timing.field += ms
            case .shadows: timing.shadows += ms
            case .scene: timing.giScene += ms
            case .fluence: timing.fluence += ms
            case .firstCascade, nil:
                let index = Int(interval.label) - Int(Stage.firstCascade.rawValue)
                if timing.cascades.indices.contains(index) { timing.cascades[index] += ms }
            }
        }
        timing.gi = timing.giScene + timing.fluence + timing.cascades.reduce(0, +)
        return timing
    }
}
#endif
