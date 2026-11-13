import Foundation
import Testing
@testable import Rune

@Suite("Slice 4 Input Wave 1B Parity Tests (DragPhase/Cancel/Release, Secondary, ContextMenuKey, EventLog, Pointer APIs)")
struct Slice4InputWave1BTests {

    // MARK: - Drag Cancel (`tests/drag_cancel.rs` - all 4 tests)

    @Test("drag_cancel: escape, physical escape, focus loss, and uncancelled release")
    @MainActor
    func dragCancelParity() {
        struct S {
            var drags: [(DragPhase, Bool, Float)] = []
            var keys: [Key] = []
            var presses = 0
        }
        func makeHeld() -> Runtime<S> {
            let rt = Runtime(
                state: S(),
                viewport: Vec2(300, 300),
                pixelScale: 1.0,
                onKey: { s, ev, _ in s.keys.append(ev.key); return true },
                view: { _, _ in
                    col().wFull().hFull().child(
                        el().key("handle").w(100).h(40)
                            .onDrag { s, d, _ in s.drags.append((d.phase, d.cancelled(), d.delta.x)) }
                            .onClick { s in s.presses += 1 }
                    )
                }
            )
            _ = rt.frame(at: 0.0)
            rt.pointerDown(at: Vec2(10, 10), at: 0.01)
            rt.pointerMove(to: Vec2(40, 10), at: 0.02)
            _ = rt.frame(at: 0.03)
            return rt
        }
        let esc = KeyEvent(key: .escape, mods: .none)

        // 1. escape_cancels_a_held_drag_and_the_release_does_nothing
        do {
            let rt = makeHeld()
            _ = rt.keyDown(esc, at: 0.04)
            _ = rt.frame(at: 0.05)
            #expect(rt.state.drags.last.map { $0 == (.up, true, 30.0) } == true)
            #expect(rt.state.keys.isEmpty)
            rt.pointerMove(to: Vec2(60, 10), at: 0.06)
            rt.pointerUp(at: Vec2(60, 10), at: 0.07)
            _ = rt.frame(at: 0.08)
            #expect(rt.state.drags.filter { $0.0 == .up }.count == 1)
            #expect(rt.state.presses == 0)
        }

        // 2. losing_window_focus_cancels_a_held_drag
        do {
            let rt = makeHeld()
            rt.dispatchFocus(true, at: 0.04)
            rt.dispatchFocus(false, at: 0.05)
            _ = rt.frame(at: 0.06)
            #expect(rt.state.drags.last.map { $0 == (.up, true, 30.0) } == true)
            rt.pointerUp(at: Vec2(40, 10), at: 0.07)
            _ = rt.frame(at: 0.08)
            #expect(rt.state.drags.filter { $0.0 == .up }.count == 1)
        }

        // 3. physical_escape_cancels_a_held_drag_too
        do {
            let rt = makeHeld()
            _ = rt.physicalWithFallback(.key(key: .escape, mods: .none, pressed: true, repeat: false), fallbackKey: nil, at: 0.04)
            _ = rt.frame(at: 0.05)
            #expect(rt.state.drags.last.map { $0 == (.up, true, 30.0) } == true)
            #expect(rt.state.keys.isEmpty)
            rt.pointerUp(at: Vec2(40, 10), at: 0.06)
            _ = rt.frame(at: 0.07)
            #expect(rt.state.drags.filter { $0.0 == .up }.count == 1)
        }

        // 4. a_release_ends_uncancelled_and_escape_without_a_drag_passes_through
        do {
            let rt = makeHeld()
            rt.pointerUp(at: Vec2(40, 10), at: 0.04)
            _ = rt.frame(at: 0.05)
            #expect(rt.state.drags.last.map { $0 == (.up, false, 30.0) } == true)
            _ = rt.keyDown(esc, at: 0.06)
            _ = rt.frame(at: 0.07)
            #expect(rt.state.keys == [.escape])
        }
    }

    // MARK: - Drag Release (`tests/drag_release.rs` - all 3 tests)

