import Foundation
import Testing
import Rune
@testable import RuneKit

@Suite("RuneKit Increment 3: ToastStack, ScrollBar, RollingText & ShortcutRecorder Tests")
struct FeedbackAndInputsTests {

    // MARK: - ToastStack & Toast (`toast_stack.rs`, `toast.rs`)

    @Test("ToastTimerPhase handles hover pause, resume, tick expiration, and dismiss")
    func toastTimerPhaseLifecycle() {
        var timer = ToastTimerPhase.armed(remaining: 4.0)
        let e1 = timer.step(.tick(1.5))
        #expect(e1.isEmpty)
        #expect(abs(timer.remaining - 2.5) < 1e-6)

        // Hover pauses timer; ticks do not advance while paused
        let eEnter = timer.step(.pointerEnter)
        #expect(eEnter.isEmpty)
        #expect(timer.isPaused)
        let ePausedTick = timer.step(.tick(10.0))
        #expect(ePausedTick.isEmpty)
        #expect(abs(timer.remaining - 2.5) < 1e-6)

        // Leaving resumes from exact paused remainder
        let eLeave = timer.step(.pointerLeave)
        #expect(eLeave.isEmpty)
        #expect(!timer.isPaused)
        let e2 = timer.step(.tick(2.0))
        #expect(e2.isEmpty)
        #expect(abs(timer.remaining - 0.5) < 1e-6)

        let effects = timer.step(.tick(0.6))
        #expect(effects == [.dismiss])
        #expect(timer.isExpired)
        let eDone = timer.step(.dismiss)
        #expect(eDone.isEmpty)
    }

    @Test("ToastStack bounds visible slots, promotes FIFO queue, and auto-dismisses")
    func toastStackFifoAndTick() {
        var stack = ToastStack<String>(maxVisible: 2, defaultDuration: 3.0)
        let id1 = stack.push("First")
        let id2 = stack.push("Second", duration: 5.0)
        let id3 = stack.push("Third", duration: 2.0)
        let id4 = stack.push("Fourth")

        #expect(stack.visible.map(\.id) == [id1, id2])
        #expect(stack.queued.map(\.id) == [id3, id4])
        #expect(stack.queuedCount == 2)

        // Hover-pause first toast so only second advances toward expiry, or dismiss first manually
        stack.pause(id: id1)
        let pausedExpired = stack.tick(2.5)
        #expect(pausedExpired.isEmpty)
        #expect(stack.visible.first(where: { $0.id == id1 })?.remaining == 3.0)
        #expect(abs((stack.visible.first(where: { $0.id == id2 })?.remaining ?? 0) - 2.5) < 1e-6)

        // Manual dismiss promotes Third cleanly with its full 2.0s budget
        let dismissed1 = stack.dismiss(id: id1)
        #expect(dismissed1)
        #expect(stack.visible.map(\.id) == [id2, id3])
        #expect(stack.queued.map(\.id) == [id4])
        #expect(stack.visible.first(where: { $0.id == id3 })?.remaining == 2.0)

        // Tick 2.1s expires Third (2.0s) and keeps Second (0.4s left), promoting Fourth
        let expired = stack.tick(2.1)
        #expect(expired == [id3])
        #expect(stack.visible.map(\.id) == [id2, id4])
        #expect(stack.queued.isEmpty)

        // Infinite sticky toast never expires
        let sticky = stack.push("Sticky", duration: .infinity)
        let longExpired = stack.tick(100.0)
        #expect(longExpired == [id2, id4])
        #expect(stack.visible.map(\.id) == [sticky])

        stack.clear()
        #expect(stack.isEmpty)
    }

