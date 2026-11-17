#if (os(macOS) || os(Linux) || os(Windows)) && canImport(CRuneOffscreenGL)
import Testing
@testable import Rune

@MainActor
@Suite("OpenGL runtime frames")
struct PortableGLRuntimeSceneTests {
    @Test("A click repaints the control and its platform-shaped label")
    func interactiveTextControl() throws {
        let runtime = Runtime<Bool>(state: false, viewport: Vec2(112, 52), pixelScale: 1) { selected, _ in
            col().wFull().hFull().center().bg(.black)
                .child(el().key("control").focusable(true).size(100, 36).rounded(8)
                    .center().bg(selected ? Color.srgb(0.15, 0.43, 0.72) : Color.srgb(0.31, 0.28, 0.38))
                    .onClick { $0.toggle() }
                    .child(text(selected ? "Lights on" : "Lights off").color(.white)))
        }
        try withTestGLRenderer { _, render in
            let initial = runtime.frame(at: 0.0)
            try #require(initial.primitives.contains { $0.kind == .glyph })
            let first = try render(initial)
            let firstDiff = RuneRef.compare(scene: initial, expected: try RuneRef.render(initial), actual: first)
            #expect(firstDiff.passed, "\(firstDiff)")

            let center = Vec2(56, 26)
            runtime.pointerDown(at: center, at: 0.1)
            runtime.pointerUp(at: center, at: 0.15)
            try #require(runtime.state)
            let updated = runtime.frame(at: 0.2)
            let second = try render(updated)
            let secondDiff = RuneRef.compare(scene: updated, expected: try RuneRef.render(updated), actual: second)
            #expect(secondDiff.passed, "\(secondDiff)")
            #expect(first.rgba != second.rgba)
        }
    }
}
#endif