    @Test("drag_release: tap animates through release, move on release snaps, still release emits only Up")
    @MainActor
    func dragReleaseParity() {
        struct S {
            var value: Float = 0
            var phases: [DragPhase] = []
        }
        func makeRt() -> Runtime<S> {
            let rt = Runtime(state: S(), viewport: Vec2(400, 100), pixelScale: 2.0) { s, _ in
                el().key("root").w(400).h(100).child(
                    el().key("slider").w(300).h(20)
                        .onDrag { s, d, tx in
                            s.phases.append(d.phase)
                            switch d.phase {
                            case .down:
                                s.value = d.local.x
                            case .move:
                                s.value = d.local.x
                                tx.instant()
                            case .up:
                                break
                            }
                        }
                        .child(el().key("knob").w(20).h(20).absolute(x: s.value, y: 0).animateLayout(Spring(duration: 0.25, bounce: 0.0)))
                )
            }
            _ = rt.frame(at: 0.0)
            return rt
        }
        func knobX(_ rt: Runtime<S>) -> Float {
            rt.element(byKey: "knob")!.rect[0]
        }

        // 1. a_tap_animates_through_its_release
        do {
            let rt = makeRt()
            var t = 0.0
            rt.pointerMove(to: Vec2(250, 10), at: t)
            rt.pointerDown(at: Vec2(250, 10), at: t)
            for _ in 0..<3 { t += 1.0 / 120.0; _ = rt.frame(at: t) }
            let before = knobX(rt)
            rt.pointerUp(at: Vec2(250, 10), at: t)
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            let after = knobX(rt)
            #expect(rt.state.phases == [.down, .up])
            #expect(after > before && after < 249.0)
            _ = rt.frame(at: t + 1.0)
            #expect(knobX(rt) == 250.0)
        }

        // 2. a_release_somewhere_new_still_moves
        do {
            let rt = makeRt()
            rt.pointerMove(to: Vec2(50, 10), at: 0.01)
            rt.pointerDown(at: Vec2(50, 10), at: 0.02)
            _ = rt.frame(at: 1.02)
            rt.pointerUp(at: Vec2(120, 10), at: 1.03)
            _ = rt.frame(at: 1.03 + 1.0 / 120.0)
            #expect(rt.state.phases == [.down, .move, .up])
            #expect(knobX(rt) == 120.0)
        }

        // 3. a_drag_that_comes_to_rest_releases_without_a_move
        do {
            let rt = makeRt()
            rt.pointerMove(to: Vec2(50, 10), at: 0.01)
            rt.pointerDown(at: Vec2(50, 10), at: 0.02)
            _ = rt.frame(at: 1.02)
            rt.pointerMove(to: Vec2(90, 10), at: 1.03)
            _ = rt.frame(at: 1.03 + 1.0 / 120.0)
            rt.pointerUp(at: Vec2(90, 10), at: 1.04)
            _ = rt.frame(at: 1.04 + 1.0 / 120.0)
            #expect(rt.state.phases == [.down, .move, .up])
            #expect(knobX(rt) == 90.0)
        }
    }

    // MARK: - Secondary Capture & ContextMenuKey (`secondary.rs`, `context_menu_key.rs`, `pointer_hit.rs:243`)