    @Test("ToastRegion and Toast render action/dismiss buttons interactively in Runtime")
    func toastRegionRuntime() throws {
        struct S {
            var toasts = [ToastEntry(id: "save", message: "Saved file", tone: .success, actionLabel: "Undo")]
            var undone = 0
            var dismissed: [String] = []
        }

        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(480, 320), systemDark: false) { s, _ in
            var region = ToastRegion<S>(key: "region", placement: .bottomTrailing)
            for t in s.toasts {
                let tid = t.id
                region = region.child(
                    Toast<S>(key: "toast-\(tid)", message: t.message, variant: t.tone)
                        .action(t.actionLabel ?? "OK") { st, _ in st.undone += 1 }
                        .onDismiss { st, _ in
                            st.dismissed.append(tid)
                            st.toasts.removeAll { $0.id == tid }
                        }
                        .build(using: kit)
                )
            }
            return col().sizeFull().child(region.build())
        }

        rt.frame(at: 0.0)
        let actionRect = try #require(rt.element(byKey: "toast-save-action")).rect
        let dismissRect = try #require(rt.element(byKey: "toast-save-dismiss")).rect
        let toastRect = try #require(rt.element(byKey: "toast-save")).rect
        #expect(toastRect[0] > 200 && toastRect[1] > 200)

        let ax = actionRect[0] + actionRect[2] * 0.5
        let ay = actionRect[1] + actionRect[3] * 0.5
        rt.pointerDown(at: Vec2(ax, ay), at: 0.05)
        rt.pointerUp(at: Vec2(ax, ay), at: 0.06)
        rt.frame(at: 0.07)
        #expect(rt.state.undone == 1)

