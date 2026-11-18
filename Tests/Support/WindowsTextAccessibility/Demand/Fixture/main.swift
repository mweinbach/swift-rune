import Foundation
import Rune

let app = App(title: "Rune accessibility demand", size: Vec2(320, 200), state: 0) { revision, _ in
    col().key("viewport").sizeFull().scrollY()
        .child(el().h(160).wFull().shrink(0))
        .child(text("Demand revision \(revision)").key("demand-target").role(.button)
            .label("Demand revision \(revision)").h(32).wFull().shrink(0))
        .child(el().h(600).wFull().shrink(0))
}
var scrolled = false
var signaled = false
try app.onFrameDrawn { runtime in
    guard !signaled else { return }
    if runtime.state < 6 {
        runtime.update { revision, _ in revision += 1 }
    } else if !scrolled {
        scrolled = true
        runtime.wheel(WheelEvent(dx: 0, dy: -80), at: Vec2(100, 100), now: runtime.currentTime)
    } else if let target = runtime.element(byKey: "demand-target"),
              target.label == "Demand revision 6", abs(target.rect[1] - 80) < 0.1 {
        // The external process watches the ordinary window caption before making its first UIA call.
        let y = Int((target.visible[1] * runtime.pixelScale).rounded())
        let height = Int((target.visible[3] * runtime.pixelScale).rounded())
        signaled = true
        runtime.update { _, tx in tx.setTitle("Rune accessibility ready \(y) \(height)") }
        return
    }
    let wake = runtime.waker
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(1)) { wake.wake() }
}.run(arguments: [])