    @Test("Secondary gesture capture, claim classification, abandon, and link target matching")
    @MainActor
    func secondaryCaptureAndClaim() {
        struct S {
            var menus: [String] = []
            var edit = TextEdit("wroong word")
        }
        let rt = Runtime(state: S(), viewport: Vec2(300, 260), pixelScale: 1.0) { _, _ in
            col().children([
                el().key("appBtn").w(100).h(40)
                    .onSecondaryClick { s, p, _ in s.menus.append("app:\(Int(p.local.x))") },
                textInput(key: "field", \S.edit).w(150).h(30),
                text("selectable copy text").key("sel").w(200).h(30).selectable(),
                el().key("blank").w(100).h(30),
                text("see the docs").link(TextLink(8..<12, id: "docs"))
                    .key("links").w(200).h(30)
                    .onLinkSecondary { s, id, _, _ in s.menus.append("link:\(id)") },
            ])
        }
        _ = rt.frame(at: 0.0)

        // App element -> "app", delivered on secondaryUp
        let appPt = rt.find("appBtn")!
        rt.secondaryDown(at: appPt, at: 0.1)
        #expect(rt.secondaryClaim() == "app")
        #expect(rt.pressing())
        #expect(rt.state.menus.isEmpty)
        rt.secondaryUp(at: appPt, at: 0.12)
        #expect(rt.state.menus == ["app:50"])
        #expect(!rt.pressing())

        // Abandon drops the secondary gesture silently
        rt.secondaryDown(at: appPt, at: 0.2)
        rt.secondaryAbandon()
        #expect(rt.secondaryClaim() == "")
        rt.secondaryUp(at: appPt, at: 0.22)
        #expect(rt.state.menus == ["app:50"])

        // Field & selectable text & blank claim classifications
        let fieldPt = rt.find("field")!
        rt.secondaryDown(at: fieldPt, at: 0.3)
        #expect(rt.secondaryClaim() == "field")
        rt.secondaryUp(at: fieldPt, at: 0.31)

        let selPt = rt.find("sel")!
        rt.secondaryDown(at: selPt, at: 0.4)
        #expect(rt.secondaryClaim() == "text")
        rt.secondaryUp(at: selPt, at: 0.41)
        _ = rt.frame(at: 0.42)
        #expect(rt.takePopup() != nil)

        let blankPt = rt.find("blank")!
        rt.secondaryDown(at: blankPt, at: 0.5)
        #expect(rt.secondaryClaim() == "")
        rt.secondaryUp(at: blankPt, at: 0.51)

        // Link down + move off opens nothing; same link opens link menu
        if let linkPt = rt.find("docs") {
            rt.secondaryDown(at: linkPt, at: 0.6)
            #expect(rt.secondaryClaim() == "app")
            rt.secondaryUp(at: Vec2(linkPt.x + 150, linkPt.y), at: 0.61)
            #expect(rt.state.menus == ["app:50"])

            rt.secondaryDown(at: linkPt, at: 0.7)
            rt.secondaryUp(at: linkPt, at: 0.71)
            #expect(rt.state.menus == ["app:50", "link:docs"])
        } else {
            Issue.record("expected link docs center")
        }
    }

