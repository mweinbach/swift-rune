import Foundation
import Testing
@testable import Rune

@Suite("Slice 4 Input Wave 1 Parity Tests (PressRun, KeyReleases, ModifierKeys, AppIme)")
struct Slice4InputWave1Tests {

    // MARK: - PressRun (`press_run_tests.rs`)

    @Test("PressRun: presses on one element close in time and place count up")
    func pressRunCountsUp() {
        var run = PressRun()
        let p1 = run.press(path: "a", at: 0.0, point: Vec2(10, 10), interval: 0.5)
        let p2 = run.press(path: "a", at: 0.3, point: Vec2(12, 9), interval: 0.5)
        let p3 = run.press(path: "a", at: 0.6, point: Vec2(13, 9), interval: 0.5)
        #expect(p1 == 1 && p2 == 2 && p3 == 3)
    }

    @Test("PressRun: another element, late press, or far press starts again")
    func pressRunResetsOnMismatch() {
        var run = PressRun()
        _ = run.press(path: "a", at: 0.0, point: Vec2(10, 10), interval: 0.5)
        let p1 = run.press(path: "b", at: 0.1, point: Vec2(10, 10), interval: 0.5)
        let p2 = run.press(path: "b", at: 0.7, point: Vec2(10, 10), interval: 0.5)
        let p3 = run.press(path: "b", at: 0.8, point: Vec2(10 + PressRun.clickSlop + 1, 10), interval: 0.5)
        #expect(p1 == 1 && p2 == 1 && p3 == 1)
    }

    @Test("PressRun: clearing or moving away ends the run")
    func pressRunKeepOnAndClear() {
        var run = PressRun()
        _ = run.press(path: "a", at: 0.0, point: .zero, interval: 0.5)
        run.keepOn("a")
        let p2 = run.press(path: "a", at: 0.1, point: .zero, interval: 0.5)
        run.keepOn("b")
        let p1 = run.press(path: "a", at: 0.2, point: .zero, interval: 0.5)
        run.clear()
        let p0 = run.press(path: "a", at: 0.3, point: .zero, interval: 0.5)
        #expect(p2 == 2 && p1 == 1 && p0 == 1)
    }

    // MARK: - Double Press & Drag Click Run (`pointer_hit.rs:215,317`, `pointer_drag.rs:524`)

    @Test("pointer_hit: double press follows first press within interval and tolerance; double-press-only is hit target")
    @MainActor
    func doublePressBehavior() {
        struct S {
            var presses = 0
            var doubles = 0
            var other = 0
        }
        let rt = Runtime(state: S(), viewport: Vec2(300, 100), pixelScale: 1.0) { _, _ in
            row().w(300).h(100).children([
                el().key("row").w(100).h(100)
                    .onClick { $0.presses += 1 }
                    .onDoubleClick { s, _ in s.doubles += 1 },
                el().key("other").w(100).h(100)
                    .onClick { $0.other += 1 },
            ])
        }
        var t = 0.0
        _ = rt.frame(at: t)
        func click(_ pt: Vec2) {
            rt.pointerMove(to: pt, at: t)
            rt.pointerDown(at: pt, at: t)
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
            rt.pointerUp(at: pt, at: t)
            t += 1.0 / 120.0
            _ = rt.frame(at: t)
        }
        click(Vec2(50, 50))
        #expect(rt.state.presses == 1 && rt.state.doubles == 0)
        t += 0.1
        click(Vec2(53, 47))
        #expect(rt.state.presses == 2 && rt.state.doubles == 1)
        t += 0.1
        click(Vec2(50, 50))
        #expect(rt.state.presses == 3 && rt.state.doubles == 1)
        t += 0.1
        click(Vec2(50, 50))
        #expect(rt.state.presses == 4 && rt.state.doubles == 2)

        // Element with only onDoubleClick blocks behind sibling
        struct S2 { var doubles = 0; var behind = 0 }
        let rt2 = Runtime(state: S2(), viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in
            el().w(100).h(100).onClick { $0.behind += 1 }
                .child(el().w(100).h(100).onDoubleClick { s, _ in s.doubles += 1 })
        }
        _ = rt2.frame(at: 0)
        for i in 0..<2 {
            let base = Double(i) * 0.05
            rt2.pointerMove(to: Vec2(50, 50), at: base)
            rt2.pointerDown(at: Vec2(50, 50), at: base)
            _ = rt2.frame(at: base + 1.0 / 120.0)
            rt2.pointerUp(at: Vec2(50, 50), at: base + 0.02)
            _ = rt2.frame(at: base + 0.03)
        }
        #expect(rt2.state.doubles == 1 && rt2.state.behind == 0)
    }

