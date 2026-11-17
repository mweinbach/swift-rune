import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

@Suite("Tx Slice 2 Parity Tests")
struct TxSlice2ParityTests {
    // MARK: - Helpers

    private struct WalkDev: Equatable {
        var instant: Bool = false
        var settle: Bool = false
        var motion: Spring? = nil
        var motionCurve: Anim<Float>? = nil
        var liveOnly: Bool = false

        mutating func apply(_ op: Int) {
            switch op {
            case 0: instant = true
            case 1: instant = false
            case 2: instant = true; settle = true
            case 3:
                motion = Spring(duration: 0.14, bounce: 0.05)
                motionCurve = nil
            case 4:
                let anim = Anim<Float>(
                    curve: .tween(duration: 0.35, easing: .cubicBezier(CubicBezier(0.16, 1.0, 0.3, 1.0))),
                    delay: 0.05
                )
                motion = Spring(duration: max(0.01, anim.curve.logicalDuration), bounce: 0.0)
                motionCurve = anim
            default:
                break
            }
        }

        mutating func merge(_ one: WalkDev) {
            instant = instant || one.instant
            settle = settle || one.settle
            if let m = one.motion {
                motion = m
                motionCurve = one.motionCurve
            }
        }

        var snaps: Bool { instant }
        var lands: Bool { settle }
        var layoutSpring: Spring { motion ?? Spring(duration: 0.4, bounce: 0.1) }
        var layoutAnim: Anim<Float> { motionCurve ?? Anim(curve: .spring(layoutSpring)) }
        var flight: Spring { motion ?? Spring(duration: 0.2, bounce: 0.0) }
        var window: Spring? { snaps ? nil : (motion ?? MotionTokens.REFLOW) }
    }

    private func applyWalkOp(_ tx: inout Tx, op: Int) {
        switch op {
        case 0: tx.instant()
        case 1: tx.animated()
        case 2: tx.settle()
        case 3: tx.motion(Spring(duration: 0.14, bounce: 0.05))
        case 4:
            tx.motionCurve(
                Anim<Float>(
                    curve: .tween(duration: 0.35, easing: .cubicBezier(CubicBezier(0.16, 1.0, 0.3, 1.0))),
                    delay: 0.05
                )
            )
        default: break
        }
    }

    private struct SeenKey: Hashable {
        var snaps: Bool
        var lands: Bool
        var layoutSpring: Spring
        var layoutAnim: Anim<Float>
        var flight: Spring
        var window: Spring?
    }

    private func seen(_ tx: Tx) -> SeenKey {
        let node = Spring(duration: 0.4, bounce: 0.1)
        let matched = Spring(duration: 0.2, bounce: 0.0)
        return SeenKey(
            snaps: tx.commitKind.snaps,
            lands: tx.commitKind.lands,
            layoutSpring: tx.motionSource?.spring ?? node,
            layoutAnim: tx.motionSource?.anim ?? Anim(curve: .spring(node)),
            flight: tx.motionSource?.spring ?? matched,
            window: tx.commitKind.snaps ? nil : (tx.motionSource?.spring ?? MotionTokens.REFLOW)
        )
    }

    private func seen(_ dev: WalkDev) -> SeenKey {
        SeenKey(
            snaps: dev.snaps,
            lands: dev.lands,
            layoutSpring: dev.layoutSpring,
            layoutAnim: dev.layoutAnim,
            flight: dev.flight,
            window: dev.window
        )
    }

    // MARK: - src/el/tx/tests.rs (5-op walk + all-pair merge matrix)

    @Test("tx/tests.rs: exhaustive 5-op commit intent walk & all-pair merge matches Dev")
    func exhaustiveFiveOpWalkAndMergeMatrix() {
        var reachable: [(seq: [Int], dev: WalkDev, tx: Tx)] = [([], WalkDev(), Tx())]
        var seenStates: Set<SeenKey> = [seen(WalkDev())]

        func walk(depth: Int, dev: WalkDev, tx: Tx, seq: [Int]) {
            if depth == 5 { return }
            for op in 0..<5 {
                var nextDev = dev
                var nextTx = tx
                nextDev.apply(op)
                applyWalkOp(&nextTx, op: op)
                #expect(seen(nextTx) == seen(nextDev))
                let key = seen(nextDev)
                if seenStates.insert(key).inserted {
                    reachable.append((seq + [op], nextDev, nextTx))
                }
                walk(depth: depth + 1, dev: nextDev, tx: nextTx, seq: seq + [op])
            }
        }

        walk(depth: 0, dev: WalkDev(), tx: Tx(), seq: [])
        #expect(seenStates.count == 12)

        for a in reachable {
            for b in reachable {
                var devMerged = a.dev
                var txMerged = a.tx
                devMerged.merge(b.dev)
                txMerged.merge(b.tx)
                #expect(seen(txMerged) == seen(devMerged))
            }
        }
    }

