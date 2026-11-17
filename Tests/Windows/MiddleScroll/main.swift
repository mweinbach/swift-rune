import Foundation
import Rune

// The private-desktop driver sends this window middle-button and key messages.
let observation = URL(fileURLWithPath: "middle-scroll-state.txt")
var previous = ""
try App<Void>("Rune middle scroll probe", size: Vec2(220, 160), init: {}, view: { _, _ in
    col().key("viewport").wFull().hFull().scroll(stickBottom: false)
        .child(col().wFull().h(4000).shrink(0).child(text("Scroll this surface")))
})
.onFrameDrawn { (runtime: Runtime<Void>) in
    let pan: Bool
    if case .image = runtime.currentCursor() { pan = true } else { pan = false }
    let sample = "\(runtime.scrollOffset(forKey: "viewport").y) \(pan ? 1 : 0)"
    if sample != previous {
        try? sample.write(to: observation, atomically: true, encoding: .utf8)
        previous = sample
    }
}
.run(arguments: [])