    @Test("pointer_drag: a drag counts its run of clicks and resets after dragging past slop")
    @MainActor
    func dragCountsClickRun() {
        struct S {
            var dragClicks: [Int] = []
            var doubled = 0
        }
        let rt = Runtime(state: S(), viewport: Vec2(200, 200), pixelScale: 1.0) { _, _ in
            col().children([
                el().key("text").w(100).h(40)
                    .onDrag { s, d, _ in s.dragClicks.append(d.clicks) }
                    .onDoubleClick { s, _ in s.doubled += 1 },
                el().key("other").w(100).h(40)
                    .onDrag { s, d, _ in s.dragClicks.append(d.clicks) },
            ])
        }
        var t = 0.0
        _ = rt.frame(at: t)
        func click(_ pt: Vec2) -> Int {
            rt.pointerDown(at: pt, at: t)
            rt.pointerUp(at: pt, at: t + 0.01)
            t += 0.1
            _ = rt.frame(at: t)
            let c = rt.state.dragClicks.first ?? -1
            rt.state.dragClicks.removeAll()
            return c
        }
        let presses = (0..<4).map { click(Vec2(10 + Float($0), 10)) }
        #expect(presses == [1, 2, 3, 4])
        t += 1.0
        _ = rt.frame(at: t)
        #expect(click(Vec2(10, 10)) == 1)
        #expect(click(Vec2(10, 50)) == 1)
        #expect(click(Vec2(20, 10)) == 1)

        // Second press that drags keeps clicks == 2 on move, then ends run
        rt.pointerDown(at: Vec2(20, 10), at: t)
        t += 0.02
        rt.pointerMove(to: Vec2(40, 10), at: t)
        t += 0.02
        rt.pointerUp(at: Vec2(40, 10), at: t)
        t += 0.1
        _ = rt.frame(at: t)
        #expect(!rt.state.dragClicks.isEmpty && rt.state.dragClicks.allSatisfy { $0 == 2 })
        rt.state.dragClicks.removeAll()
        #expect(click(Vec2(20, 10)) == 1)

        // Double click on drag element still fires onDoubleClick
        t += 1.0
        _ = rt.frame(at: t)
        rt.state.doubled = 0
        _ = click(Vec2(10, 10))
        _ = click(Vec2(10, 10))
        #expect(rt.state.doubled == 1)
    }

    // MARK: - Press Moving (`tests/press_moving.rs`)

    @Test("press_moving: moving button under still pointer takes press; moving pointer off cancels press")
    @MainActor
    func pressMovingButtonAndPointer() {
        struct S { var x: Float = 0; var pressed = 0 }
        func pressThenSlide(moveAfter: Vec2?) -> Int {
            let rt = Runtime(state: S(), viewport: Vec2(300, 100), pixelScale: 2.0) { s, _ in
                el().child(
                    el().key("button").w(40).h(20).absolute(x: s.x, y: 0)
                        .onClick { $0.pressed += 1 }
                )
            }
            _ = rt.frame(at: 0.0)
            rt.pointerMove(to: Vec2(20, 10), at: 0.01)
            rt.pointerDown(at: Vec2(20, 10), at: 0.02)
            rt.update(at: 0.025) { s, _ in s.x = 200 }
            _ = rt.frame(at: 1.0 / 60.0 + 0.025)
            let target = moveAfter ?? Vec2(20, 10)
            rt.pointerMove(to: target, at: 0.05)
            rt.pointerUp(at: target, at: 0.06)
            _ = rt.frame(at: 0.07)
            return rt.state.pressed
        }
        #expect(pressThenSlide(moveAfter: nil) == 1)
        #expect(pressThenSlide(moveAfter: Vec2(25, 60)) == 0)
    }

    // MARK: - KeyReleases (`key_releases_tests.rs` & `gesture.rs:313`)

