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

    @Test("shift_click_extends_from_anchor_and_does_not_start_multiclick")
    func shiftClickExtendsFromAnchorAndDoesNotStartMulticlick() throws {
        let rt = InputClickFixture.runtime()
        var t = 0.0
        func click(_ p: Vec2) {
            rt.pointerDown(at: p, at: t)
            rt.pointerUp(at: p, at: t)
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
        }
        let pMake = try InputClickFixture.pointAtByte(rt, "single", 2)
        let pTitle = try InputClickFixture.pointAtByte(rt, "single", 11)

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

    // MARK: - help.rs:617 `reaching_help_wakes_a_host_that_skips_unchanged_frames`

    @Test("reaching_help_wakes_a_host_that_skips_unchanged_frames")
    func reachingHelpWakesAHostThatSkipsUnchangedFrames() {
        struct S { var modal = false; var cover = false }
        // `help.rs` tests `view` / `runtime(S::default(), false)` at 300 × 300, scale 2.
        let rt = Runtime(state: S(), viewport: Vec2(300, 300), pixelScale: 2.0) { _, _ in
            el().wFull().hFull()
                .child(el().key("copy").size(40, 20).pin(top: 20, left: 20).help("Copy"))
                .child(el().key("low").size(40, 20).pin(top: 200, left: 20).help("Low"))
        }
        rt.nativeHelp = false
        _ = rt.frame(at: 0)
        // An overlay draws only when observePointer says something changed; help that has no
        // hover paint of its own must still start its wait.
        #expect(!rt.observePointer(at: Vec2(150, 150), at: 0), "nothing there")
        #expect(rt.observePointer(at: Vec2(30, 30), at: 0), "onto help")
        _ = rt.frame(at: 1.0 / 60.0)
        #expect(!rt.observePointer(at: Vec2(31, 30), at: 1.0 / 60.0), "still on it")
        _ = rt.frame(at: 1.0 / 60.0 + rt.helpDelay)
        #expect(rt.helpTooltip() != nil)
        #expect(rt.observePointer(at: Vec2(150, 150), at: 1.0 / 60.0 + rt.helpDelay), "off it hides the tooltip")
    }

    // MARK: - `observe_pointer` counts what a held press's move queues (`pointer.rs:13-65`)

    @Test("observePointer: a text field drag-selection queues Action::Focus on every move (input_drag)")
    func observePointerFieldDragSelectionNeedsFrames() throws {
        let rt = InputClickFixture.runtime()
        let pDown = try InputClickFixture.pointAtByte(rt, "single", 2)
        let pMid = try InputClickFixture.pointAtByte(rt, "single", 8)
        let pFar = try InputClickFixture.pointAtByte(rt, "single", 11)
        rt.pointerMove(to: pDown, at: 0)
        rt.pointerDown(at: pDown, at: 0)
        _ = rt.frame(at: 1.0 / 60.0)
        #expect(rt.observePointer(at: pMid, at: 1.0 / 60.0), "a field drag-selection move queues Focus")
        #expect(rt.observePointer(at: pFar, at: 2.0 / 60.0), "and every further move does")
        #expect(!rt.observePointer(at: pFar, at: 2.0 / 60.0), "a duplicate observation queues nothing")
        rt.pointerUp(at: pFar, at: 3.0 / 60.0)
        _ = rt.frame(at: 3.0 / 60.0)
        #expect(rt.state.single.anchor != rt.state.single.cursor, "the drag selected")
        #expect(!rt.observePointer(at: Vec2(pFar.x + 1, pFar.y), at: 4.0 / 60.0), "released, moving within the field queues nothing")
    }

    @Test("observePointer: a held drag queues Action::Drag only where on_drag hears it (drags_with); a drag-out start queues DragStart")
    func observePointerHeldDragAndDragOut() throws {
        struct S { var moves = 0; var started = 0 }
        let rt = Runtime(state: S(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            row()
                .child(el().key("knob").size(40, 40).onDrag { s, d, _ in if d.phase == .move { s.moves += 1 } })
                .child(el().key("card").size(40, 40)
                    .onDrag { s, _, _ in s.moves += 1 }
                    .dragOut { _ in DragItem().text("payload") }
                    .onDragStart { s, _ in s.started += 1 })
        }
        _ = rt.frame(at: 0)

        rt.pointerMove(to: Vec2(10, 10), at: 0)
        rt.pointerDown(at: Vec2(10, 10), at: 0)
        #expect(rt.observePointer(at: Vec2(12, 10), at: 0.01), "on_drag hears the held press's move")
        #expect(rt.state.moves >= 1)
        rt.pointerUp(at: Vec2(12, 10), at: 0.02)
        _ = rt.frame(at: 0.03)

        // A drag-out element's `on_drag` doesn't hear the press (`!drags_out(n)`): a move inside
        // its threshold queues nothing.
        rt.pointerMove(to: Vec2(50, 10), at: 0.1)
        _ = rt.frame(at: 0.11)
        rt.pointerDown(at: Vec2(50, 10), at: 0.12)
        let moves = rt.state.moves
        #expect(!rt.observePointer(at: Vec2(51, 10), at: 0.13), "within the drag-out threshold, nothing is queued")
        #expect(rt.state.moves == moves)
        // Past the threshold the move starts the drag-out (`start_drag_out` queues DragStart).
        #expect(rt.observePointer(at: Vec2(70, 10), at: 0.14), "a drag-out the move starts needs a frame")
        #expect(rt.takeDragOutStart() != nil)
        #expect(rt.state.started == 1)
    }

    // MARK: - `overlay/input.rs:41-49` `Overlay::observe_pointer`

    @Test("overlayObservePointer: inside or captured observes; outside, a known pointer leaves once")
    func overlayObservePointerLeavesOutsideTheCanvas() {
        struct S { var hovered = 0; var pressed = 0 }
        let rt = Runtime(state: S(), viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in
            el().child(el().size(40, 20).onClick { $0.pressed += 1 }.onHover { s, inside, _ in if inside { s.hovered += 1 } })
        }
        _ = rt.frame(at: 0)
        #expect(!rt.overlayObservePointer(at: Vec2(150, 50), at: 0), "outside with no pointer: nothing")
        #expect(rt.overlayObservePointer(at: Vec2(5, 5), at: 0.01), "inside: observed, entering hover")
        #expect(!rt.overlayObservePointer(at: Vec2(6, 5), at: 0.02))
        #expect(rt.overlayObservePointer(at: Vec2(150, 50), at: 0.03), "leaving the canvas lets the pointer go")
        #expect(rt.hoveredPath == nil)
        #expect(!rt.overlayObservePointer(at: Vec2(160, 50), at: 0.04), "already gone")

        // A held press keeps observing outside the canvas: the release there cancels.
        #expect(rt.overlayObservePointer(at: Vec2(5, 5), at: 0.1))
        rt.pointerDown(at: Vec2(5, 5), at: 0.1)
        #expect(rt.overlayObservePointer(at: Vec2(150, 50), at: 0.11), "the capture moved outside")
        #expect(rt.pointerPosition == Vec2(150, 50))
        rt.pointerUp(at: Vec2(150, 50), at: 0.12)
        _ = rt.frame(at: 0.13)
        #expect(rt.state.pressed == 0)
    }

    // MARK: - `observe_pointer` and hover delays (`hover.rs:144-158`, `hover_delay.rs:128-137`)

    @Test("observePointer: entering or leaving a hover-delayed on_hover_change element queues no HoverChange")
    func observePointerSkipsDelayedHoverChange() {
        struct S { var tip: [Bool] = []; var eager: [Bool] = []; var plain: [Bool] = [] }
        let rt = Runtime(state: S(), viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in
            col()
                .child(el().key("tip").size(40, 20).hoverDelays(enter: 0.3, leave: 0.3)
                    .onHoverChange { s, inside, _ in s.tip.append(inside) })
                .child(el().key("plain").size(40, 20)
                    .onHoverChange { s, inside, _ in s.plain.append(inside) })
                .child(el().key("eager").size(40, 20).hoverDelays(enter: 0, leave: 0.3)
                    .onHoverChange { s, inside, _ in s.eager.append(inside) })
        }
        _ = rt.frame(at: 0)
        #expect(!rt.observePointer(at: Vec2(5, 5), at: 0), "a delayed enter only starts its wait")
        #expect(rt.state.tip.isEmpty)
        _ = rt.frame(at: 0.35)
        #expect(rt.state.tip == [true], "the frame after the wait reports the enter")
        #expect(!rt.observePointer(at: Vec2(5, 90), at: 0.4), "a delayed leave only starts its wait")
        _ = rt.frame(at: 0.75)
        #expect(rt.state.tip == [true, false])

        #expect(rt.observePointer(at: Vec2(5, 25), at: 0.8), "an undelayed enter queues HoverChange")
        #expect(rt.state.plain == [true])
        #expect(rt.observePointer(at: Vec2(5, 90), at: 0.9), "and so does its leave")
        #expect(rt.state.plain == [true, false])

        // No enter wait: the delay machine reports at once (`Effect::Report` queues HoverChange).
        #expect(rt.observePointer(at: Vec2(5, 45), at: 1.0), "a delay machine report needs a frame")
        #expect(rt.state.eager == [true])
        #expect(!rt.observePointer(at: Vec2(5, 90), at: 1.1), "its leave waits")
        #expect(rt.state.eager == [true])
    }

    // MARK: - `observe_pointer` visual edges follow the parent clip (`hit.rs:110-113` `node_contains`)

    @Test("observePointer: a hover-painted node's edge outside its parent's clip changes no pixels")
    func observePointerVisualEdgesFollowTheParentClip() {
        let rt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            el().child(
                el().key("clip").size(40, 40).clip(true)
                    .child(el().key("wide").size(100, 20).pin(top: 0, left: 0).hover(Color(r: 1, g: 0, b: 0, a: 1)))
            )
        }
        _ = rt.frame(at: 0)
        #expect(!rt.observePointer(at: Vec2(60, 5), at: 0), "inside the wide row but outside the clip it shows nothing")
        #expect(!rt.observePointer(at: Vec2(60, 30), at: 0.01), "leaving its clipped-away part flips nothing drawn")
        #expect(rt.observePointer(at: Vec2(10, 5), at: 0.02), "its visible part shows hover")
        #expect(rt.observePointer(at: Vec2(10, 30), at: 0.03), "and leaving it hides hover")

        // A node with no drawn geometry falls back to its layout edges, still within the parent's
        // inherited clip (`drawn_edges` ∩ `inh.clip`). `pressScale` tracks the press without
        // making the node a hover target, so only its edges decide.
        let rest = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            el().child(
                el().key("clip").size(40, 40).clip(true)
                    .child(el().key("wide").size(100, 20).pin(top: 0, left: 0).pressScale(0.96))
            )
        }
        _ = rest.frame(at: 0)
        let wide = rest.flatNodes.first { $0.key == "wide" }
        #expect(wide != nil)
        if let wide {
            // Laid out but not drawn yet (`drawn` has no entry for it).
            rest.hitGeometryByPath[wide.path] = nil
        }
        #expect(!rest.observePointer(at: Vec2(60, 5), at: 0), "outside the clip the rest edges hold nothing")
        #expect(!rest.observePointer(at: Vec2(60, 30), at: 0.01))
        #expect(rest.observePointer(at: Vec2(10, 5), at: 0.02), "inside the clip and the row")
        #expect(rest.observePointer(at: Vec2(10, 30), at: 0.03), "inside the clip, below the row")
    }
}
