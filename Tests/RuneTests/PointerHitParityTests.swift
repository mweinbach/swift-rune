import Foundation
import Testing
@testable import Rune

/// Ports of `crates/rune/src/runtime/tests/pointer_hit.rs` press / secondary / double-press /
/// overlay-observation tests and `runtime/input_click_tests.rs:243` (Shift+click).
@Suite("pointer_hit.rs + input_click_tests.rs parity: double press, secondary press, observePointer, Shift+click")
@MainActor
struct PointerHitParityTests {

    // MARK: - pointer_hit.rs:60 `overlay_idle_pointer_does_not_request_unchanged_frames`

    @Test("overlay_idle_pointer_does_not_request_unchanged_frames")
    func overlayIdlePointerDoesNotRequestUnchangedFrames() {
        let rt = Runtime(state: UInt32(0), viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in
            el().child(
                el().w(40).h(20).hit()
                    // `on_hover` runs when the pointer enters.
                    .onHover { n, inside, _ in if inside { n += 1 } }
            )
        }
        _ = rt.frame(at: 0)
        #expect(rt.observePointer(at: Vec2(5, 5), at: 0), "enter must run the hover callback")
        _ = rt.frame(at: 0)
        #expect(rt.state == 1)
        #expect(!rt.observePointer(at: Vec2(6, 5), at: 0), "movement within an unchanged chip needs no frame")
        #expect(!rt.observePointer(at: Vec2(6, 5), at: 0), "duplicate monitor/winit observations need no frame")
        #expect(!rt.observePointer(at: Vec2(90, 90), at: 0))
        #expect(!rt.observePointer(at: Vec2(200, 90), at: 0), "movement outside the canvas needs no frame")
        #expect(!rt.hasPendingInput)
    }

    // MARK: - pointer_hit.rs:136 `secondary_only_children_preserve_primary_click_hover_and_background_blur`

    @Test("secondary_only_children_preserve_primary_click_hover_and_background_blur")
    func secondaryOnlyChildrenPreservePrimaryClickHoverAndBackgroundBlur() {
        struct S: Equatable { var pressed: UInt32 = 0; var hovered: UInt32 = 0; var bare = false }
        let rt = Runtime(state: S(), viewport: Vec2(100, 100), pixelScale: 1.0) { s, _ in
            var parent: El<S> = el().key("parent").w(80).h(80)
            if !s.bare {
                parent = parent
                    .onClick { $0.pressed += 1 }
                    .onHover { s, inside, _ in if inside { s.hovered += 1 } }
            }
            return parent.child(
                el().key("child").w(40).h(40)
                    .onSecondaryClick { _, _, _ in }
            )
        }
        _ = rt.frame(at: 0)
        rt.pointerMove(to: Vec2(10, 10), at: 0)
        rt.pointerDown(at: Vec2(10, 10), at: 0)
        rt.pointerUp(at: Vec2(10, 10), at: 0)
        _ = rt.frame(at: 0)
        #expect(rt.state == S(pressed: 1, hovered: 1, bare: false))

        rt.state.bare = true
        rt.invalidate()
        _ = rt.frame(at: 0)
        // Focus sits on a field elsewhere (`Focus::On { path: "previous-input" }`).
        rt.focusedPath = "previous-input"
        rt.pointerMove(to: Vec2(10, 10), at: 0)
        rt.pointerDown(at: Vec2(10, 10), at: 0)
        #expect(rt.hoveredPath == nil)
        // `Action::Blur`: the background press takes focus away from the field.
        #expect(rt.focusedPath == nil)
        #expect(rt.blurredFocusPath == "previous-input")
        #expect(rt.secondaryTarget(at: Vec2(10, 10)) != nil)
    }

    // MARK: - pointer_hit.rs:166 `secondary_press_routes_to_ancestor_without_primary_and_cancels_outside`

    @Test("secondary_press_routes_to_ancestor_without_primary_and_cancels_outside")
    func secondaryPressRoutesToAncestorWithoutPrimaryAndCancelsOutside() {
        struct S { var pressed: UInt32 = 0; var secondary: [PointerPress] = []; var gone = false }
        let rt = Runtime(state: S(), viewport: Vec2(100, 100), pixelScale: 1.0) { s, _ in
            col().child(s.gone
                ? el()
                : el().key("parent").w(80).h(80)
                    .onSecondaryClick { s, p, _ in s.secondary.append(p) }
                    .child(el().key("child").w(40).h(40).onClick { $0.pressed += 1 }))
        }
        _ = rt.frame(at: 0)
        rt.secondaryDown(at: Vec2(10, 10), at: 0)
        rt.secondaryUp(at: Vec2(12, 12), at: 0)
        _ = rt.frame(at: 0)
        #expect(rt.state.pressed == 0)
        #expect(rt.state.secondary.map(\.window) == [Vec2(12, 12)])

        rt.secondaryDown(at: Vec2(10, 10), at: 0)
        rt.secondaryUp(at: Vec2(90, 90), at: 0)
        _ = rt.frame(at: 0)
        #expect(rt.state.secondary.count == 1)

        rt.secondaryDown(at: Vec2(10, 10), at: 0)
        rt.state.gone = true
        rt.invalidate()
        _ = rt.frame(at: 0)
        rt.secondaryUp(at: Vec2(12, 12), at: 0)
        _ = rt.frame(at: 0)
        #expect(rt.state.secondary.count == 1)
    }