    @Test("KeyReleases: all 6 release routing and IME composition guard tests")
    func keyReleasesStateMachine() {
        // 1. Release goes to press focus until last key is up
        do {
            var k = KeyReleases()
            k.down(composing: false, repeat: false) { "a" }
            k.down(composing: false, repeat: true) { "b" }
            k.down(composing: false, repeat: false) { "b" }
            let e1 = k.eat(composing: false); let r1 = k.route()
            let e2 = k.eat(composing: false); let r2 = k.route()
            let r3 = k.route()
            #expect(!e1 && r1 == "b" && !e2 && r2 == "b" && r3 == nil)
        }
        // 2. Every release during composition is input method's
        do {
            var k = KeyReleases()
            k.down(composing: true, repeat: false) { "a" }
            k.down(composing: true, repeat: false) { "a" }
            let e1 = k.eat(composing: true); let e2 = k.eat(composing: true); let r = k.route()
            #expect(e1 && e2 && r == nil)
        }
        // 3. Key ending composition comes back up unheard once (including candidate click)
        do {
            var k = KeyReleases()
            k.down(composing: true, repeat: false) { "a" }
            k.imeTookKey()
            let e1 = k.eat(composing: false); let e2 = k.eat(composing: false)
            #expect(e1 && !e2)
            k.imeTookKey()
            let e3 = k.eat(composing: false); let e4 = k.eat(composing: false)
            #expect(e3 && !e4)
        }
        // 4. Key outside composition drops what it would have eaten
        do {
            var k = KeyReleases()
            k.imeTookKey()
            k.down(composing: false, repeat: false) { "a" }
            let e = k.eat(composing: false); let r = k.route()
            #expect(!e && r == "a")
        }
        // 5. Physical release while composing keeps .one for key that ends it
        do {
            var k = KeyReleases()
            k.down(composing: true, repeat: false) { "a" }
            k.composingRelease()
            let e1 = k.eat(composing: false); let e2 = k.eat(composing: false)
            #expect(e1 && !e2)
        }
        // 6. Losing window forgets everything
        do {
            var k = KeyReleases()
            k.down(composing: false, repeat: false) { "a" }
            k.imeTookKey()
            k.lost()
            let e = k.eat(composing: false); let r = k.route()
            #expect(!e && r == nil)
        }
    }

    @Test("gesture.rs:313: physical release carries logical key to onKeyUp after focused handler")
    @MainActor
    func physicalReleaseCarriesLogicalKeyToOnKeyUp() {
        struct S { var ups: [Key] = []; var swallow = false }
        let rt = Runtime(state: S(), viewport: Vec2(100, 100), pixelScale: 1.0) { _, _ in
            el().wFull().hFull()
                .onKeyUp { s, ev, _ in s.ups.append(ev.key); return true }
                .child(el().key("field").w(40).h(40).focusable(true).onPhysicalInput { s, _, _ in s.swallow })
        }
        _ = rt.frame(at: 0)
        let release = PhysicalInput.key(key: .space, mods: .none, pressed: false, repeat: false)
        let space = KeyEvent(key: .text(" "), mods: .none)
        #expect(rt.physicalWithFallback(release, fallbackKey: space, at: 0.01))
        _ = rt.frame(at: 0.02)
        #expect(rt.state.ups == [.text(" ")])

        if let pt = rt.find("field") {
            rt.pointerDown(at: pt, at: 0.03)
            rt.pointerUp(at: pt, at: 0.04)
        }
        rt.state.swallow = true
        _ = rt.physicalWithFallback(release, fallbackKey: space, at: 0.05)
        _ = rt.frame(at: 0.06)
        #expect(rt.state.ups.count == 1)
        rt.state.swallow = false
        _ = rt.physicalWithFallback(release, fallbackKey: space, at: 0.07)
        _ = rt.frame(at: 0.08)
        #expect(rt.state.ups.count == 2)
    }

    // MARK: - ModifierKeys (`modifier_keys.rs` - all 12 tests)

