import Dispatch
import Foundation
import Rune
import Synchronization

@main
struct SurfaceApp {
    static func main() throws {
        let surface = NativeSurface()
        let red = try ByteFrame(width: 1, height: 1, format: .rgba, color: .srgb, planes: [Data([255, 0, 0, 255])])
        let green = try ByteFrame(width: 1, height: 1, format: .rgba, color: .srgb, planes: [Data([0, 255, 0, 255])])
        try surface.pushBytes(red, frameId: 1)
        let secondPresented = DispatchSemaphore(value: 0)
        let firstPending = Atomic(true)
        let app = App<Int>(title: "Rune idle surface", size: Vec2(96, 96), state: 0) { _, _ in
            nativeSurface(surface, .stretch).sizeFull()
        }.onFrameEncoded { report in
            if report.outcome == .drawn && surface.timing()?.frameId == 2 { secondPresented.signal() }
        }
        let handle = app.handle()
        surface.setObserver { timing in
            guard timing.completedAt != nil else { return }
            precondition(!Thread.isMainThread, "surface callback occupied the rendering thread")
            if timing.frameId == 1 && firstPending.exchange(false, ordering: .relaxed) {
                try! surface.pushBytes(green, frameId: 2)
                handle.update { state, _ in state += 1 }
                precondition(secondPresented.wait(timeout: .now() + 10) == .success,
                             "second frame was unable to present while the first observer was held")
            } else if timing.frameId == 2 {
                handle.quit()
            }
        }
        try RuneApp.run(app)
        surface.setObserver(nil)
        let (submitted, completed) = surface.counts()
        precondition(submitted >= 2 && submitted == completed && surface.timing()?.frameId == 2
                     && surface.timing()?.completedAt != nil, "window closed with an unfinished frame")
        print("PASS RuneApp presented a second frame during the first observer and completed its idle frame")
    }
}