    // MARK: - src/el/tx.rs (Shell, elementAt*, tracing, window commands, announcements, sendKey, focus, fonts)

    @Test("tx.rs: Shell ordering, toggleMaximized/FullScreen, setFontFamilies, tracing & traceChannel")
    func txShellTracingFontsAndWindowCommands() throws {
        #expect(Shell.close < Shell.quit)
        #expect(Shell.quit < Shell.relaunch)

        struct S { var dummy: Int = 0 }
        let rt = Runtime<S>(state: S(), viewport: Vec2(400, 300), pixelScale: 1.0) { _, _ in
            row().child(el().key("lbl").size(80, 24))
        }
        _ = rt.frame(at: 0.0)

        rt.slice2State.tracingEnabled = true
        var tx1 = rt.makeTx(at: 0.016)
        #expect(tx1.tracing == true)
        tx1.traceEvent("did_work")
        tx1.traceChannel("fps", kind: "level", value: 120)
        tx1.setShell(.close)
        tx1.toggleMaximized()
        tx1.toggleFullScreen()
        tx1.setFontFamilies("Inter", "JetBrains Mono")
        tx1.announce("Saved", .polite)
        tx1.announce("Alert!", .assertive)

        var tx2 = Tx()
        tx2.setShell(Shell.relaunch)
        tx2.setShell(Shell.quit) // should not downgrade from relaunch
        tx1.merge(tx2)
        withFontFamilies(sans: "", mono: "") {
            rt.applyTx(tx1, at: 0.016)
        }

        #expect(rt.slice2State.lastShellRequest == Shell.relaunch)
        #expect(rt.slice2State.toggleMaximizedRequested == true)
        #expect(rt.slice2State.toggleFullScreenRequested == true)
        #expect(rt.slice2State.customFontFamilies?.sans == "Inter")
        #expect(rt.slice2State.customFontFamilies?.mono == "JetBrains Mono")
        #expect(rt.slice2State.traceEvents == ["did_work"])
        try #require(rt.slice2State.traceChannels.count == 1)
        #expect(rt.slice2State.traceChannels[0].name == "fps")
        #expect(rt.slice2State.traceChannels[0].kind == "level")
        #expect(rt.slice2State.traceChannels[0].value == 120)
        #expect(rt.slice2State.announcements.last?.text == "Alert!")
        #expect(rt.slice2State.announcements.last?.politeness == LiveRegionPoliteness.assertive)

        // When tracing is disabled, traceEvent/traceChannel skip recording.
        rt.slice2State.tracingEnabled = false
        var evalCount = 0
        var txDisabled = rt.makeTx(at: 0.032)
        #expect(txDisabled.tracing == false)
        txDisabled.traceEvent({ evalCount += 1; return "expensive" }())
        txDisabled.traceChannel("ignored", kind: "counter", value: 1)
        rt.applyTx(txDisabled, at: 0.032)
        #expect(evalCount == 0)
        #expect(rt.slice2State.traceEvents.count == 1)
        #expect(rt.slice2State.traceChannels.count == 1)
    }

    @Test("tx.rs: elementAt / elementAtWith / elementAtIn / elementAtInWith pick and scope")
    func txElementAtAndElementAtIn() {
        struct S {
            var pickedKeys: [String?] = []
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 160), pixelScale: 1.0) { _, _ in
            col().size(200, 160)
                .child(
                    el().key("panel-a").size(200, 80)
                        .child(el().key("inner-a").size(100, 40))
                )
                .child(el().key("panel-b").size(200, 80).opacity(0.0))
        }
        _ = rt.frame(at: 0.0)

        var tx = rt.makeTx(at: 0.016)
        tx.elementAt(20, 20) { (s: inout S, picked, _) in
            s.pickedKeys.append(picked?.key)
        }
        tx.elementAtWith(20, 100, pick: .default) { (s: inout S, picked, _) in
            // opacity(0) is skipped by Pick.default
            s.pickedKeys.append(picked?.key)
        }
        tx.elementAtIn("panel-a", x: 20, y: 100) { (s: inout S, picked, _) in
            // (20, 100) is outside panel-a -> nil!
            s.pickedKeys.append(picked?.key)
        }
        tx.elementAtInWith("panel-a", x: 20, y: 20, pick: Pick.default.transparent(true)) { (s: inout S, picked, _) in
            s.pickedKeys.append(picked?.key)
        }
        tx.elementAtWith(20, 100, pick: Pick.default.transparent(true)) { (s: inout S, picked, _) in
            s.pickedKeys.append(picked?.key)
        }
        rt.applyTx(tx, at: 0.016)