    @Test("ModifierKeys: all 11 runtime tests + AltGr state machine test")
    @MainActor
    func modifierKeysFullParity() {
        struct KState {
            var app: [KeyEvent] = []
            var field: [KeyEvent] = []
            var recorded: [PhysicalInput] = []
            var fieldTakes = false
            var recording = false
            var chords = 0
            var edit = TextEdit()
            var focusLost = 0
        }
        let makeRuntime: (Bool) -> Runtime<KState> = { enabled in
            let rt = Runtime(
                state: KState(),
                viewport: Vec2(200, 200),
                pixelScale: 1.0,
                onKey: { s, ev, tx in
                    s.app.append(ev)
                    if ev.key == .command("k") || (ev.mods.cmd && ev.key == .text("k")) {
                        s.chords += 1
                    }
                    if s.focusLost >= 0 { _ = tx }
                    return true
                },
                view: { _, _ in
                    col().children([
                        textInput(key: "field", \KState.edit).w(100).h(30)
                            .onInputKey { s, ev, _ in
                                s.field.append(ev)
                                return s.fieldTakes
                            },
                        el().key("recorder").w(100).h(30).focusable(true)
                            .onPhysicalInput { s, ev, _ in
                                if case .focusLost = ev { s.focusLost += 1 }
                                if s.recording { s.recorded.append(ev) }
                                return s.recording
                            },
                    ])
                }
            )
            rt.setModifierKeys(enabled)
            _ = rt.frame(at: 0)
            return rt
        }

        let shiftMods = Mods(shift: true)
        let altMods = Mods(alt: true)
        func modPairs(_ log: [KeyEvent]) -> [(ModifierKey, Bool)] {
            log.compactMap { ev in
                if case .modifier(let m, pressed: let p) = ev.key { return (m, p) }
                return nil
            }
        }
        func modifier(_ rt: Runtime<KState>, _ code: PhysicalKeyCode, _ pressed: Bool, _ mods: Mods, t: inout Double) -> Bool {
            t += 0.01
            let r = rt.physicalWithFallback(.key(key: code, mods: mods, pressed: pressed, repeat: false), fallbackKey: nil, at: t)
            _ = rt.frame(at: t)
            return r
        }
        func flags(_ rt: Runtime<KState>, _ mods: Mods, t: inout Double) -> Bool {
            t += 0.01
            let r = rt.physicalWithFallback(.modifiers(mods), fallbackKey: nil, at: t)
            _ = rt.frame(at: t)
            return r
        }
        func click(_ rt: Runtime<KState>, _ key: String, t: inout Double) {
            t += 0.01
            if let p = rt.find(key) {
                rt.pointerDown(at: p, at: t)
                rt.pointerUp(at: p, at: t + 0.005)
                t += 0.01
                _ = rt.frame(at: t)
            }
        }

        // 1. shift_alone_sends_press_and_release_with_side_and_mods_after_the_change
        do {
            let rt = makeRuntime(true); var t = 0.0
            #expect(modifier(rt, .shiftLeft, true, .none, t: &t))
            #expect(!flags(rt, shiftMods, t: &t))
            #expect(modifier(rt, .shiftLeft, false, shiftMods, t: &t))
            #expect(!flags(rt, .none, t: &t))
            let pairs = modPairs(rt.state.app)
            #expect(pairs.count == 2 && pairs[0] == (.shiftLeft, true) && pairs[1] == (.shiftLeft, false))
            #expect(rt.state.app[0].mods == shiftMods && rt.state.app[1].mods == .none)
            #expect(ModifierKey.shiftLeft.side == .left)
            #expect(!rt.focusVisible)
        }

        // 2. right_option_is_told_apart_from_left_option
        do {
            let rt = makeRuntime(true); var t = 0.0
            _ = modifier(rt, .altRight, true, .none, t: &t)
            _ = modifier(rt, .altLeft, true, altMods, t: &t)
            _ = modifier(rt, .altRight, false, altMods, t: &t)
            _ = modifier(rt, .altLeft, false, altMods, t: &t)
            let pairs = modPairs(rt.state.app)
            #expect(pairs.map(\.0) == [.altRight, .altLeft, .altRight, .altLeft])
            #expect(pairs.map(\.1) == [true, true, false, false])
            #expect(rt.state.app.map(\.mods.alt) == [true, true, true, false])
            #expect(ModifierKey.altRight.side == .right && ModifierKey.fn.side == nil)
        }

        // 3. a_held_modifier_then_a_letter_is_the_usual_chord
        do {
            let rt = makeRuntime(true); var t = 0.0
            let cmd = Mods(cmd: true)
            _ = modifier(rt, .superLeft, true, .none, t: &t)
            #expect(rt.state.app[0].mods.cmd)
            #expect(rt.state.chords == 0)
            _ = rt.physicalWithFallback(
                .key(key: .keyK, mods: cmd, pressed: true, repeat: false),
                fallbackKey: KeyEvent(key: .command("k"), mods: cmd),
                at: t + 0.01
            )
            _ = rt.frame(at: t + 0.02)
            #expect(rt.state.app[1] == KeyEvent(key: .command("k"), mods: cmd))
            #expect(rt.state.chords == 1)

            click(rt, "field", t: &t)
            _ = modifier(rt, .shiftRight, true, .none, t: &t)
            _ = rt.physicalWithFallback(
                .key(key: .keyA, mods: shiftMods, pressed: true, repeat: false),
                fallbackKey: KeyEvent(key: .text("A"), mods: shiftMods),
                at: t + 0.01
            )
            _ = rt.frame(at: t + 0.02)
            #expect(rt.state.edit.text == "A")
        }

        // 4. modifier_keys_never_fire_chords_insert_text_or_repeat
        do {
            let rt = makeRuntime(true); var t = 0.0
            click(rt, "field", t: &t)
            rt.state.app.removeAll()
            for code: PhysicalKeyCode in [.superLeft, .controlLeft, .altLeft, .shiftLeft, .fn] {
                _ = modifier(rt, code, true, .none, t: &t)
                _ = rt.physicalWithFallback(.key(key: code, mods: .none, pressed: true, repeat: true), fallbackKey: nil, at: t + 0.005)
                _ = rt.frame(at: t + 0.006)
                _ = modifier(rt, code, false, .none, t: &t)
            }
            #expect(rt.state.chords == 0 && rt.state.edit.text.isEmpty)
            #expect(rt.state.app.count == 10)
            #expect(rt.state.app.allSatisfy { if case .modifier = $0.key { return true }; return false })
            var direct = TextEdit()
            let directOutcome = direct.handleKey(KeyEvent(key: .modifier(.shiftLeft, pressed: true), mods: shiftMods))
            #expect(directOutcome == .ignored)
        }

        // 5. a_focused_field_hears_modifiers_before_the_window_unless_nothing_is_focused
        do {
            let rt = makeRuntime(true); var t = 0.0
            _ = modifier(rt, .shiftLeft, true, .none, t: &t)
            #expect(rt.state.app.count == 1 && rt.state.field.isEmpty)
            _ = modifier(rt, .shiftLeft, false, shiftMods, t: &t)
            click(rt, "field", t: &t)
            rt.state.app.removeAll()
            rt.state.fieldTakes = true
            _ = modifier(rt, .controlRight, true, .none, t: &t)
            #expect(rt.state.app.isEmpty && rt.state.field.count == 1)
            rt.state.fieldTakes = false
            _ = modifier(rt, .controlRight, false, Mods(ctrl: true), t: &t)
            #expect(rt.state.app.count == 1 && rt.state.field.count == 2)
            #expect(rt.state.app[0].key == .modifier(.controlRight, pressed: false))
        }

        // 6. off_by_default_existing_handlers_see_no_modifier_keys
        do {
            let rt = makeRuntime(false); var t = 0.0
            #expect(!rt.modifierKeys())
            _ = modifier(rt, .shiftLeft, true, .none, t: &t)
            #expect(!modifier(rt, .shiftLeft, false, shiftMods, t: &t))
            #expect(!flags(rt, .none, t: &t))
            _ = rt.physicalWithFallback(.focusLost, fallbackKey: nil, at: t + 0.01)
            _ = rt.frame(at: t + 0.02)
            #expect(rt.state.app.isEmpty)
        }

        // 7. a_key_up_the_platform_never_sent_comes_from_the_flags_or_focus_loss
        do {
            let rt = makeRuntime(true); var t = 0.0
            let both = Mods(shift: true, alt: true)
            _ = modifier(rt, .shiftLeft, true, .none, t: &t)
            _ = flags(rt, shiftMods, t: &t)
            _ = modifier(rt, .altRight, true, shiftMods, t: &t)
            _ = flags(rt, both, t: &t)
            _ = modifier(rt, .fn, true, both, t: &t)
            #expect(flags(rt, altMods, t: &t))
            let tail1 = Array(modPairs(rt.state.app).dropFirst(3))
            #expect(tail1.count == 1 && tail1[0] == (.shiftLeft, false))
            _ = rt.physicalWithFallback(.focusLost, fallbackKey: nil, at: t + 0.01)
            _ = rt.frame(at: t + 0.02)
            let tail2 = Array(modPairs(rt.state.app).dropFirst(4))
            #expect(tail2.map(\.0) == [.altRight, .fn] && tail2.map(\.1) == [false, false])
            #expect(rt.state.app.dropFirst(4).allSatisfy { $0.mods == .none })
            #expect(!modifier(rt, .altRight, false, .none, t: &t))
            #expect(rt.state.app.count == 6)
        }

        // 8. altgr_held_without_the_alt_flag_stays_down_until_its_key_up
        do {
            let rt = makeRuntime(true); var t = 0.0
            _ = modifier(rt, .altRight, true, .none, t: &t)
            _ = flags(rt, .none, t: &t)
            _ = flags(rt, shiftMods, t: &t)
            #expect(modPairs(rt.state.app).count == 1 && modPairs(rt.state.app)[0] == (.altRight, true))
            _ = modifier(rt, .altRight, false, shiftMods, t: &t)
            #expect(modPairs(rt.state.app).count == 2 && modPairs(rt.state.app)[1] == (.altRight, false))
        }

        // 9. a_recorder_takes_modifiers_first_and_on_key_never_hears_half_of_what_it_took
        do {
            let rt = makeRuntime(true); var t = 0.0
            click(rt, "recorder", t: &t)
            rt.state.recording = true
            _ = modifier(rt, .altLeft, true, .none, t: &t)
            _ = flags(rt, altMods, t: &t)
            _ = rt.physicalWithFallback(
                .key(key: .keyK, mods: altMods, pressed: true, repeat: false),
                fallbackKey: KeyEvent(key: .text("k"), mods: altMods),
                at: t + 0.01
            )
            _ = rt.frame(at: t + 0.02)
            rt.state.recording = false
            #expect(!flags(rt, .none, t: &t))
            #expect(!modifier(rt, .altLeft, false, altMods, t: &t))
            #expect(rt.state.recorded.count == 3)
            #expect(rt.state.app.isEmpty)

            _ = modifier(rt, .shiftLeft, true, .none, t: &t)
            rt.state.recording = true
            _ = modifier(rt, .shiftLeft, false, shiftMods, t: &t)
            _ = modifier(rt, .altRight, true, .none, t: &t)
            rt.state.recording = false
            _ = modifier(rt, .shiftLeft, true, .none, t: &t)
            let p1 = modPairs(rt.state.app)
            #expect(p1.map(\.0) == [.shiftLeft, .shiftLeft] && p1.map(\.1) == [true, true])

            rt.state.recording = true
            _ = rt.physicalWithFallback(.focusLost, fallbackKey: nil, at: t + 0.03)
            _ = rt.frame(at: t + 0.04)
            rt.state.recording = false
            #expect(rt.state.recorded.last == .focusLost)
            #expect(rt.state.app.count == 2)
            #expect(!modifier(rt, .shiftLeft, false, shiftMods, t: &t))
            _ = modifier(rt, .altRight, true, .none, t: &t)
            let p2 = Array(modPairs(rt.state.app).dropFirst(2))
            #expect(p2.count == 1 && p2[0] == (.altRight, true))
        }

        // 10. a_blur_or_a_hide_releases_held_keys_once
        do {
            let rt = makeRuntime(true); var t = 0.0
            click(rt, "recorder", t: &t)
            rt.dispatchFocus(true, at: t)
            _ = modifier(rt, .shiftLeft, true, .none, t: &t)
            rt.dispatchFocus(false, at: t + 0.01)
            _ = rt.frame(at: t + 0.02)
            let firstBlur = modPairs(rt.state.app)
            #expect(firstBlur.map(\.0) == [.shiftLeft, .shiftLeft] && firstBlur.map(\.1) == [true, false])
            #expect(rt.state.focusLost == 1)

            rt.dispatchFocus(true, at: t + 0.03)
            _ = modifier(rt, .altRight, true, .none, t: &t)
            _ = rt.keysLost(at: t + 0.04)
            #expect(rt.keysQueued)
            rt.dispatchFocus(false, at: t + 0.05)
            _ = rt.frame(at: t + 0.06)
            let secondBlur = Array(modPairs(rt.state.app).dropFirst(2))
            #expect(secondBlur.map(\.0) == [.altRight, .altRight] && secondBlur.map(\.1) == [true, false])
            #expect(rt.state.focusLost == 2)

            rt.dispatchFocus(true, at: t + 0.07)
            _ = rt.keysLost(at: t + 0.08)
            _ = rt.frame(at: t + 0.09)
            #expect(rt.state.focusLost == 3)
        }

        // 11. a_focus_move_inside_the_window_keeps_modifiers_held
        do {
            let rt = makeRuntime(true); var t = 0.0
            _ = modifier(rt, .shiftLeft, true, .none, t: &t)
            click(rt, "recorder", t: &t)
            click(rt, "field", t: &t)
            _ = modifier(rt, .shiftLeft, false, shiftMods, t: &t)
            let pairs = modPairs(rt.state.app)
            #expect(pairs.map(\.0) == [.shiftLeft, .shiftLeft] && pairs.map(\.1) == [true, false])
        }

        // 12. windows_altgr_clearing_control_and_alt_is_no_release
        do {
            let ctrl = Mods(ctrl: true)
            let keyEv: (PhysicalKeyCode, Bool, Mods) -> PhysicalInput = { .key(key: $0, mods: $2, pressed: $1, repeat: false) }
            let sent: ([KeyEvent]) -> [(ModifierKey, Bool)] = { modPairs($0) }
            for altgrClears in [false, true] {
                var keys = ModifierKeysState(enabled: true)
                _ = keys.apply(keyEv(.controlLeft, true, .none), consumed: false, altGrClearsFlags: altgrClears)
                _ = keys.apply(.modifiers(ctrl), consumed: false, altGrClearsFlags: altgrClears)
                _ = keys.apply(keyEv(.altRight, true, ctrl), consumed: false, altGrClearsFlags: altgrClears)
                let cleared = sent(keys.apply(.modifiers(.none), consumed: false, altGrClearsFlags: altgrClears))
                if !altgrClears {
                    #expect(cleared.count == 1 && cleared[0] == (.controlLeft, false))
                    continue
                }
                #expect(cleared.isEmpty)
                let upAlt = sent(keys.apply(keyEv(.altRight, false, .none), consumed: false, altGrClearsFlags: true))
                #expect(upAlt.count == 1 && upAlt[0] == (.altRight, false))
                #expect(sent(keys.apply(.modifiers(ctrl), consumed: false, altGrClearsFlags: true)).isEmpty)
                let upCtrl = sent(keys.apply(keyEv(.controlLeft, false, ctrl), consumed: false, altGrClearsFlags: true))
                #expect(upCtrl.count == 1 && upCtrl[0] == (.controlLeft, false))
            }
        }
    }

