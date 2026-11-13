import Foundation
import Testing
@testable import Rune
@testable import RuneKit
@testable import RuneRef

@MainActor
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
        #expect(abs((toastRect[0] + toastRect[2]) - (480 - ToastMetrics.regionRight)) < 1.0)
        #expect(toastRect[2] == ToastMetrics.toastWidth)
        #expect(toastRect[1] > 180)

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

        // Leaving bar holds for fadeDelay (0.75s) then hides
        vis.setPointerOverBar(false, now: 2.0)
        #expect(vis.opacity == 1.0)
        #expect(!vis.isWide)
        vis.tick(now: 2.74)
        #expect(vis.opacity == 1.0)
        vis.tick(now: 2.76)
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
            to: "$1.98",
            trailing: true,
            nextSeq: &seq
        )
        let nextSlots = RollingTextDiff.transition(
            labelKey: "odo",
            previous: initSlots.map { ($0.glyph, $0.key) },
            to: "$1.99",
            trailing: true,
            nextSeq: &seq
        )
        // "$1.9" matches as prefix + middle run; '9' is fresh
        #expect(nextSlots[0].key == initSlots[0].key)
        #expect(nextSlots[1].key == initSlots[1].key)
        #expect(nextSlots[2].key == initSlots[2].key)
        #expect(nextSlots[3].key == initSlots[3].key)
        #expect(!nextSlots[4].retained)

        func keptMask(_ old: String, _ new: String, trailing: Bool) -> String {
            let oldArr = old.map { String($0) }
            let newArr = new.map { String($0) }
            let idx = RollingTextDiff.matchIndices(old: oldArr, new: newArr, trailing: trailing)
            return zip(idx, newArr).map { $0 != nil ? $1 : "_" }.joined()
        }

        // Exact upstream rolling_text.rs:397-422 cases
        #expect(keptMask("10s", "100s", trailing: true) == "__0s")
        #expect(keptMask("19s", "100s", trailing: true) == "___s")
        #expect(keptMask("9s", "10s", trailing: true) == "__s")
        #expect(keptMask("$1.98", "$1.99", trailing: true) == "$1.9_")
        #expect(keptMask("$9.99", "$10.00", trailing: true) == "$__.__")
        #expect(keptMask("59s", "1m 00s", trailing: true) == "_____s")
        #expect(keptMask("1:00", "0:59", trailing: false) == "_:__")
        #expect(keptMask("Copy password", "Copied, clears in 0:30", trailing: false) == "Cop___________________")
        #expect(keptMask("xxabyy", "xqqqabzyy", trailing: false) == "x___ab_yy")

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
        let initialGlyphs = rt.elements()
            .filter { !$0.exiting && ($0.key?.hasPrefix("counter#") == true) }
            .sorted { $0.rect[0] < $1.rect[0] }
        #expect(initialGlyphs.count == 2)
        let onesNineKey = initialGlyphs.last?.key

        rt.state.text = "109"
        rt.markNeedsCommit()
        rt.frame(at: 0.06)
        for i in 1...40 { rt.frame(at: 0.06 + Double(i) / 60.0) }
        let updatedGlyphs = rt.elements()
            .filter { !$0.exiting && ($0.key?.hasPrefix("counter#") == true) }
            .sorted { $0.rect[0] < $1.rect[0] }
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

    @Test("Sonner ToastStack state machine coalesces keys, pulses, pauses stack-wide, and places slots")
    func sonnerToastStackParity() throws {
        var stack = ToastStack<String>()
        // Shown twice on front with same key pulses in place
        let e1 = stack.step(.shown(key: "k1", options: "Saved", secs: 4.0, now: 1.0))
        let id1 = try #require(stack.front?.id)
        #expect(e1.contains(.wakeAt(5.0)))

        let pulseEff = stack.step(.shown(key: "k1", options: "Saved again", secs: 4.0, now: 2.0))
        #expect(pulseEff.contains(.pulse(id1)))
        #expect(stack.entries.count == 1)
        #expect(stack.front?.options == "Saved again")

        // Second & third toast push onto front; buried key moves to front cleanly
        _ = stack.step(.shown(key: "k2", options: "Second", secs: 4.0, now: 2.0))
        _ = stack.step(.shown(key: "k3", options: "Third", secs: 4.0, now: 2.0))
        let id2 = stack.entries[1].id
        let id3 = stack.entries[2].id
        #expect(stack.entries.count == 3)

        // Collapsed placement: front has lift 0 scale 1.0 content true; behind has peek 12 and shrink 0.05
        let heights: [UInt64: Float] = [id1: 50, id2: 60, id3: 44]
        let pFront = try #require(stack.place(id: id3) { heights[$0] ?? 40 })
        let pMid = try #require(stack.place(id: id2) { heights[$0] ?? 40 })
        let pBack = try #require(stack.place(id: id1) { heights[$0] ?? 40 })
        #expect(pFront == ToastSlotPlacement(lift: 0, scale: 1.0, height: 44, content: true, visible: true, index: 0))
        #expect(abs(pMid.lift - 12.0) < 1e-4 && abs(pMid.scale - 0.95) < 1e-4 && !pMid.content && pMid.height == 44)
        #expect(abs(pBack.lift - 24.0) < 1e-4 && abs(pBack.scale - 0.90) < 1e-4 && !pBack.content)

        // Pointer over expands and pauses stack-wide timers
        _ = stack.step(.pointerOver(now: 3.0))
        #expect(stack.stackState == .expanded)
        #expect(stack.nextDue == nil)
        let expMid = try #require(stack.place(id: id2) { heights[$0] ?? 40 })
        #expect(abs(expMid.lift - (44.0 + 12.0)) < 1e-4 && expMid.scale == 1.0 && expMid.content)

        // Pressed + PointerLeft holds until Released outside
        _ = stack.step(.pressed(now: 4.0))
        _ = stack.step(.pointerLeft(now: 4.5))
        #expect(stack.stackState == .held(left: true))
        _ = stack.step(.released(now: 5.0))
        #expect(stack.stackState == .collapsed)

        // Page hidden pauses; shown resumes; dismissing to 1 collapses expanded stack
        _ = stack.step(.hotkey(now: 5.1))
        #expect(stack.stackState == .expanded)
        _ = stack.step(.dismissed(id: id1, now: 5.2))
        _ = stack.step(.dismissed(id: id2, now: 5.2))
        #expect(stack.entries.count == 1)
        #expect(stack.stackState == .collapsed)

        // Rich Toast card + ToastRegion layout checks
        struct Dummy {}
        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: Dummy(), viewport: Vec2(500, 300), systemDark: false) { _, _ in
            el().sizeFull().child(
                ToastRegion<Dummy>()
                    .toast(
                        Toast<Dummy>(key: "t", title: "Title")
                            .description("More detail")
                            .action("Primary", primary: true) { _, _ in }
                            .action("Secondary", primary: false) { _, _ in }
                            .closable()
                            .build(using: kit)
                    )
                    .build()
            )
        }
        rt.frame(at: 0.0)
        let regionRect = try #require(rt.element(byKey: "toast-region")).rect
        let cardRect = try #require(rt.element(byKey: "t")).rect
        #expect(abs(cardRect[2] - 320.0) < 0.5)
        #expect(abs((regionRect[0] + regionRect[2]) - (500.0 - 32.0)) < 1.0)
        #expect(abs((regionRect[1] + regionRect[3]) - (300.0 - 48.0)) < 1.0)
    }

    @Test("RollingText value(Double) direction, ScrollBar Chromium presets & live store, and ShortcutRecorder finishing key")
    func parityFixesVerification() throws {
        // RollingText value(Double) falling flips edge + font defaults to ui
        let store = RollingTextStore()
        _ = store.updateWithDirection(key: "n", value: "10s", numericValue: 10.0)
        let fall = store.updateWithDirection(key: "n", value: "8s", numericValue: 8.0)
        let hold = store.updateWithDirection(key: "n", value: "8 s", numericValue: 8.0)
        let nanStep = store.updateWithDirection(key: "n", value: "-", numericValue: .nan)
        let resumeFall = store.updateWithDirection(key: "n", value: "7s", numericValue: 7.0)
        #expect(fall.falling)
        #expect(!hold.falling)
        #expect(!nanStep.falling)
        #expect(resumeFall.falling)

        let kit = Kit.neutral(dark: false)
        struct Dummy {}
        let rtView = RollingText<Dummy>(key: "rt-font", value: "42", kit: kit, store: RollingTextStore()).value(42)
        #expect(rtView.font?.size == kit.ty.ui.size)

        // ScrollBar presets & Chromium pixel truncation + travel<=0 + LiveStore
        let sv = KitScrollBarStyle.scrollView(kit)
        let nat = KitScrollBarStyle.native(thumb: kit.c.borderMuted, thumbHover: kit.c.borderStrong)
        let menu = KitScrollBarStyle.menuScroll(thumb: kit.c.borderMuted, thumbHover: kit.c.borderStrong)
        #expect(sv.stripWidth == 12 && sv.edgeInset == 4 && sv.trackStartInset == 8 && sv.minThumb == 32)
        #expect(nat.stripWidth == 8 && nat.gutter && nat.border == 2 && nat.minThumb == 32)
        #expect(menu.stripWidth == 8 && menu.scrollOnly && menu.minThumb == 24)
        #expect(ScrollBarMetrics.fadeDelay == 0.75)

        let pxThumb = ScrollBarMath.thumbAlong(
            ScrollAxisMetrics(offset: 1, content: 1000, viewport: 100),
            trackLength: 100,
            minThumb: 24,
            devicePixels: true,
            scale: 1.0
        )
        #expect(pxThumb.start == 1.0) // Chromium (0..<1) -> 1
        #expect(ScrollBarMath.offsetAlong(thumbStart: 10, trackLength: 24, thumbLength: 24, maxScroll: 100, currentOffset: 42) == 42)
        #expect(!ScrollBarMath.trackLength(for: ScrollAxisMetrics(offset: 0, content: 100, viewport: 20), minThumb: 24).shows)

        let liveSlot = ScrollBarLiveStore.shared.slot(for: "sb-test", style: sv)
        liveSlot.hover(true, style: sv, now: 1.0)
        #expect(liveSlot.liveOpacity.get() == 1.0)
        #expect(liveSlot.liveFill.get() == sv.thumbHoverColor)

        // ShortcutRecorder ignores bare modifier keyDown & swallows finishing key repeat in capturing
        var rec = ShortcutRecorderState()
        rec.begin()
        let bareModHandled = rec.handle(.keyDown(key: "ShiftLeft", modifiers: [.shift], isRepeat: false))
        #expect(bareModHandled)
        #expect(rec.error == nil)
        let kHandled = rec.handle(.keyDown(key: "k", modifiers: [], isRepeat: false))
        #expect(kHandled)
        #expect(rec.error == .missingModifier)
        #expect(rec.phase.finishingKey == "k")
        let kUpHandled = rec.handle(.keyUp("k"))
        #expect(kUpHandled)
        #expect(rec.phase.finishingKey == nil)
    }

    @Test("ShortcutRecorder onPhysicalInput handles modifiers, keyDown/keyUp swallowing, repeat, Escape & Backspace")
    func shortcutRecorderPhysicalInputRuntime() throws {
        struct S {
            var recorder = ShortcutRecorderState(shortcut: ShortcutChord(key: "j", modifiers: [.command]))
            var committed: [ShortcutChord?] = []
            var rejectNext = false
        }
        let kit = Kit.neutral(dark: false)
        let rt = Runtime(state: S(), viewport: Vec2(320, 140), systemDark: false) { s, _ in
            kit.shortcutRecorder(
                key: "phys-rec",
                \.recorder,
                in: s,
                label: "Quick open",
                onChange: { st, chord in
                    if st.rejectNext {
                        st.rejectNext = false
                        return .conflict
                    }
                    st.committed.append(chord)
                    return nil
                }
            )
        }
        rt.frame(at: 0.0)

        // Click to enter recording mode
        let recRect = try #require(rt.element(byKey: "phys-rec")).rect
        let pt = Vec2(recRect[0] + 20, recRect[1] + 12)
        rt.pointerDown(at: pt, at: 0.01)
        rt.pointerUp(at: pt, at: 0.02)
        rt.frame(at: 0.03)
        #expect(rt.state.recorder.isRecording)

        // Modifiers update held keycaps live; Escape cancels without changing stored chord
        _ = rt.physicalInput(.modifiers(Mods(cmd: true)), at: 0.04)
        rt.frame(at: 0.05)
        #expect(rt.state.recorder.keycaps == ["⌘"])
        _ = rt.physicalInput(.key(key: .escape, mods: Mods(), pressed: true, repeat: false), at: 0.06)
        rt.frame(at: 0.07)
        #expect(!rt.state.recorder.isRecording)
        #expect(rt.state.recorder.shortcut == ShortcutChord(key: "j", modifiers: [.command]))

        // Re-begin, refuse bare key 'k', keep recording, clear error on Cmd modifier press, accept Cmd+K, swallow repeat & release
        rt.pointerDown(at: pt, at: 0.08)
        rt.pointerUp(at: pt, at: 0.09)
        rt.frame(at: 0.10)
        _ = rt.physicalInput(.key(key: .keyK, mods: Mods(), pressed: true, repeat: false), at: 0.11)
        _ = rt.physicalInput(.key(key: .keyK, mods: Mods(), pressed: false, repeat: false), at: 0.12)
        #expect(rt.state.recorder.isRecording && rt.state.recorder.error == .missingModifier)

        _ = rt.physicalInput(.modifiers(Mods(cmd: true)), at: 0.13)
        #expect(rt.state.recorder.error == nil)

        let handledDown = rt.physicalInput(.key(key: .keyK, mods: Mods(cmd: true), pressed: true, repeat: false), at: 0.14)
        #expect(handledDown)
        #expect(!rt.state.recorder.isRecording)
        #expect(rt.state.recorder.shortcut == ShortcutChord(key: "k", modifiers: [.command]))

        // Repeat + keyUp for finishing key 'k' remain swallowed without clearing/re-triggering
        #expect(rt.physicalInput(.key(key: .keyK, mods: Mods(cmd: true), pressed: true, repeat: true), at: 0.15))
        #expect(rt.physicalInput(.key(key: .keyK, mods: Mods(), pressed: false, repeat: false), at: 0.16))
        #expect(rt.state.recorder.shortcut == ShortcutChord(key: "k", modifiers: [.command]))

        // Re-begin and Backspace clears shortcut
        rt.pointerDown(at: pt, at: 0.17)
        rt.pointerUp(at: pt, at: 0.18)
        rt.frame(at: 0.19)
        _ = rt.physicalInput(.key(key: .backspace, mods: Mods(), pressed: true, repeat: false), at: 0.20)
        _ = rt.physicalInput(.key(key: .backspace, mods: Mods(), pressed: false, repeat: false), at: 0.21)
        #expect(rt.state.recorder.shortcut == nil)
        #expect(rt.state.committed.last ?? ShortcutChord(key: "x", modifiers: [.command]) == nil)

        // Commit Cmd+M, then conflict keeps old binding, shows error naming refused chord & keeps refused keycaps
        rt.pointerDown(at: pt, at: 0.22)
        rt.pointerUp(at: pt, at: 0.23)
        rt.frame(at: 0.24)
        _ = rt.physicalInput(.key(key: .keyM, mods: Mods(cmd: true), pressed: true, repeat: false), at: 0.25)
        _ = rt.physicalInput(.key(key: .keyM, mods: Mods(), pressed: false, repeat: false), at: 0.26)
        rt.frame(at: 0.27)
        let cmdM = ShortcutChord(key: "m", modifiers: [.command])
        #expect(rt.state.recorder.shortcut == cmdM)

        // Conflict on Cmd+P keeps Cmd+M, displays error naming ⌘ P, keeps recording & keycaps on refused chord
        rt.state.rejectNext = true
        rt.pointerDown(at: pt, at: 0.28)
        rt.pointerUp(at: pt, at: 0.29)
        rt.frame(at: 0.30)
        _ = rt.physicalInput(.key(key: .keyP, mods: Mods(cmd: true), pressed: true, repeat: false), at: 0.31)
        _ = rt.physicalInput(.key(key: .keyP, mods: Mods(), pressed: false, repeat: false), at: 0.32)
        rt.frame(at: 0.33)
        #expect(rt.state.recorder.isRecording)
        #expect(rt.state.recorder.shortcut == cmdM)
        #expect(rt.state.recorder.error == .conflict)
        #expect(rt.state.recorder.keycaps == ["⌘", "P"])
        #expect(rt.element(byKey: "phys-rec-error")?.text == "⌘P is already in use.")

        // Recording unchanged Cmd+M cancels without calling onChange; markUnregistered retries it cleanly
        let countBeforeSame = rt.state.committed.count
        _ = rt.physicalInput(.key(key: .keyM, mods: Mods(cmd: true), pressed: true, repeat: false), at: 0.34)
        _ = rt.physicalInput(.key(key: .keyM, mods: Mods(), pressed: false, repeat: false), at: 0.35)
        rt.frame(at: 0.36)
        #expect(!rt.state.recorder.isRecording)
        #expect(rt.state.committed.count == countBeforeSame)

        rt.state.recorder.markUnregistered()
        rt.pointerDown(at: pt, at: 0.37)
        rt.pointerUp(at: pt, at: 0.38)
        rt.frame(at: 0.39)
        _ = rt.physicalInput(.key(key: .keyM, mods: Mods(cmd: true), pressed: true, repeat: false), at: 0.40)
        _ = rt.physicalInput(.key(key: .keyM, mods: Mods(), pressed: false, repeat: false), at: 0.41)
        rt.frame(at: 0.42)
        #expect(!rt.state.recorder.isRecording)
        #expect(rt.state.committed.count == countBeforeSame + 1)

        // FocusLost cancels active capture cleanly; clear button clears shortcut
        rt.pointerDown(at: pt, at: 0.43)
        rt.pointerUp(at: pt, at: 0.44)
        rt.frame(at: 0.45)
        #expect(rt.state.recorder.isRecording)
        _ = rt.physicalInput(.focusLost, at: 0.46)
        rt.frame(at: 0.47)
        #expect(!rt.state.recorder.isRecording && !rt.state.recorder.isSwallowing)

        let clearRect = try #require(rt.element(byKey: "phys-rec-clear")).rect
        rt.pointerDown(at: Vec2(clearRect[0] + clearRect[2] * 0.5, clearRect[1] + clearRect[3] * 0.5), at: 0.48)
        rt.pointerUp(at: Vec2(clearRect[0] + clearRect[2] * 0.5, clearRect[1] + clearRect[3] * 0.5), at: 0.49)
        rt.frame(at: 0.50)
        #expect(rt.state.recorder.shortcut == nil)
    }

    @Test("RollingText countdown preserves prefix identity and rolls entering/exiting glyphs by value direction")
    func rollingTextCountdownAndValueDirectionRuntime() throws {
        struct S { var text = "0:30"; var val = 30.0 }
        let kit = Kit.neutral(dark: true)
        let store = RollingTextStore()
        let rt = Runtime(state: S(), viewport: Vec2(300, 120), pixelScale: 2.0, systemDark: true) { s, _ in
            col().p(20).child(
                RollingText<S>(key: "cd", value: s.text, font: kit.ty.mono, kit: kit, store: store)
                    .value(s.val)
                    .build()
            )
        }
        _ = rt.frame(at: 0.0)
        let before = rt.elements()
            .filter { !$0.exiting && ($0.key?.hasPrefix("cd#") ?? false) }
            .sorted { $0.rect[0] < $1.rect[0] }
        #expect(before.compactMap(\.text) == ["0", ":", "3", "0"])

        // Count down 30 -> 29: "0" and ":" keep keys & stay put, "3","0" exit down while "2","9" enter from top
        rt.update { s, _ in s.text = "0:29"; s.val = 29.0 }
        var now = 0.0
        for _ in 0..<10 {
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
        }
        let activeMid = rt.elements().filter { !$0.exiting && ($0.key?.hasPrefix("cd#") ?? false) }
        #expect(activeMid.contains { $0.key == before[0].key && $0.rect[1] == before[0].rect[1] })
        #expect(activeMid.contains { $0.key == before[1].key && $0.rect[1] == before[1].rect[1] })
        let exitingDown = rt.elements().filter { $0.exiting && ($0.key == before[2].key || $0.key == before[3].key) }
        #expect(!exitingDown.isEmpty)
        for ex in exitingDown {
            #expect(ex.rect[1] > before[2].rect[1] + 0.5)
        }
        let entering = activeMid.filter { $0.key != before[0].key && $0.key != before[1].key }
        #expect(entering.count == 2)
        for ent in entering {
            #expect(ent.rect[1] < ent.target[1] - 0.5)
        }

        // Settle and reverse back up 29 -> 30: entering "3" rolls up from below
        for _ in 0..<120 {
            now += 1.0 / 120.0
            _ = rt.frame(at: now)
        }
        rt.update { s, _ in s.text = "0:30"; s.val = 30.0 }
        now += 1.0 / 120.0
        _ = rt.frame(at: now)
        let risingThree = try #require(rt.elements().first { !$0.exiting && ($0.key?.hasPrefix("cd#") ?? false) && $0.text == "3" })
        #expect(risingThree.rect[1] > risingThree.target[1] + 1.0)
    }

    private func rollingSpanWidth<S>(_ rt: Runtime<S>, prefix: String) throws -> Float {
        let cells = rt.elements()
            .filter { !$0.exiting && ($0.key?.hasPrefix("\(prefix)#") ?? false) }
            .sorted { $0.rect[0] < $1.rect[0] }
        let first = try #require(cells.first)
        let last = try #require(cells.last)
        return last.rect[0] + last.rect[2] - first.rect[0]
    }

    @Test("RollingText width matches plain text, ZWJ emoji is one cell, and kept glyphs advance (tests/rolling_text.rs:182,200,211)")
    func rollingTextWidthMatchesPlainEmojiAndAdvance() throws {
        struct S { var text: String; var font: TextStyle }
        let kit = Kit.neutral(dark: false)
        let store = RollingTextStore()
        let plex = kit.ty.mono
        let inter = kit.ty.body

        for (sample, font) in [("Copy password", plex), ("Copy password", inter), ("AVATAR Tokyo, WAVE", inter)] {
            let rt = Runtime(state: S(text: sample, font: font), viewport: Vec2(400, 120), pixelScale: 2.0, systemDark: false) { s, _ in
                col().p(20)
                    .child(row().child(RollingText<S>(key: "rolled", value: s.text, font: s.font, kit: kit, store: store).build()))
                    .child(row().child(text(s.text).key("plain").font(s.font).noWrap()))
            }
            _ = rt.frame(at: 0.0)
            let rolledW = try rollingSpanWidth(rt, prefix: "rolled")
            let plainW = try #require(rt.element(byKey: "plain")).rect[2]
            #expect(abs(rolledW - plainW) <= 0.5)
        }

        // ZWJ emoji sequence renders as a single cell matching plain text width
        let family = "👩\u{200d}👩\u{200d}👧"
        let emojiLine = "\(family) 2 👍🏽 e\u{301}"
        let emojiStore = RollingTextStore()
        let emojiRt = Runtime(state: S(text: emojiLine, font: inter), viewport: Vec2(400, 120), pixelScale: 2.0, systemDark: false) { s, _ in
            col().p(20)
                .child(row().child(RollingText<S>(key: "emoji", value: s.text, font: s.font, kit: kit, store: emojiStore).build()))
                .child(row().child(text(s.text).key("plain").font(s.font).noWrap()))
        }
        _ = emojiRt.frame(at: 0.0)
        let cells = emojiRt.elements()
            .filter { !$0.exiting && ($0.key?.hasPrefix("emoji#") ?? false) }
            .sorted { $0.rect[0] < $1.rect[0] }
            .compactMap(\.text)
        #expect(cells == [family, " ", "2", " ", "👍🏽", " ", "e\u{301}"])
        let emojiRolledW = try rollingSpanWidth(emojiRt, prefix: "emoji")
        let emojiPlainW = try #require(emojiRt.element(byKey: "plain")).rect[2]
        #expect(abs(emojiRolledW - emojiPlainW) <= 0.5)

        // Kept glyphs settle to new advance when width changes (1:00 -> 11:00)
        let advStore = RollingTextStore()
        let advRt = Runtime(state: S(text: "1:00", font: inter), viewport: Vec2(400, 120), pixelScale: 2.0, systemDark: false) { s, _ in
            col().p(20)
                .child(row().child(RollingText<S>(key: "adv", value: s.text, font: s.font, kit: kit, store: advStore).build()))
                .child(row().child(text(s.text).key("plain").font(s.font).noWrap()))
        }
        _ = advRt.frame(at: 0.0)
        advRt.update { s, _ in s.text = "11:00" }
        var now = 0.0
        for _ in 0..<240 {
            now += 1.0 / 120.0
            _ = advRt.frame(at: now)
        }
        let advRolledW = try rollingSpanWidth(advRt, prefix: "adv")
        let advPlainW = try #require(advRt.element(byKey: "plain")).rect[2]
        #expect(abs(advRolledW - advPlainW) <= 0.5)
    }

    @Test(
        "ScrollBar thumb draws whole over viewport that fades at bottom (tests/scroll_bar_fade.rs)",
        .disabled("Blocked on @el: El.wrapScrollArea / clipToContent (forwarding wrapper clipFadeLinear to viewport child only; El.onScrollOffset is now wired)")
    )
    func scrollBarFadeOverViewportDrawsWholeThumb() throws {
        let width: Float = 200
        let height: Float = 100
        for inside in [true, false] {
            let rt = Runtime(state: inside, viewport: Vec2(width, height), pixelScale: 1.0, systemDark: true) { isInside, _ in
                let rows: [El<Bool>] = (0..<40).map { i in
                    el().key("row\(i)").w(100).h(20).bg(Color.white)
                }
                let viewport: El<Bool> = col()
                    .key("scroll")
                    .wFull()
                    .h(height)
                    .scrollY()
                    .child(col().children(rows))
                let style = KitScrollBarStyle.neutral(dark: true).thumb(Color.white)
                let area: El<Bool> = if isInside {
                    viewport.clipFadeLinear(bottom: 40).scrollBarStyled(style)
                } else {
                    viewport.scrollBarStyled(style).clipFadeLinear(bottom: 40)
                }
                return col().size(width, height).child(area)
            }
            rt.setSystemScrollBars(.always)
            _ = rt.frame(at: 0.0)
            rt.wheel(WheelEvent(dx: 0, dy: -10_000), at: Vec2(100, 50), now: 0.01)
            var t = 0.02
            var scene = rt.frame(at: t)
            for _ in 0..<120 {
                t += 1.0 / 60.0
                scene = rt.frame(at: t)
            }
            let thumb = try #require(rt.elements().first { $0.key == "thumb" }).rect
            #expect(thumb[1] + thumb[3] > height - 10.0)

            let frame = try RuneRef.render(scene)
            let bottomRowPixel = frame.pixel(x: 50, y: Int(height) - 2)
            #expect(bottomRowPixel.x < 64)
            let cx = Int(thumb[0] + thumb[2] * 0.5)
            let rowYs: [Float] = [
                thumb[1] + thumb[3] * 0.5,
                thumb[1] + thumb[3] - 4.0,
                thumb[1] + thumb[3] - 2.0,
            ]
            for rowY in rowYs {
                let p = frame.pixel(x: cx, y: Int(rowY))
                #expect(p.x == 255 && p.w == 255)
            }
        }
    }

    @Test("El.scrollBarStyled tracks live ScrollPos metrics and thumb rect via chainScrollOffset on wheel")
    func scrollBarLiveScrollTrackingViaOnScrollOffset() throws {
        var style = KitScrollBarStyle.neutral(dark: true)
            .key("live-sb-\(UUID().uuidString)")
            .thumbKey("live-thumb")
        style.overlay = true
        let viewportKey = "live-vp-\(UUID().uuidString)"
        final class Counter: @unchecked Sendable { var count = 0 }
        let builds = Counter()

        let rt = Runtime(state: 0, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { _, _ in
            builds.count += 1
            let rows: [El<Int>] = (0..<40).map { i in
                el().key("live-row-\(i)").wFull().h(20.0).shrink(0.0)
            }
            let viewport: El<Int> = col()
                .key(viewportKey)
                .wFull()
                .h(100.0)
                .scrollY()
                .child(col().wFull().shrink(0.0).children(rows))
                .scrollBarStyled(style, viewportKey: viewportKey)
            return col().size(200.0, 100.0).child(viewport)
        }

        _ = rt.frame(at: 0.0)
        let slot = ScrollBarLiveStore.shared.slot(for: "\(style.key)::\(viewportKey)", style: style)
        #expect(builds.count == 1)
        #expect(abs(slot.lastMetrics.viewport - 100.0) < 0.5)
        #expect(abs(slot.lastMetrics.content - 800.0) < 0.5)
        #expect(abs(slot.lastMetrics.offset) < 0.5)
        let topBefore = slot.liveThumb.get().top

        rt.wheel(WheelEvent(dx: 0, dy: -160), at: Vec2(100, 50), now: 0.02)
        _ = rt.frame(at: 0.03)
        #expect(slot.lastMetrics.offset > 50.0)
        #expect(slot.liveThumb.get().top > topBefore)
        #expect(slot.liveOpacity.get() == 1.0)
    }

    @Test("Extra KitIcons glyphs rasterize with ink (tests/glyphs.rs)")
    func extraGlyphsRasterizeWithInk() {
        for icon in [KitIcons.mic, KitIcons.keyboard, KitIcons.cursorText, KitIcons.arrowRight, KitIcons.sparkle] {
            let atlas = GlyphAtlas()
            _ = atlas.rasterizeIcon(icon, pixelSize: 32)
            let ink = atlas.atlas.texels.reduce(0) { $0 + Int($1) }
            #expect(ink > 2000, "Expected \(icon.paths.count)-path glyph to have ink > 2000, got \(ink)")
        }
    }

    @Test("RollingText preserves entering glyphs and roll direction across layout-read retries (tests/rolling_text_retry.rs)")
    func rollingTextLayoutReadRetriesKeepChangedGlyphsEnterAndDirection() throws {
        final class Counter: @unchecked Sendable { var count = 0 }
        struct RetryState {
            var value: Int = 9
            var reads: Bool
            var views = Counter()
        }
        let kit = Kit.neutral(dark: true)
        for reads in [true, false] {
            let store = RollingTextStore()
            let rt = Runtime(state: RetryState(reads: reads), viewport: Vec2(400, 120), pixelScale: 2.0, systemDark: true) { s, cx in
                s.views.count += 1
                if s.reads {
                    _ = cx.layoutSize("probe")
                } else {
                    _ = cx.layoutWith("probe") { $0[2] }
                }
                return col()
                    .p(20)
                    .child(el().key("probe").size(Float(s.value) * 10.0, 10.0))
                    .child(RollingText<RetryState>(key: "retry-count", value: "\(s.value)", kit: kit, store: store).value(Double(s.value)).build())
            }
            _ = rt.frame(at: 0.0)
            var now = 0.0
            for value in [8, 9] {
                let before = rt.state.views.count
                rt.update { s, _ in s.value = value }
                now += 1.0 / 120.0
                _ = rt.frame(at: now)
                #expect(rt.state.views.count >= before + 2)
                let digit = try #require(rt.elements().first { !$0.exiting && ($0.key?.hasPrefix("retry-count#") ?? false) })
                #expect(digit.opacity < 0.5)
                let dy = digit.rect[1] - digit.target[1]
                #expect(value == 8 ? dy < -1.0 : dy > 1.0)
                for _ in 0..<120 {
                    now += 1.0 / 120.0
                    _ = rt.frame(at: now)
                }
            }
        }
    }

    @Test("RollingText layout-read retry motion gate passes with zero findings (tests/rolling_text_retry.rs)")
    func rollingTextRetryMotionGate() {
        final class Counter: @unchecked Sendable { var count = 0 }
        struct RetryState {
            var value: Int = 9
            var views = Counter()
        }
        let cells = MotionGateGate.run([(
            "rolling-text/layout-read-retry",
            {
                let kit = Kit.neutral(dark: true)
                let store = RollingTextStore()
                let rt = Runtime(state: RetryState(), viewport: Vec2(400, 120), pixelScale: 2.0, systemDark: true) { s, cx in
                    s.views.count += 1
                    _ = cx.layoutSize("probe")
                    return col()
                        .p(20)
                        .child(el().key("probe").size(Float(s.value) * 10.0, 10.0))
                        .child(RollingText<RetryState>(key: "retry-count", value: "\(s.value)", kit: kit, store: store).value(Double(s.value)).build())
                }
                let run = MotionGateRun(rt, hz: 120.0)
                run.idle(0.5)
                run.step()
                run.act("down") { rt in rt.update { s, _ in s.value = 8 } }
                run.play(0.8)
                run.act("up") { rt in rt.update { s, _ in s.value = 9 } }
                run.play(1.0)
                return run.rec
            }
        )])
        let report = MotionGateGate.reportRows(
            cells,
            rows: [
                MotionGateAllowRow(
                    "jump",
                    "0/@probe",
                    "rolling-text/layout-read-retry",
                    "Test fixture unpainted layout probe resizes synchronously on input (!parentOf[i] sets .ink in MotionGateCheck.swift:261); RollingText itself must have 0 findings.",
                    max: 2
                ),
            ]
        )
        #expect(report.failing == 0, "\(report.text)")
    }
}