        let dx = dismissRect[0] + dismissRect[2] * 0.5
        let dy = dismissRect[1] + dismissRect[3] * 0.5
        rt.pointerDown(at: Vec2(dx, dy), at: 0.1)
        rt.pointerUp(at: Vec2(dx, dy), at: 0.11)
        rt.frame(at: 0.12)
        for i in 1...60 { rt.frame(at: 0.12 + Double(i) / 60.0) }
        #expect(rt.state.dismissed == ["save"])
        #expect(rt.element(byKey: "toast-save") == nil)
    }

    // MARK: - ScrollBar (`scroll_bar.rs`, `press.rs`, `visibility.rs`)

    @Test("ScrollBarMath computes track, thumb, pixel alignment, overscroll shrink, and offset")
    func scrollBarMathParity() {
        let m = ScrollAxisMetrics(offset: 100, content: 500, viewport: 100)
        let (len, shows) = ScrollBarMath.trackLength(for: m)
        #expect(shows)
        #expect(len == 96)

        // Thumb length clamped to minThumb (20) when ratio * 96 = 19.2 < 20
        let (start, thumbLen) = ScrollBarMath.thumbAlong(m, trackLength: len, minThumb: 20)
        #expect(thumbLen == 20)
        // offset=100 out of maxScroll=400 => 25% of travel (76) = 19
        #expect(start == 19)

        // Inverse mapping restores offset cleanly
        let roundTrip = ScrollBarMath.offsetAlong(
            thumbStart: start,
            trackLength: len,
            thumbLength: thumbLen,
            maxScroll: m.maxScroll
        )
        #expect(abs(roundTrip - 100) < 0.01)

        // Overscroll above top or past bottom shrinks thumb toward minThumb and pins to edge
        let topOver = ScrollBarMath.thumbAlong(
            ScrollAxisMetrics(offset: -50, content: 300, viewport: 100),
            trackLength: 96,
            minThumb: 20
        )
        let restTop = ScrollBarMath.thumbAlong(
            ScrollAxisMetrics(offset: 0, content: 300, viewport: 100),
            trackLength: 96,
            minThumb: 20
        )
        #expect(topOver.start == 0)
        #expect(topOver.length < restTop.length)

        let bottomOver = ScrollBarMath.thumbAlong(
            ScrollAxisMetrics(offset: 260, content: 300, viewport: 100),
            trackLength: 96,
            minThumb: 20
        )
        #expect(abs((bottomOver.start + bottomOver.length) - 96) < 0.01)

        // Content <= viewport hides bar
        #expect(!ScrollBarMath.trackLength(for: ScrollAxisMetrics(offset: 0, content: 100, viewport: 100)).shows)
    }

    @Test("ScrollBarPressTracker distinguishes thumb grab vs track page and catches lost releases")
    func scrollBarPressTrackerAndGrip() {
        // Vertical track click above thumb pages up (-1), Option+click jumps to thumb centered
        let pageUp = ScrollBarPress.begin(
            pointerAlongTrack: 5,
            thumbStart: 40,
            thumbLength: 20,
            altPressed: false,
            jumpPreference: false,
            horizontal: false
        )
        #expect(pageUp == .pages(toward: -1))

        let jump = ScrollBarPress.begin(
            pointerAlongTrack: 15,
            thumbStart: 40,
            thumbLength: 20,
            altPressed: true,
            jumpPreference: false,
            horizontal: false
        )
        #expect(jump == .thumb(grab: 10))

        let horizontalJump = ScrollBarPress.begin(
            pointerAlongTrack: 15,
            thumbStart: 40,
            thumbLength: 20,
            altPressed: false,
            jumpPreference: false,
            horizontal: true
        )
        #expect(horizontalJump == .thumb(grab: 10))

        // Grip lost-release detection
        var tracker = ScrollBarPressTracker()
        tracker.pointerDown(.thumb(grab: 6), at: Vec2(195, 20))
        #expect(tracker.isHeld)
        let moved = tracker.dragMoved(to: Vec2(195, 30))
        #expect(moved == .thumb(grab: 6))
        // Two distinct non-drag pointer moves reveal the release was lost
        let p1 = tracker.observePointerMove(at: Vec2(100, 30))
        #expect(p1 == nil)
        let p2 = tracker.observePointerMove(at: Vec2(110, 40))
        #expect(p2 == .thumb(grab: 6))
        #expect(!tracker.isHeld)
    }

    @Test("ScrollBarVisibility manages overlay reveal, hold delay, fade, and always-visible mode")
    func scrollBarVisibilityStateMachine() {
        var vis = ScrollBarVisibility(alwaysVisible: false, shows: true)
        #expect(vis.opacity == 0.0)
        #expect(!vis.acceptsPointerHits)

        // Moving inside viewport without reaching edge keeps overlay bar hidden
        vis.setPointerInside(true, now: 1.0)
        #expect(vis.opacity == 0.0)

        // Hovering over the edge strip reveals & widens bar
        vis.setPointerOverBar(true, now: 1.1)
        #expect(vis.opacity == 1.0)
        #expect(vis.isWide)
        #expect(vis.acceptsPointerHits)

        // Leaving bar holds for fadeDelay (0.8s) then hides
        vis.setPointerOverBar(false, now: 2.0)
        #expect(vis.opacity == 1.0)
        #expect(!vis.isWide)
        vis.tick(now: 2.79)
        #expect(vis.opacity == 1.0)
        vis.tick(now: 2.81)
        #expect(vis.opacity == 0.0)
        #expect(!vis.acceptsPointerHits)

        // Scrolling reveals bar and holds while pressed
        vis.scrolled(now: 5.0)
        #expect(vis.opacity == 1.0)
        vis.setHeld(true, now: 5.2)
        vis.tick(now: 10.0)
        #expect(vis.opacity == 1.0)
        vis.setHeld(false, now: 10.0)
        vis.tick(now: 10.9)
        #expect(vis.opacity == 0.0)

        // Always-visible ignores auto-hide, unless content fits viewport
        vis.setAlwaysVisible(true, now: 11.0)
        #expect(vis.opacity == 1.0)
        vis.setShows(false, now: 11.5)
        #expect(vis.opacity == 0.0)
    }

    @Test("KitScrollBarStyle renders custom thumb widths/colors and Runtime container")
    func scrollBarStyledRendering() throws {
        struct S { var offset: Float = 0 }
        let kit = Kit.neutral(dark: true)
        let red = Color(r: 1, g: 0, b: 0, a: 1)
        let blue = Color(r: 0, g: 0, b: 1, a: 1)
        let style = KitScrollBarStyle.neutral(dark: true)
            .thumb(red)
            .thumbHover(blue)
            .width(4)
            .hoverWidth(12)
            .alwaysVisible(true)

        #expect(style.resolvedStripWidth == 16)

        let rt = Runtime(state: S(), viewport: Vec2(200, 100), systemDark: true) { s, _ in
            col().size(200, 100).child(
                kit.styledScrollBar(
                    style,
                    metrics: ScrollAxisMetrics(offset: s.offset, content: 400, viewport: 100),
                    hovered: false
                ) { st, nextOffset, _ in
                    st.offset = nextOffset
                }
            )
        }
        rt.frame(at: 0.0)
        let track = try #require(rt.element(byKey: "scroll-bar") as ElementInfo?).rect
        let thumb = try #require(rt.element(byKey: "thumb") as ElementInfo?).rect
        #expect(track[2] == 16)
        #expect(thumb[2] == 4)
        #expect(thumb[0] == 10) // strip(16) - edgeInset(2) - width(4)
    }

    // MARK: - RollingText (`rolling_text.rs`, `tests/rolling_text.rs`)

    @Test("RollingTextDiff keeps matching grapheme keys, handles duplicates, and bounds stagger")
    func rollingTextDiffAndStability() {
        var seq: UInt64 = 1
        let s1 = RollingTextDiff.transition(labelKey: "lbl", previous: [], to: "aa", nextSeq: &seq)
        #expect(s1.map(\.glyph) == ["a", "a"])
        #expect(s1[0].enterDelay == 0.0)
        #expect(abs(s1[1].enterDelay - 0.03) < 1e-6)

        // Identical text preserves exact keys
        let sSame = RollingTextDiff.transition(
            labelKey: "lbl",
            previous: s1.map { ($0.glyph, $0.key) },
            to: "aa",
            nextSeq: &seq
        )
        #expect(sSame.map(\.key) == s1.map(\.key))
        #expect(sSame.allSatisfy { $0.retained })

        // Insert 'b' in middle: prefix 'a' and suffix 'a' keep original keys!
        let sInsert = RollingTextDiff.transition(
            labelKey: "lbl",
            previous: s1.map { ($0.glyph, $0.key) },
            to: "aba",
            nextSeq: &seq
        )
        #expect(sInsert[0].key == s1[0].key && sInsert[0].retained)
        #expect(!sInsert[1].retained && sInsert[1].glyph == "b")
        #expect(sInsert[2].key == s1[1].key && sInsert[2].retained)

        // Stagger capped at staggerCap (6 * 0.03 = 0.18)
        let sLong = RollingTextDiff.transition(labelKey: "long", previous: [], to: "abcdefghij", nextSeq: &seq)
        #expect(abs(sLong[9].enterDelay - 0.18) < 1e-6)
    }

    @Test("RollingTextDiff trailing odometer aligns right digits and treats ZWJ emoji atomically")
    func rollingTextOdometerAndGraphemes() {
        var seq: UInt64 = 1
        let initSlots = RollingTextDiff.transition(
            labelKey: "odo",
            previous: [],
            to: "$1,234",
            trailing: true,
            nextSeq: &seq
        )
        let nextSlots = RollingTextDiff.transition(
            labelKey: "odo",
            previous: initSlots.map { ($0.glyph, $0.key) },
            to: "$1,240",
            trailing: true,
            nextSeq: &seq
        )
        // "$1,2" unchanged; '4' is reused or fresh depending on match, '0' is new
        #expect(nextSlots[0].key == initSlots[0].key)
        #expect(nextSlots[1].key == initSlots[1].key)
        #expect(nextSlots[2].key == initSlots[2].key)
        #expect(nextSlots[3].key == initSlots[3].key)
        #expect(nextSlots[4].key == initSlots[5].key) // trailing '4' aligned from right!
        #expect(!nextSlots[5].retained)

        // Grapheme clusters (emoji + combining accent) stay whole
        let emojiSlots = RollingTextDiff.transition(
            labelKey: "uni",
            previous: [],
            to: "e\u{0301}👨‍👩‍👧‍👦!",
            nextSeq: &seq
        )
        #expect(emojiSlots.count == 3)
        #expect(emojiSlots[1].glyph == "👨‍👩‍👧‍👦")

        // Budget guard (> 48*48) handles huge strings cleanly without O(N*M) blowup
        let a60 = String(repeating: "a", count: 60)
        let b60 = String(repeating: "b", count: 60)
        let huge = RollingTextDiff.transition(
            labelKey: "big",
            previous: a60.enumerated().map { (String($0.element), "k\($0.offset)") },
            to: "a" + b60 + "a",
            nextSeq: &seq
        )
        #expect(huge.first?.key == "k0")
        #expect(huge.last?.key == "k59")
    }

    @Test("RollingTextStore bounds entry count/bytes and drives stable Runtime element keys")
    func rollingTextStoreAndRuntime() throws {
        let store = RollingTextStore(maxLabels: 3, maxBytes: 1024)
        _ = store.update(key: "a", value: "10")
        _ = store.update(key: "b", value: "20")
        _ = store.update(key: "c", value: "30")
        // Touch "a" so "b" is LRU and gets evicted when "d" arrives
        _ = store.update(key: "a", value: "11")
        _ = store.update(key: "d", value: "40")
        #expect(store.count == 3)
        #expect(store.contains(key: "a"))
        #expect(!store.contains(key: "b"))
        #expect(store.contains(key: "c"))
        #expect(store.contains(key: "d"))

        let testStore = RollingTextStore()
        struct S { var text = "99" }
        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(240, 80), systemDark: false) { s, _ in
            col().sizeFull().child(
                RollingText<S>(key: "counter", value: s.text, trailing: true, kit: kit, store: testStore).build()
            )
        }
        rt.frame(at: 0.0)
        let initialGlyphs = rt.elements().filter { !$0.exiting && ($0.key?.hasPrefix("counter#") == true) }
        #expect(initialGlyphs.count == 2)
        let onesNineKey = initialGlyphs.last?.key

        rt.state.text = "109"
        rt.markNeedsCommit()
        rt.frame(at: 0.06)
        for i in 1...40 { rt.frame(at: 0.06 + Double(i) / 60.0) }
        let updatedGlyphs = rt.elements().filter { !$0.exiting && ($0.key?.hasPrefix("counter#") == true) }
        #expect(updatedGlyphs.count == 3)
        let afterNineKey = updatedGlyphs.last?.key
        #expect(onesNineKey != nil && onesNineKey == afterNineKey)
    }

    // MARK: - ShortcutRecorder (`shortcut_recorder.rs`, `tests/shortcut_recorder.rs`)

    @Test("ShortcutRecorderState swallows finishing key release, handles refusals, unregister, and non-mac formatting")
    func shortcutRecorderSwallowingAndParity() {
        var rec = ShortcutRecorderState()
        rec.begin()
        #expect(rec.isRecording)

        // Repeated unmodified key refused, error cleared when modifier added
        let h1 = rec.handle(.keyDown(key: "k", modifiers: [], isRepeat: false))
        #expect(h1)
        #expect(rec.error == .missingModifier)
        #expect(rec.error?.defaultMessage(for: rec.refusedChord, macOS: true) == "Add ⌘, ⌃ or ⌥.")
        #expect(rec.error?.defaultMessage(for: rec.refusedChord, macOS: false) == "Add Ctrl, Alt or Super.")

        let hMod = rec.handle(.modifiersChanged([.command]))
        #expect(hMod)
        #expect(rec.error == nil)
        #expect(rec.keycaps == ["⌘"])

        // Function key F5 accepted without extra modifiers; enters swallowing until F5 keyUp
        let hF5 = rec.handle(.keyDown(key: "F5", modifiers: [], isRepeat: false))
        #expect(hF5)
        #expect(!rec.isRecording)
        #expect(rec.isSwallowing)
        #expect(rec.shortcut == ShortcutChord(key: "F5", modifiers: []))

        // Repeat of F5 swallowed; mismatched keyUp ignored; matching F5 keyUp completes swallow -> idle
        let hRep = rec.handle(.keyDown(key: "F5", modifiers: [], isRepeat: true))
        let hUpWrong = rec.handle(.keyUp("a"))
        let hUpF5 = rec.handle(.keyUp("F5"))
        #expect(hRep)
        #expect(!hUpWrong)
        #expect(hUpF5)
        #expect(!rec.isSwallowing)
        #expect(rec.phase == .idle)

        // Unregistered shortcut re-triggers onChange when same chord is recorded again
        var calls = 0
        rec.markUnregistered()
        rec.begin()
        let hReconfirm = rec.handle(.keyDown(key: "F5", modifiers: [], isRepeat: false)) { _ in
            calls += 1
            return nil
        }
        #expect(hReconfirm)
        #expect(calls == 1)
        _ = rec.handle(.keyUp("F5"))

        // Rejected clear keeps shortcut and displays error
        rec.begin()
        _ = rec.handle(.keyDown(key: "backspace", modifiers: [], isRepeat: false)) { _ in
            .permissionDenied
        }
        #expect(rec.error == .permissionDenied)
        #expect(rec.shortcut == ShortcutChord(key: "F5", modifiers: []))
        #expect(rec.isRecording)

        // allowUnmodified allows plain character + non-macOS formatting
        _ = rec.handle(.keyDown(key: "m", modifiers: [], isRepeat: false), allowUnmodified: true)
        _ = rec.handle(.keyUp("m"))
        #expect(rec.shortcut == ShortcutChord(key: "m", modifiers: []))

        let nonMac = ShortcutChord(key: "k", modifiers: [.control, .shift])
        #expect(nonMac.displayString(macOS: false) == "Ctrl+Shift+K")
        #expect(ShortcutValidationError.conflict.defaultMessage(for: nonMac, macOS: false) == "Ctrl+Shift+K is already in use.")
    }

    @Test("ShortcutRecorder interactive builder captures chords and renders custom errors in Runtime")
    func shortcutRecorderRuntime() throws {
        struct S {
            var rec = ShortcutRecorderState()
        }
        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(360, 140), systemDark: false) { s, _ in
            col().sizeFull().p(16).child(
                ShortcutRecorder<S>(key: "sr", \.rec, label: "Toggle Panel")
                    .errorMessage { err, chord in
                        "Rejected \(chord?.displayString ?? "none"): \(err.defaultMessage(for: chord))"
                    }
                    .build(using: kit, in: s)
            )
        }

        rt.frame(at: 0.0)
        let box = try #require(rt.element(byKey: "sr")).rect
        // Click begins capture and Tab focuses control
        let cx = box[0] + box[2] * 0.5
        let cy = box[1] + box[3] * 0.5
        rt.pointerDown(at: Vec2(cx, cy), at: 0.05)
        rt.pointerUp(at: Vec2(cx, cy), at: 0.06)
        rt.frame(at: 0.07)
        #expect(rt.state.rec.isRecording)

        // Focus + send unmodified key -> displays custom formatted error
        _ = rt.keyDown(KeyEvent(key: .tab, mods: .none), at: 0.08)
        rt.frame(at: 0.09)
        _ = rt.keyDown(KeyEvent(key: .text("k"), mods: .none), at: 0.1)
        rt.frame(at: 0.11)
        #expect(rt.state.rec.error == .missingModifier)
        #expect(rt.element(byKey: "sr-error") != nil)

        // Cmd+Shift+K commits chord and enters swallowing phase
        _ = rt.keyDown(
            KeyEvent(key: .text("k"), mods: Mods(shift: true, cmd: true)),
            at: 0.12
        )
        rt.frame(at: 0.13)
        #expect(rt.state.rec.shortcut == ShortcutChord(key: "k", modifiers: [.command, .shift]))
        #expect(rt.state.rec.isSwallowing)
        #expect(rt.element(byKey: "sr-error") == nil)
    }
}