    // MARK: - pointer_hit.rs:221 `a_double_press_follows_the_first_press_within_the_interval_and_tolerance`

    @Test("a_double_press_follows_the_first_press_within_the_interval_and_tolerance")
    func aDoublePressFollowsTheFirstPressWithinTheIntervalAndTolerance() {
        struct S { var presses: UInt32 = 0; var doubles: UInt32 = 0; var other: UInt32 = 0 }
        let rt = Runtime(state: S(), viewport: Vec2(300, 100), pixelScale: 1.0) { _, _ in
            row().w(300).h(100)
                .child(el().key("row").w(100).h(100)
                    .onClick { $0.presses += 1 }
                    .onDoubleClick { s, _ in s.doubles += 1 })
                .child(el().key("other").w(100).h(100).onClick { $0.other += 1 })
        }
        rt.recordEvents = true
        // The runtime's virtual clock: every frame advances it by 1/120 s.
        var t = 0.0
        func frame() {
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        func tick(_ seconds: Double) {
            for _ in 0..<Int((seconds * 120.0).rounded()) { frame() }
        }
        func click(_ p: Vec2) {
            rt.pointerMove(to: p, at: t)
            rt.pointerDown(at: p, at: t)
            frame()
            rt.pointerUp(at: p, at: t)
            frame()
        }
        func counts() -> [UInt32] { [rt.state.presses, rt.state.doubles] }
        _ = rt.frame(at: t)

        click(Vec2(50, 50))
        #expect(counts() == [1, 0], "the first press runs on_press right away")
        tick(0.1)
        click(Vec2(53, 47))
        #expect(counts() == [2, 1], "the second press inside the interval and 4 pt is a double press")
        #expect(rt.events.contains { $0.hasPrefix("double press") })
        tick(0.1)
        click(Vec2(50, 50))
        #expect(counts() == [3, 1], "a third press starts a new pair")
        tick(0.1)
        click(Vec2(50, 50))
        #expect(counts() == [4, 2])

        tick(0.1)
        click(Vec2(50, 50))
        let slow = rt.doubleClickInterval + 0.05
        tick(slow)
        click(Vec2(50, 50))
        #expect(counts() == [6, 2], "too slow")

        tick(0.6)
        click(Vec2(50, 50))
        click(Vec2(55, 50))
        #expect(counts() == [8, 2], "moved more than 4 pt")

        tick(0.6)
        click(Vec2(50, 50))
        click(Vec2(150, 50))
        click(Vec2(50, 50))
        #expect(counts() == [10, 2] && rt.state.other == 1, "a press elsewhere breaks the pair")

        tick(0.6)
        click(Vec2(50, 50))
        rt.pointerDown(at: Vec2(50, 50), at: t)
        frame()
        rt.pointerMove(to: Vec2(250, 50), at: t)
        rt.pointerUp(at: Vec2(250, 50), at: t)
        frame()
        #expect(counts() == [11, 2], "a second press released outside is cancelled")

        // A second press that drags 40 pt (still inside) and lets go 5 s later is no click.
        tick(0.6)
        click(Vec2(50, 50))
        rt.pointerDown(at: Vec2(50, 50), at: t)
        frame()
        rt.pointerMove(to: Vec2(90, 50), at: t)
        rt.pointerMove(to: Vec2(60, 50), at: t)
        tick(5.0)
        rt.pointerUp(at: Vec2(60, 50), at: t)
        frame()
        #expect(counts() == [13, 2], "a drag or a long press doesn't finish a double press")
        // Held without moving past the interval, it's no click either.
        tick(0.6)
        click(Vec2(50, 50))
        rt.pointerDown(at: Vec2(50, 50), at: t)
        let long = rt.doubleClickInterval + 0.05
        tick(long)
        rt.pointerUp(at: Vec2(50, 50), at: t)
        frame()
        #expect(counts() == [15, 2], "a long second press")
        // A first press that drags doesn't arm one.
        tick(0.6)
        rt.pointerDown(at: Vec2(50, 50), at: t)
        rt.pointerMove(to: Vec2(50, 90), at: t)
        rt.pointerMove(to: Vec2(50, 50), at: t)
        rt.pointerUp(at: Vec2(50, 50), at: t)
        frame()
        click(Vec2(50, 50))
        #expect(counts() == [17, 2], "a dragged first press")

        // Headless, a slower system setting is honoured on the same virtual clock.
        rt.doubleClickInterval = 1.0
        tick(1.1)
        click(Vec2(50, 50))
        tick(0.8)
        click(Vec2(50, 50))
        #expect(counts() == [19, 3])
    }

    // MARK: - input_click_tests.rs:243 `shift_click_extends_from_anchor_and_does_not_start_multiclick`

    struct Form {
        var single = TextEdit("make the title smaller", multiline: false)
        var multi = TextEdit("first line here\nsecond line there\nthird line end", multiline: true)
        var other = TextEdit("other words", multiline: false)
        var presses = 0
    }

    private static func formRuntime() -> Runtime<Form> {
        let style = TextStyle(size: 14, weight: 400).lh(20)
        let rt = Runtime(state: Form(), viewport: Vec2(320, 300), pixelScale: 1.0) { _, _ in
            col().wFull().hFull().p(8).gap(8)
                .child(textInput(key: "single", \Form.single).singleLine(true).font(style).w(280).h(24)
                    .onClick { $0.presses += 1 })
                .child(textInput(key: "multi", \Form.multi).font(style).w(280).h(80))
                .child(textInput(key: "other", \Form.other).singleLine(true).font(style).w(280).h(24))
        }
        _ = rt.frame(at: 0)
        return rt
    }

    /// Window point a quarter of the way across the glyph cluster at `byte` in field `key`,
    /// vertically centred on its caret (`point_at_byte` / `point_in_cluster(.., 0.25)`).
    private static func pointAtByte(_ rt: Runtime<Form>, _ key: String, _ byte: Int) throws -> Vec2 {
        let node = try #require(rt.flatNodes.first { $0.key == key })
        let lens = try #require(node.el.handlers.editLens)
        let edit = lens.get(rt.state)
        let rect = rt.presentedRectByPath[node.path] ?? node.targetRect
        let pad = node.el.layout.padding
        let resolved = ElDisplayResolver.resolveInput(el: node.el, edit: edit, innerWidth: max(0, rect.width - pad.left - pad.right))
        let shaped = rt.textSystem.shape(
            text: resolved.renderedString,
            spans: resolved.spans,
            pills: resolved.pills,
            style: resolved.style,
            maxWidth: resolved.maxWidthForShape,
            pixelScale: rt.pixelScale,
            emitGlyphs: false
        )
        let c0 = rt.textSystem.caretRect(in: shaped, utf8Offset: byte, pixelScale: rt.pixelScale)
        let c1 = rt.textSystem.caretRect(in: shaped, utf8Offset: byte + 1, pixelScale: rt.pixelScale)
        let hScroll = edit.multiline ? 0 : (rt.inputMachines.inputScroll[node.path] ?? 0)
        return Vec2(
            rect.x + pad.left + c0.x + (c1.x - c0.x) * 0.25 - hScroll,
            rect.y + pad.top + c0.y + c0.w * 0.5
        )
    }

    @Test("shift_click_extends_from_anchor_and_does_not_start_multiclick")
    func shiftClickExtendsFromAnchorAndDoesNotStartMulticlick() throws {
        let rt = Self.formRuntime()
        var t = 0.0
        func click(_ p: Vec2) {
            rt.pointerDown(at: p, at: t)
            rt.pointerUp(at: p, at: t)
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let pMake = try Self.pointAtByte(rt, "single", 2)
        let pTitle = try Self.pointAtByte(rt, "single", 11)

        click(pMake)
        let anchor = rt.state.single.anchor
        #expect(anchor > 0 && anchor < 4)

        // Shift+click at the same point right after a click extends (empty at anchor) instead of double-clicking.
        _ = rt.physicalInput(.modifiers(Mods(shift: true)), at: t)
        click(pMake)
        #expect(rt.state.single.anchor == anchor && rt.state.single.cursor == anchor)

        // Shift+click further right extends from anchor to the clicked byte.
        click(pTitle)
        _ = rt.physicalInput(.modifiers(Mods()), at: t)
        #expect(rt.state.single.anchor == anchor)
        #expect(rt.state.single.cursor >= 9 && rt.state.single.cursor <= 14)

        // Immediately clicking at pTitle without Shift is a single click, not a double-click.
        click(pTitle)
        #expect(rt.state.single.anchor == rt.state.single.cursor)
    }
}
