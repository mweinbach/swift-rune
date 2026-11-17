import Foundation
import Rune

// The private-desktop driver sends this window middle-button and key messages.
let observation = URL(fileURLWithPath: "middle-scroll-state.txt")
var frame = 0
try App<Void>("Rune middle scroll probe", size: Vec2(220, 160), init: {}, view: { _, _ in
    col().key("viewport").wFull().hFull().scroll(stickBottom: false)
        .child(col().wFull().h(4000).shrink(0).child(text("Scroll this surface")))
})
.onFrameDrawn { (runtime: Runtime<Void>) in
    frame += 1
    let cursorBytes: Int
    if case let .image(image) = runtime.currentCursor() { cursorBytes = image.bytes.count } else { cursorBytes = 0 }
    let point = runtime.pointerPosition
    let wake = runtime.nextWakeDeadline(after: runtime.currentTime) ?? -1
    let sample = "\(runtime.scrollOffset(forKey: "viewport").y) \(cursorBytes == 0 ? 0 : 1) \(frame) \(point.x) \(point.y) \(cursorBytes) \(wake)"
    // A reader may see a partial sample. It retries and validates every field.
    try? sample.write(to: observation, atomically: false, encoding: .utf8)
}
.run(arguments: [])
