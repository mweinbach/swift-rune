import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

@Suite("VirtualDesktop, Composite & Reopen Parity")
struct VirtualDesktopTests {

    private final class MockMember: DesktopMember {
        let key: String
        var frame: [Float]
        var visible: Bool
        var clickThrough: Bool
        var onTop: Bool
        var cornerRadius: Float
        var hasShadow: Bool
        var keepRunning: Bool = false
        var isMain: Bool = true
        var finished: Bool = false

        var focusedCalls: [Bool] = []
        var inputs: [(DesktopInputKind, Float, Float)] = []
        var leaves: Int = 0
        var closes: Int = 0
        var reopenRuns: Int = 0
        var hiddenAt: UInt64?
        var renderedPixels: [UInt8]

        init(
            key: String,
            frame: [Float],
            visible: Bool = true,
            clickThrough: Bool = false,
            onTop: Bool = false,
            cornerRadius: Float = 0,
            hasShadow: Bool = false,
            fillRGBA: [UInt8] = [200, 100, 50, 255]
        ) {
            self.key = key
            self.frame = frame
            self.visible = visible
            self.clickThrough = clickThrough
            self.onTop = onTop
            self.cornerRadius = cornerRadius
            self.hasShadow = hasShadow
            let pw = max(1, Int(frame[2]))
            let ph = max(1, Int(frame[3]))
            var bytes = [UInt8](repeating: 0, count: pw * ph * 4)
            for i in 0..<(pw * ph) {
                bytes[i * 4 + 0] = fillRGBA[0]
                bytes[i * 4 + 1] = fillRGBA[1]
                bytes[i * 4 + 2] = fillRGBA[2]
                bytes[i * 4 + 3] = fillRGBA[3]
            }
            self.renderedPixels = bytes
        }

        func start(desktop: VirtualDesktop) {}
        func drain(desktop: VirtualDesktop, t: Double) -> DesktopChanges { DesktopChanges() }
        var hasPending: Bool { false }
        var isStale: Bool { false }
        func advance(dt: Double) {}
        func setFocused(_ focused: Bool) { focusedCalls.append(focused) }
        func input(_ kind: DesktopInputKind, at localPt: (Float, Float)) {
            inputs.append((kind, localPt.0, localPt.1))
        }
        func leave() { leaves += 1 }
        func find(key: String) -> (Float, Float)? { nil }
        func pointer() -> (Float, Float)? { nil }
        func reopenCandidate() -> DesktopReopenCandidate {
            DesktopReopenCandidate(reopenable: !finished, visible: visible, minimized: false, hiddenAt: hiddenAt, main: isMain)
        }
        func runReopenHook(hasVisibleWindows: Bool) -> Bool {
            reopenRuns += 1
            return true
        }
        func reopen() -> DesktopChanges {
            visible = true
            return DesktopChanges(front: true, keys: true)
        }
        func backdropDark() -> Bool? { nil }
        func treeJSON(at t: Double) -> [String: Any] { ["key": key] }
        func renderFrame(scale: Float) -> Frame? {
            let pw = max(1, Int(frame[2]))
            let ph = max(1, Int(frame[3]))
            return Frame(width: pw, height: ph, rgba: renderedPixels)
        }
    }

    // MARK: - VirtualDisplay & VirtualDesktop (virtual_desktop/displays.rs)

    @Test("VirtualDesktop: parses displays & pointer from script and routes openAt / placeOverlay")
    func displaysFromScriptAndPlacement() throws {
        let json = """
        {
          "displays": [
            { "id": 10, "frame": [0, 0, 1280, 800], "scale": 2.0 },
            { "id": 20, "frame": [1280, 0, 1440, 900], "scale": 1.0, "primary": true }
          ],
          "pointer": [1320, 40]
        }
        """
        let desktop = try VirtualDesktop.fromScript(jsonData: Data(json.utf8), scale: 2.0)
        #expect(desktop.displays.count == 2)
        #expect(desktop.primaryDisplay.id == 20)
        #expect(desktop.pointer?.0 == 1320)

        let atPrimary = desktop.displayAt(nil)
        #expect(atPrimary.id == 20)

        // Centered on display 20 when position == nil
        let centered = desktop.openAt(position: nil, size: (400, 300))
        #expect(centered == [1280 + 520, 300, 400, 300])

        // Clamped when opened near right edge of display 10
        let clamped = desktop.openAt(position: (1200, 750), size: (200, 100))
        #expect(clamped[0] + clamped[2] <= 1280)
        #expect(clamped[1] + clamped[3] <= 800)

        // placeOverlay onto primary display top edge
        let (dId, overlayFrame) = desktop.placeOverlay(
            requested: .primary,
            placement: .edge(.top, margin: 16),
            size: (200, 100)
        )
        #expect(dId == 20)
        #expect(overlayFrame[2] == 200 && overlayFrame[3] == 100)
        #expect(overlayFrame[1] == 16)
        #expect(overlayFrame[0] >= 1280 && overlayFrame[0] + overlayFrame[2] <= 1280 + 1440)
    }