    // MARK: - App IME (`tests/app_ime.rs` + `focus.rs:1301`)

    @Test("AppIme: imeCursor, app composition, focus handoff to field, and Return/Escape mid-composition")
    @MainActor
    func appImeFullParity() {
        struct Editor {
            var log: [String] = []
            var field = TextEdit()
            var caret = true
        }
        func makeEditor() -> Runtime<Editor> {
            let rt = Runtime(
                state: Editor(),
                viewport: Vec2(300, 200),
                pixelScale: 1.0,
                onKey: { s, ev, _ in
                    s.log.append("key \(ev.key)")
                    return true
                },
                view: { s, _ in
                    col().w(300).h(200).children([
                        textInput(key: "field", \Editor.field).w(200).h(30),
                        el().key("page").w(300).h(100).children(
                            s.caret ? [el().key("caret").absolute(x: 40, y: 20).w(2).h(18).imeCursor()] : []
                        ),
                    ])
                }
            )
            rt.onIme = { s, ev, _ in
                switch ev {
                case .enabled: s.log.append("Enabled")
                case .disabled: s.log.append("Disabled")
                case .preedit(let p): s.log.append("Preedit(\(p.text))")
                case .commit(let t): s.log.append("Commit(\(t))")
                case .cancel: s.log.append("Cancel")
                case .deleteSurrounding: s.log.append("DeleteSurrounding")
                }
                return true
            }
            _ = rt.frame(at: 0)
            return rt
        }

        // 1. an_ime_cursor_turns_the_input_method_on_at_its_rect_unless_a_field_has_focus
        do {
            let rt = makeEditor()
            #expect(rt.imeArea == [40, 50, 2, 18])
            rt.update(at: 0.01) { _, tx in tx.focus("field") }
            _ = rt.frame(at: 0.02)
            let fieldArea = rt.imeArea
            #expect(fieldArea != nil && (fieldArea?[1] ?? 999) < 30)
            rt.update(at: 0.03) { s, tx in tx.blur(); s.caret = false }
            _ = rt.frame(at: 0.04)
            #expect(rt.imeArea == nil)
        }

        // 2. the_app_hears_the_composition_and_typing_arrives_once
        do {
            let rt = makeEditor()
            _ = rt.keyDown(KeyEvent(key: .text("a")), at: 0.01)
            _ = rt.frame(at: 0.01)
            _ = rt.ime(.enabled, at: 0.02)
            _ = rt.ime(.preedit(ImePreedit(text: "か", cursorUTF8: 0..<3)), at: 0.03)
            _ = rt.frame(at: 0.03)
            _ = rt.keyDown(KeyEvent(key: .enter), at: 0.04)
            _ = rt.keyDown(KeyEvent(key: .escape), at: 0.05)
            _ = rt.ime(.commit("家"), at: 0.06)
            _ = rt.frame(at: 0.06)
            _ = rt.keyDown(KeyEvent(key: .enter), at: 0.07)
            _ = rt.frame(at: 0.07)
            #expect(rt.state.log == ["key text(\"a\")", "Enabled", "Preedit(か)", "Commit(家)", "key enter"])
        }

        // 3. a_focused_field_takes_the_input_method_but_the_apps_composition_ends_in_the_app
        do {
            let rt = makeEditor()
            _ = rt.ime(.preedit(ImePreedit(text: "か")), at: 0.01)
            _ = rt.frame(at: 0.01)
            rt.update(at: 0.02) { _, tx in tx.focus("field") }
            _ = rt.frame(at: 0.02)
            _ = rt.ime(.preedit(ImePreedit(text: "")), at: 0.03)
            _ = rt.ime(.disabled, at: 0.04)
            _ = rt.ime(.preedit(ImePreedit(text: "ね")), at: 0.05)
            _ = rt.ime(.commit("猫"), at: 0.06)
            _ = rt.frame(at: 0.06)
            #expect(rt.state.log == ["Preedit(か)", "Preedit()", "Disabled"])
            #expect(rt.state.field.text == "猫")
        }

        // 4. without_on_ime_an_ime_cursor_hears_nothing
        do {
            let rt = makeEditor()
            rt.onIme = nil
            _ = rt.ime(.preedit(ImePreedit(text: "か")), at: 0.01)
            _ = rt.frame(at: 0.01)
            _ = rt.keyDown(KeyEvent(key: .enter), at: 0.02)
            _ = rt.frame(at: 0.02)
            #expect(rt.state.log == ["key enter"])
        }

        // 5. focus.rs:1301: Return and Escape confirm and cancel a composition and nothing else
        do {
            struct FState {
                var field = TextEdit()
                var named = TextEdit()
                var log: [String] = []
            }
            let rt = Runtime(
                state: FState(),
                viewport: Vec2(300, 300),
                pixelScale: 1.0,
                onKey: { s, ev, _ in
                    if ev.key == .escape { s.log.append("escape") }
                    return false
                },
                view: { _, _ in
                    col().w(300).h(300).children([
                        textInput(key: "field", \FState.field).w(100).h(20),
                        textInput(key: "named", \FState.named).w(100).h(20)
                            .onSubmit { s, _, _ in s.log.append("submit") },
                        el().key("continue").w(80).h(20).focusable(true).defaultButton()
                            .onClick { $0.log.append("continue") },
                    ])
                }
            )
            _ = rt.frame(at: 0)
            for (field, after) in [("field", "continue"), ("named", "submit")] {
                rt.update(at: 0.01) { _, tx in tx.focus(field) }
                _ = rt.frame(at: 0.02)
                #expect(rt.focusedKey == field)
                _ = rt.ime(.preedit(ImePreedit(text: "ka")), at: 0.03)
                _ = rt.frame(at: 0.03)
                _ = rt.keyDown(KeyEvent(key: .enter), at: 0.04)
                _ = rt.keyDown(KeyEvent(key: .escape), at: 0.05)
                #expect(rt.state.log.isEmpty)
                #expect(rt.focusedKey == field)
                _ = rt.ime(.commit("か"), at: 0.06)
                _ = rt.frame(at: 0.06)
                _ = rt.keyDown(KeyEvent(key: .enter), at: 0.07)
                #expect(rt.state.log == [after])
                rt.state.log.removeAll()
            }
            #expect(rt.state.field.text == "か" && rt.state.named.text == "か")
        }
    }
}