        #expect(rt.state.pickedKeys.count == 5)
        #expect(rt.state.pickedKeys[0] == "inner-a")
        #expect(rt.state.pickedKeys[1] == nil)
        #expect(rt.state.pickedKeys[2] == nil)
        #expect(rt.state.pickedKeys[3] == "inner-a")
        #expect(rt.state.pickedKeys[4] == "panel-b")
    }

    @Test("tx.rs: focus(_, ring:), returnFocus(_, ring:), sendKey, focusVisible, byKeysFlag & wakeAt")
    func txFocusRingSendKeyAndFlags() {
        struct S {
            var keyLog: [String] = []
            var sawFocusVisible: [Bool] = []
            var sawByKeys: [Bool] = []
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            col()
                .child(
                    el().key("first").focusable(true).size(120, 32)
                        .onKey { s, ev, tx in
                            s.sawFocusVisible.append(tx.focusVisible())
                            s.sawByKeys.append(tx.byKeysFlag())
                            if case .enter = ev.key {
                                s.keyLog.append("first:enter")
                                tx.sendKey(KeyEvent(key: .tab))
                                return true
                            }
                            return false
                        }
                )
                .child(
                    el().key("second").focusable(true).size(120, 32)
                        .onKey { s, ev, tx in
                            s.sawFocusVisible.append(tx.focusVisible())
                            s.sawByKeys.append(tx.byKeysFlag())
                            if case .text(let ch) = ev.key {
                                s.keyLog.append("second:\(ch)")
                                tx.returnFocus("first", ring: true)
                                tx.focus("third", ring: false) // explicit focus wins over returnFocus
                                return true
                            }
                            return false
                        }
                )
                .child(el().key("third").focusable(true).size(120, 32))
        }
        _ = rt.frame(at: 0.0)

        var fTx = rt.makeTx(at: 0.016)
        fTx.focus("first", ring: false)
        rt.applyTx(fTx, at: 0.016)
        _ = rt.frame(at: 0.016)
        #expect(rt.focusedKey == "first")
        #expect(rt.focusVisible == false)

        // Dispatch Enter on "first"; sendKey(.tab) queues synthetic Tab and moves focus to "second"
        let handled = rt.keyDown(KeyEvent(key: .enter), at: 0.032)
        #expect(handled == true)
        _ = rt.frame(at: 0.032)
        #expect(rt.state.keyLog == ["first:enter"])
        #expect(rt.state.sawByKeys == [true, true])
        #expect(rt.focusedKey == "second")
        #expect(rt.focusVisible == true)

        // Dispatch text "x" on "second"; explicit tx.focus("third", ring: false) overrides returnFocus
        _ = rt.keyDown(KeyEvent(key: .text("x")), at: 0.048)
        _ = rt.frame(at: 0.048)
        #expect(rt.focusedKey == "third")
        #expect(rt.focusVisible == false)

        // Verify wakeAt and Tx.took + liveOnly + assistiveTechnology
        rt.slice2State.assistiveTechnologyActive = true
        var metaTx = rt.makeTx(at: 0.050)
        #expect(metaTx.assistiveTechnology() == true)
        metaTx.liveOnly()
        #expect(Tx.took(false, &metaTx) == false)
        #expect(metaTx.liveOnlyRequested == false)
        metaTx.wakeAt(0.250)
        metaTx.colorMotion(Spring(duration: 0.12, bounce: 0))
        rt.applyTx(metaTx, at: 0.050)
        #expect(rt.nextWakeDeadline != nil)
        #expect(abs((rt.nextWakeDeadline ?? 0) - 0.250) < 0.001)
    }

    // MARK: - src/el/tx/{keys,press}.rs

    @Test("tx/keys.rs & press.rs: keyRepeat, physicalKey, keyBase, mods, inputTime, focused & dragRepeat")
    func txKeysContextAndDragRepeat() {
        struct S {
            var repeats: [Bool] = []
            var phys: [PhysicalKeyCode?] = []
            var bases: [Character?] = []
            var modsSeen: [Mods] = []
            var times: [Double?] = []
            var focusedSeen: [String?] = []
            var dragRepeatFlags: [Bool] = []
            var dragPhases: [DragPhase] = []
            var dragMods: [Mods] = []
        }
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 100), pixelScale: 1.0) { _, _ in
            col()
                .child(
                    el().key("keybox").focusable(true).size(120, 40)
                        .onKey { s, _, tx in
                            s.repeats.append(tx.keyRepeat())
                            s.phys.append(tx.physicalKey())
                            s.bases.append(tx.keyBase())
                            s.modsSeen.append(tx.mods)
                            s.times.append(tx.inputTime())
                            s.focusedSeen.append(tx.focused())
                            return true
                        }
                )
                .child(
                    el().key("stepper").size(120, 40)
                        .onDrag { s, drag, tx in
                            let rep = tx.dragRepeat()
                            s.dragPhases.append(drag.phase)
                            s.dragRepeatFlags.append(rep)
                            s.dragMods.append(tx.mods)
                            if drag.phase == .down || rep {
                                tx.dragRepeatAfter(.milliseconds(rep ? 50 : 200))
                            }
                        }
                )
        }
        _ = rt.frame(at: 0.0)

        var fTx = rt.makeTx(at: 0.01)
        fTx.focus("keybox", ring: true)
        rt.applyTx(fTx, at: 0.01)
        _ = rt.frame(at: 0.01)

        let optMod = Mods(alt: true)
        let shiftMod = Mods(shift: true)
        _ = rt.physicalInput(.key(key: PhysicalKeyCode.keyA, mods: optMod, pressed: true, repeat: false), at: 1.0)
        _ = rt.keyDown(KeyEvent(key: .text("å"), mods: optMod), isRepeat: false, at: 1.0)
        _ = rt.keyDown(KeyEvent(key: .text("å"), mods: optMod), isRepeat: true, at: 1.2)
        _ = rt.physicalInput(.key(key: PhysicalKeyCode.keyA, mods: optMod, pressed: false, repeat: false), at: 1.3)

        #expect(rt.state.repeats == [false, true])
        #expect(rt.state.phys.first == .keyA)
        #expect(rt.state.bases.first == "a")
        #expect(rt.state.modsSeen == [optMod, optMod])
        #expect(rt.state.times == [1.0, 1.2])
        #expect(rt.state.focusedSeen == ["keybox", "keybox"])

        // Drag repeat: press down on stepper at y=60 with .shift held -> initial drag (repeat=false), then step at +0.2s and +0.25s.
        rt.pointerDown(at: Vec2(20, 60), mods: shiftMod, at: 2.0)
        #expect(rt.state.dragRepeatFlags == [false])
        #expect(rt.state.dragMods == [shiftMod])

        _ = rt.frame(at: 2.10) // not due yet (< 2.20)
        #expect(rt.state.dragRepeatFlags == [false])

        _ = rt.frame(at: 2.20) // first repeat due at 2.0 + 0.2
        #expect(rt.state.dragRepeatFlags == [false, true])
        #expect(rt.state.dragMods == [shiftMod, shiftMod])

        _ = rt.frame(at: 2.25) // second repeat due at 2.20 + 0.05
        #expect(rt.state.dragRepeatFlags == [false, true, true])

        // Releasing clears activeDrag and armed drag repeat.
        rt.pointerUp(at: Vec2(20, 60), at: 2.26)
        _ = rt.frame(at: 2.35)
        #expect(rt.state.dragPhases == [.down, .move, .move, .up])
        #expect(rt.state.dragRepeatFlags == [false, true, true, false])
        #expect(rt.kitHooks.pressRepeat.attempt == nil)
        #expect(rt.nextWakeDeadline(after: 2.35) == nil)
    }

    @Test("sticky.rs & scaleMotion: stuckShadow renders shadows proportional to sticky shift & scaleMotion applies")
    func stuckShadowAndScaleMotion() {
        struct S {}
        let rt = Runtime<S>(state: S(), viewport: Vec2(200, 120), pixelScale: 1.0) { _, _ in
            col()
                .key("scroller")
                .size(200, 120)
                .scrollY(stickBottom: false)
                .scaleMotion(Spring(duration: 0.25, bounce: 0.1))
                .child(
                    col()
                        .child(
                            el().key("hdr").size(200, 30)
                                .stickyTop(0)
                                .stuckShadow(Shadow(x: 0, y: 2, blur: 6, color: Color.black.alpha(0.5)))
                                .stuckShadow(Shadow(x: 0, y: 1, blur: 2, color: Color.black.alpha(0.3), inset: true))
                        )
                        .child(el().key("body").size(200, 400))
                )
        }
        let s0 = rt.frame(at: 0.0)
        let shadowsAtRest = s0.primitives.filter {
            $0.params.y == Float(PrimitiveKind.dropShadow.rawValue) || $0.params.y == Float(PrimitiveKind.insetShadow.rawValue)
        }
        #expect(shadowsAtRest.isEmpty)

        var sTx = Tx()
        sTx.scrollToY("scroller", 40)
        rt.applyTx(sTx, at: 0.016)
        let s1 = rt.frame(at: 0.016)

        let shadowsWhileStuck = s1.primitives.filter {
            $0.params.y == Float(PrimitiveKind.dropShadow.rawValue) || $0.params.y == Float(PrimitiveKind.insetShadow.rawValue)
        }
        #expect(shadowsWhileStuck.count == 2)
    }
}