    @Test("VirtualDesktop: invalid scripts report clear errors")
    func displaysInvalidScriptErrors() {
        #expect(throws: VirtualDesktopError.self) {
            _ = try VirtualDesktop.fromScript(jsonData: Data("{\"displays\": []}".utf8), scale: 2.0)
        }
        #expect(throws: VirtualDesktopError.self) {
            _ = try VirtualDesktop.fromScript(jsonData: Data("{\"displays\": [{\"frame\": [0,0,0,100]}]}".utf8), scale: 2.0)
        }
    }

    // MARK: - DesktopComposite (virtual_desktop/composite.rs)

    @Test("DesktopComposite: pixels clamp to maxSide and compositeFrame paints front window over backdrop")
    func compositePixelsAndRender() {
        #expect(DesktopComposite.pixels(size: (1920, 1080), scale: 2.0, maxSide: 1024) == nil)
        let dims = DesktopComposite.pixels(size: (512, 288), scale: 2.0, maxSide: 1024)
        #expect(dims != nil)
        if let d = dims {
            #expect(d.0 == 1024 && d.1 == 576)
        }

        let back = MockMember(key: "back", frame: [20, 20, 60, 60], fillRGBA: [0, 0, 255, 255])
        let front = MockMember(key: "front", frame: [40, 40, 60, 60], onTop: true, fillRGBA: [255, 0, 0, 255])
        let hidden = MockMember(key: "hidden", frame: [0, 0, 100, 100], visible: false, fillRGBA: [0, 255, 0, 255])

        let desk = VirtualDesk(members: [front, back, hidden], origin: (0, 0), scale: 1.0)
        // onTop pushes front after back in zOrder
        #expect(desk.zOrder.first == 1)
        #expect(desk.zOrder.last == 0)

        let backdrop = [UInt8](repeating: 30, count: 120 * 120 * 4)
        let out = desk.renderCompositeFrame(backdropRGBA: backdrop, width: 120, height: 120)
        #expect(out.width == 120 && out.height == 120)

        // (50, 50) lies in overlap of back & front -> front (red) wins
        let pOverlap = out.pixel(x: 50, y: 50)
        #expect(pOverlap.x > 200 && pOverlap.z < 50)

        // (25, 25) lies only in back -> blue
        let pBack = out.pixel(x: 25, y: 25)
        #expect(pBack.z > 200 && pBack.x < 50)

        // (5, 5) lies outside visible windows -> hidden doesn't paint -> backdrop gray (~30)
        let pBackdrop = out.pixel(x: 5, y: 5)
        #expect(pBackdrop.x == 30 && pBackdrop.y == 30 && pBackdrop.z == 30)
    }

    // MARK: - VirtualDesk Z-Order, Pointer Capture, Backdrop Click & OnClose

    @Test("VirtualDesk: pointer capture holds across release until move, backdrop click deactivates app keeping key")
    func pointerCaptureAndBackdropDeactivate() {
        let a = MockMember(key: "a", frame: [10, 10, 100, 100])
        let b = MockMember(key: "b", frame: [150, 10, 100, 100])
        let desk = VirtualDesk(members: [a, b])

        // Initial key is topmost visible (b is last in default order [0, 1])
        #expect(desk.focus.keyIndex == 1)
        #expect(desk.focus.active == true)

        // Click inside a (at 50, 50)
        desk.pointerInput(kind: .down(), at: (50, 50))
        #expect(desk.focus.keyIndex == 0)
        #expect(desk.pointer == .pressed(0))

        // Drag off a into b and release -> capture delivers Up to a with a's local coordinates!
        desk.pointerInput(kind: .up(), at: (170, 50))
        #expect(a.inputs.last?.0.isUp == true)
        #expect(b.inputs.isEmpty)
        #expect(desk.pointer == .over(0))

        // Subsequent move hits b cleanly
        desk.pointerInput(kind: .move, at: (170, 50))
        #expect(a.leaves == 1)
        #expect(desk.pointer == .over(1))

        // Backdrop click deactivates app while preserving keyIndex == 0
        desk.pointerInput(kind: .down(), at: (400, 400))
        #expect(desk.focus.keyIndex == 0)
        #expect(desk.focus.active == false)
    }

    @Test("DesktopWindow & DesktopReopen: onClose runs once on close and reopen picks main/hidden priority")
    func desktopWindowOnCloseAndReopen() {
        nonisolated(unsafe) var closeCalls = 0
        let app = App<Int>(
            title: "Win",
            size: Vec2(200, 150),
            state: 0,
            view: { s, _ in col().size(200, 150).child(text("v=\(s)")) }
        )
        .onClose { _, _ in
            closeCalls += 1
            return true
        }
        let win = DesktopWindow<Int>(key: "main", app: app, scale: 1.0)
        win.start(desktop: .single(scale: 1.0))
        win.close()
        win.close()
        #expect(closeCalls == 1)
        #expect(win.life.isFinished)

        // DesktopReopen target priority per reopen.rs:39: minimized first, then most recently hidden, then main
        let candidates = [
            DesktopReopenCandidate(reopenable: true, visible: false, minimized: false, hiddenAt: 10, main: false),
            DesktopReopenCandidate(reopenable: true, visible: false, minimized: true, hiddenAt: 99, main: true),
            DesktopReopenCandidate(reopenable: true, visible: false, minimized: false, hiddenAt: 50, main: true),
        ]
        #expect(!DesktopReopen.hasVisible(candidates))
        #expect(DesktopReopen.target(candidates) == 1)
        let hiddenOnly = [
            DesktopReopenCandidate(reopenable: true, visible: false, minimized: false, hiddenAt: 10, main: false),
            DesktopReopenCandidate(reopenable: true, visible: false, minimized: false, hiddenAt: 50, main: true),
        ]
        #expect(DesktopReopen.target(hiddenOnly) == 1)
    }
}