    @Test("context_menu_key: active focused link/row menus respond to Menu and Shift+F10, inert subtree ignores them")
    @MainActor
    func contextMenuKeyParity() {
        struct S {
            var menus: [(String, Vec2)] = []
            var isInert = false
        }
        let rt = Runtime(state: S(), viewport: Vec2(300, 100), pixelScale: 1.0) { s, _ in
            col().key("row").w(300).h(100).inert(s.isInert)
                .onSecondaryClick { s, p, _ in s.menus.append(("row", p.window)) }
                .child(
                    text("see the docs").link(TextLink(8..<12, id: "docs"))
                        .key("para").w(200)
                        .onLinkSecondary { s, id, p, _ in s.menus.append((id, p.window)) }
                )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        _ = rt.keyDown(KeyEvent(key: .tab, mods: .none), at: 0.01)
        for _ in 0..<30 { t += 1.0 / 60.0; _ = rt.frame(at: t) }
        #expect(rt.focusedKey == "docs")

        // Active focused link fires onLinkSecondary on Menu & Shift+F10
        _ = rt.keyDown(KeyEvent(key: .contextMenu, mods: .none), at: t + 0.01)
        _ = rt.keyDown(KeyEvent(key: .f(10), mods: Mods(shift: true)), at: t + 0.02)
        #expect(rt.state.menus.map(\.0) == ["docs", "docs"])

        // Inert subtree blocks Menu & Shift+F10
        rt.update(at: t + 0.025) { s, _ in s.isInert = true }
        _ = rt.frame(at: t + 0.028)
        rt.state.menus.removeAll()
        _ = rt.keyDown(KeyEvent(key: .contextMenu, mods: .none), at: t + 0.03)
        _ = rt.keyDown(KeyEvent(key: .f(10), mods: Mods(shift: true)), at: t + 0.04)
        #expect(rt.state.menus.isEmpty)
    }

    // MARK: - Event Markers (`event_markers.rs` - both tests)

    @Test("event_markers: quiet when disabled unless tracing, and bounded at CAP=512")
    @MainActor
    func eventMarkersParity() {
        func makeRt() -> Runtime<Int> {
            let rt = Runtime(state: 0, viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in
                el().key("tap").w(40).h(40).onClick { $0 += 1 }
            }
            _ = rt.frame(at: 0.0)
            return rt
        }
        func tap(_ rt: Runtime<Int>, t: inout Double) {
            rt.pointerMove(to: Vec2(20, 20), at: t)
            rt.pointerDown(at: Vec2(20, 20), at: t + 0.001)
            rt.pointerUp(at: Vec2(20, 20), at: t + 0.002)
            t += 0.5
            _ = rt.frame(at: t)
        }
        func pressMarkers(_ rt: Runtime<Int>) -> Int {
            rt.events.filter { $0.hasPrefix("press ") }.count
        }

        // 1. a_live_window_records_no_input_markers_unless_tracing
        do {
            let rt = makeRt()
            rt.recordEvents = false
            var t = 0.01
            tap(rt, t: &t)
            #expect(rt.state == 1)
            #expect(rt.events.isEmpty)
            rt.traceChannelsActive = true
            tap(rt, t: &t)
            #expect(rt.state == 2)
            #expect(pressMarkers(rt) == 1)
        }

        // 2. unread_input_markers_stay_bounded
        do {
            let rt = makeRt()
            var t = 0.01
            let taps = RuntimeEventLog.capacity + 40
            for _ in 0..<taps { tap(rt, t: &t) }
            #expect(rt.state == taps)
            #expect(rt.events.count <= RuntimeEventLog.capacity)
            #expect(pressMarkers(rt) >= RuntimeEventLog.capacity / 2)
            #expect(rt.events.last?.hasPrefix("press ") == true)
        }
    }

    // MARK: - Pointer & Runtime Inspection APIs (`pointer.rs`, `drop.rs`, `keys.rs`, `zoom.rs`, `drag_out_host.rs`)

    @Test("Runtime inspection APIs: hasFocus, pressing, pointer, inputScale, draggingFiles, windowMoved, pointerLeave, cancelPointer, pointerReleaseLost, repeatKey")
    @MainActor
    func runtimePointerAndInspectionAPIs() {
        struct S {
            var drags: [(DragPhase, Bool, Vec2)] = []
            var repeats = 0
            var clicks = 0
        }
        let rt = Runtime(state: S(), viewport: Vec2(200, 200), pixelScale: 2.0) { _, _ in
            col().children([
                el().key("drag").w(80).h(40)
                    .onDrag { s, d, _ in s.drags.append((d.phase, d.cancelled(), d.delta)) }
                    .onClick { s in s.clicks += 1 },
                el().key("btn").w(80).h(40).focusable(true)
                    .onKey { s, ev, _ in
                        if ev.key == .text("a") { s.repeats += 1; return true }
                        return false
                    },
            ])
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.inputScale() == 2.0)
        #expect(!rt.hasFocus())
        #expect(!rt.pressing())
        #expect(rt.pointer() == nil)
        #expect(!rt.draggingFiles())
        #expect(rt.osDragSupported)
        rt.setOsDrag(false)
        #expect(!rt.osDragSupported)
        #expect(!rt.dragEndsPending)

        // Focus & repeatKey
        let btnPt = rt.find("btn")!
        rt.pointerDown(at: btnPt, at: 0.1)
        rt.pointerUp(at: btnPt, at: 0.11)
        #expect(rt.hasFocus())
        #expect(rt.repeatKey(KeyEvent(key: .text("a"), mods: .none), at: 0.12))
        #expect(rt.state.repeats == 1)

        // pointer(), pressing(), pointerLeave while held, windowMoved delta, pointerReleaseLost
        rt.pointerMove(to: Vec2(20, 20), at: 0.2)
        #expect(rt.pointer() == Vec2(20, 20))
        rt.pointerDown(at: Vec2(20, 20), at: 0.21)
        #expect(rt.pressing())
        rt.windowMoved(dx: 5, dy: 0)
        #expect(rt.pointer() == Vec2(15, 20))
        rt.pointerLeave(at: 0.22)
        #expect(rt.pointer() == Vec2(15, 20)) // retained while pressing
        rt.pointerReleaseLost(at: Vec2(35, 20), at: 0.23)
        #expect(!rt.pressing())
        #expect(rt.pointer() == nil) // left after release!
        #expect(rt.state.drags.last.map { $0.0 == .up && $0.1 == true && $0.2 == Vec2(20, 0) } == true)

        // cancelPointer drops drag & file drag & pointer
        rt.pointerDown(at: Vec2(20, 20), at: 0.4)
        rt.cancelPointer(at: 0.41)
        #expect(!rt.pressing())
        #expect(rt.pointer() == nil)
        #expect(!rt.draggingFiles())
    }
}
