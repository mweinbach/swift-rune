import Foundation
import Testing
@testable import Rune

private let unitDT: Double = 1.0 / 60.0

// MARK: - Shared Test Fixtures (`playground_tests.rs`)

private final class MutexBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private struct UnitReal {
    var count: Int = 0
    var polls: Int = 0
    var holdsEscape: Bool = false
    var field: TextEdit = TextEdit("")
    var pastes: [String] = []
    var drops: Int = 0
    var focus: [Bool] = []
    var waker: Waker? = nil
    var inbox: MutexBox<[Int]>? = nil
    var typing: Bool = false
    var typed: String = ""
}

private struct UnitLab {
    var ticks: Int = 0
    var presses: Int = 0
}

private struct UnitFade {
    var t0: Double = 0.0
    var log: [(String, Double)] = []
}

private struct UnitTip {
    var hidden: Bool = false
}

private struct UnitTray {
    var hovering: Bool = false
}

private struct UnitKnob {
    var value: Int = 0
}

private func unitView(_ s: UnitReal, _ cx: inout Cx<UnitReal>) -> El<UnitReal> {
    col().wFull().hFull()
        .onDropFiles { state, files, _ in state.drops += files.count }
        .child(text("count \(s.count)").key("count"))
        .child(el().key("inc").size(40, 20).onClick { state in state.count += 1 })
        .child(
            textInput(key: "field", \UnitReal.field)
                .font(TextStyle(size: 14, weight: 400))
                .size(200, 24)
        )
}

private func unitLabView(_ p: UnitLab, _ cx: inout Cx<UnitLab>) -> El<UnitLab> {
    col().wFull().hFull()
        .child(text("ticks \(p.ticks) presses \(p.presses)").key("lab"))
        .child(el().key("bump").size(40, 20).onClick { p in p.presses += 1 })
}

private func unitLabPoll(_ p: inout UnitLab, _ t: Double, _ play: inout Play<UnitLab>) -> Bool {
    play.tx.wakeAfter(1.0)
    let due = Int(floor(t))
    let changed = due != p.ticks
    p.ticks = due
    return changed
}

private func unitActivityView(_ s: UnitReal, _ cx: inout Cx<UnitReal>) -> El<UnitReal> {
    text("live \(s.count)").key("activity")
}

private func unitFadeView(_ p: UnitFade, _ cx: inout Cx<UnitFade>) -> El<UnitFade> {
    let names = p.log.map { "\"\($0.0)\"" }.joined(separator: ", ")
    return text("[\(names)]").key("fade")
}

private func unitFadeStory() -> Story<UnitFade> {
    Story(path: "Motion/Fade", { UnitFade() }, unitFadeView)
        .trigger("r", "Fade in") { p, play in
            p.t0 = play.now()
            p.log.append(("start", 0.0))
            play.after(0.5) { p, play in
                p.log.append(("half", play.now() - p.t0))
                play.after(0.25) { p, play in
                    p.log.append(("end", play.now() - p.t0))
                }
            }
        }
        .trigger("f", "Finish") { p, _ in
            p.log.append(("finish", 0.0))
        }
}

private func unitBasePlayground() -> PlaygroundHost<UnitReal> {
    PlaygroundHost<UnitReal>()
        .enabled(true)
        .page("Live/Activity", view: unitActivityView)
        .story(Story(path: "Lab", { UnitLab() }, unitLabView).poll(unitLabPoll))
        .story(unitFadeStory())
        .triggerPlay("big", key: "d", label: "Double") { s, _ in s.count *= 2 }
}

private func unitRuntimeWith(
    _ playground: PlaygroundHost<UnitReal>,
    open: String?? = nil,
    windowed: Bool = true
) -> (Runtime<UnitReal>, Double) {
    var app = App<UnitReal>(
        "playground",
        size: Vec2(800, 500),
        init: { UnitReal() },
        view: unitView
    )
    .scene("big") { s, _ in s.count = 100 }
    .scene("holding") { s, _ in s.holdsEscape = true }
    .scene("Motion/Still") { _, _ in }
    .poll { s, _, _ in
        s.polls += 1
        return false
    }
    .onKey { s, ev, _ in
        if case .text(let t) = ev.key, s.typing {
            s.typed += t
            return true
        }
        return s.holdsEscape && ev.key == .escape
    }
    .onFocus { s, focused, _ in
        s.focus.append(focused)
    }

    app = app.playground(playground)
    let rt = app.headlessRuntime(size: Vec2(800, 500), env: Env(systemDark: false, scale: 1.0))
    if let live = rt.playgroundLive {
        if windowed {
            #if os(macOS)
            live.shortcutMenu = app.playgroundHost?.liveSpec.shortcutMenuEnabled ?? true
            #endif
        } else {
            live.shortcutMenu = false
        }
        if let openStory = open {
            do {
                try rt.openPlayground(at: openStory, variant: nil)
            } catch {
                fatalError("unitRuntimeWith openPlayground(\(String(describing: openStory))) failed: \(error)")
            }
        }
    }
    rt.frame(at: 0.0)
    return (rt, 0.0)
}

private func unitRuntime(open: String?? = nil) -> (Runtime<UnitReal>, Double) {
    unitRuntimeWith(unitBasePlayground(), open: open, windowed: true)
}

private func stepClock(_ t: inout Double, _ dt: Double = unitDT) -> Double {
    t += dt
    return t
}

private func press(_ rt: Runtime<UnitReal>, _ t: inout Double, _ key: Key, mods: Mods = Mods()) {
    _ = rt.keyDown(KeyEvent(key: key, mods: mods), at: t)
    rt.frame(at: stepClock(&t))
}

private func letter(_ rt: Runtime<UnitReal>, _ t: inout Double, _ ch: String) {
    press(rt, &t, .text(ch))
}

private func escape(_ rt: Runtime<UnitReal>, _ t: inout Double) {
    press(rt, &t, .escape)
}

private func findInfo(_ rt: Runtime<UnitReal>, _ key: String) -> ElementInfo? {
    rt.elements().first { $0.key == key && !$0.exiting }
}

private func showsText(_ rt: Runtime<UnitReal>, _ key: String) -> String {
    findInfo(rt, key)?.text ?? ""
}

private func centerOf(_ rt: Runtime<UnitReal>, _ key: String) -> Vec2 {
    guard let info = findInfo(rt, key) else {
        fatalError("missing element key '\(key)' (available: \(rt.elements().compactMap(\.key)))")
    }
    let r = info.rect
    return Vec2(r[0] + r[2] * 0.5, r[1] + r[3] * 0.5)
}

private func tap(_ rt: Runtime<UnitReal>, _ t: inout Double, _ key: String) {
    let pt = centerOf(rt, key)
    rt.pointerMove(to: pt, at: t)
    rt.pointerDown(at: pt, button: .primary, mods: Mods(), at: t)
    rt.pointerUp(at: pt, button: .primary, mods: Mods(), at: t)
    rt.frame(at: stepClock(&t))
}

private func focusedKey(_ rt: Runtime<UnitReal>) -> String? {
    rt.elements().first { $0.focused }?.key
}

private func selectedIdx(_ rt: Runtime<UnitReal>) -> Int {
    rt.playgroundLive?.selected ?? -1
}

private func headerName(_ rt: Runtime<UnitReal>) -> String? {
    rt.playgroundLive?.header
}

private func regionNow(_ rt: Runtime<UnitReal>) -> PlaygroundRegion {
    rt.playgroundLive?.region ?? .list
}

private func isOpenNow(_ rt: Runtime<UnitReal>) -> Bool {
    rt.playgroundLive?.isOpen ?? false
}

// MARK: - Core Playground Unit Tests (`playground_tests.rs`)

@Suite("Playground Core Unit Parity Tests")
struct PlaygroundCoreUnitParityTests {
    @Test("bottom bar shortens the app and opens the playground")
    func barShortensAppAndOpensPlayground() {
        var (rt, t) = unitRuntime(open: nil)
        let openInfo = findInfo(rt, "playground-open")
        #expect(openInfo != nil)
        #expect((openInfo?.rect[1] ?? 0) >= 500.0 - PlaygroundConst.bar)
        tap(rt, &t, "inc")
        #expect(rt.state.count == 1)
        tap(rt, &t, "playground-open")
        #expect(isOpenNow(rt))
        #expect(showsText(rt, "count") == "count 100")
    }

    @Test("a scene gets a fresh state and Back restores the real one")
    func sceneGetsFreshStateAndBackRestoresReal() {
        var (rt, t) = unitRuntime(open: nil)
        tap(rt, &t, "inc")
        rt.update(at: t) { _, tx in tx.openPlayground() }
        rt.frame(at: stepClock(&t))
        tap(rt, &t, "inc")
        #expect(showsText(rt, "count") == "count 101")
        tap(rt, &t, "playground-trigger-d")
        rt.frame(at: stepClock(&t))
        #expect(showsText(rt, "count") == "count 202")
        #expect(rt.state.count == 1)
        tap(rt, &t, "playground-back")
        #expect(!isOpenNow(rt))
        #expect(showsText(rt, "count") == "count 1")
        #expect(findInfo(rt, "playground-trigger-d") == nil)
    }

    @Test("the stage takes Escape first before giving list focus and closing")
    func stageTakesEscapeFirst() {
        var (rt, t) = unitRuntime(open: .some("holding"))
        #expect(isOpenNow(rt))
        escape(rt, &t)
        #expect(isOpenNow(rt), "scene's onKey took Escape")
        tap(rt, &t, "playground-item-0")
        tap(rt, &t, "field")
        #expect(focusedKey(rt) == "field")
        escape(rt, &t)
        #expect(isOpenNow(rt), "focused field took Escape")
        escape(rt, &t)
        #expect(isOpenNow(rt) && regionNow(rt) == .list, "unhandled Escape gives list the keyboard")
        escape(rt, &t)
        #expect(!isOpenNow(rt), "Escape from list closes playground")
        #expect(!rt.state.holdsEscape)
    }

    @Test("frame.rs: a page's poll that changed something commits for `poll`, not `input`")
    func pagePollCommitsForPoll() {
        var (rt, t) = unitRuntime(open: .some("lab"))
        #expect(showsText(rt, "lab").hasPrefix("ticks 0"))
        var tickWhy: UInt16? = nil
        for _ in 0..<90 {
            rt.commitWhy = 0
            rt.frame(at: stepClock(&t))
            if tickWhy == nil, showsText(rt, "lab").hasPrefix("ticks 1") {
                tickWhy = rt.commitWhy
            }
        }
        let why = tickWhy ?? 0
        #expect(tickWhy != nil, "the page's timer ticked")
        #expect(why & CommitWhy.poll != 0, "\(CommitWhy.names(why))")
        #expect(why & CommitWhy.input == 0, "\(CommitWhy.names(why))")
    }

    @Test("a page keeps its own state and timer while open, and replay requests immediate poll")
    func pageKeepsOwnStateAndTimerWhileOpen() {
        var (rt, t) = unitRuntime(open: .some("lab"))
        tap(rt, &t, "bump")
        tap(rt, &t, "bump")
        for _ in 0..<70 { rt.frame(at: stepClock(&t)) }
        #expect(showsText(rt, "lab") == "ticks 1 presses 2")
        tap(rt, &t, "playground-item-0")
        tap(rt, &t, "playground-item-4")
        #expect(showsText(rt, "lab") == "ticks 1 presses 2")
        tap(rt, &t, "playground-trigger-r")
        #expect(rt.nextWakeDeadline(after: t - 0.0001) != nil)
        rt.frame(at: stepClock(&t))
        #expect(showsText(rt, "lab") == "ticks 1 presses 0")
        tap(rt, &t, "bump")
        escape(rt, &t)
        escape(rt, &t)
        rt.update(at: t) { _, tx in tx.openPlayground() }
        rt.frame(at: stepClock(&t))
        #expect(showsText(rt, "lab").hasSuffix("presses 0"))
    }

    @Test("a live page draws and changes the real state")
    func livePageDrawsAndChangesRealState() {
        var (rt, t) = unitRuntime(open: .some("Activity"))
        #expect(showsText(rt, "activity") == "live 0")
        rt.update(at: t) { s, _ in s.count = 7 }
        rt.frame(at: stepClock(&t))
        #expect(showsText(rt, "activity") == "live 7")
    }

    @Test("the real state keeps polling while playground is open")
    func realStateKeepsPollingWhileOpen() {
        var (rt, t) = unitRuntime(open: .some(nil))
        let before = rt.state.polls
        for _ in 0..<5 { rt.frame(at: stepClock(&t)) }
        #expect(rt.state.polls >= before + 5)
        let scenePolls = rt.playgroundState(as: UnitReal.self)?.polls ?? 0
        #expect(scenePolls >= 5)
    }

    @Test("without the bar, the app lays out untouched")
    func withoutBarAppLaysOutUntouched() {
        let plainApp = App<UnitReal>("playground", size: Vec2(800, 500), init: { UnitReal() }, view: unitView)
        let plainRt = plainApp.headlessRuntime(size: Vec2(800, 500), env: Env(systemDark: false, scale: 1.0))
        plainRt.frame(at: 0.0)
        let plain = plainRt.elements().map { ($0.path, $0.rect) }

        let pg = PlaygroundHost<UnitReal>().enabled(true).bar(false)
        let barlessApp = plainApp.playground(pg)
        let barlessRt = barlessApp.headlessRuntime(size: Vec2(800, 500), env: Env(systemDark: false, scale: 1.0))
        barlessRt.frame(at: 0.0)
        let barless = barlessRt.elements().map { ($0.path, $0.rect) }

        #expect(plain.count == barless.count)
        for (a, b) in zip(plain, barless) {
            #expect(a.0 == b.0 && a.1 == b.1)
        }
    }

    @Test("keys walk the stories in their groups order")
    func keysWalkStoriesInGroupsOrder() {
        var (rt, t) = unitRuntime(open: .some(nil))
        // Scenes: big(0), holding(1); Motion: Still(2), Fade(5); Live: Activity(3); Pages: Lab(4).
        let walk: [(Key, Int, String?)] = [
            (.arrowDown, 1, nil),
            (.arrowDown, 1, "Motion"),
            (.arrowDown, 2, nil),
            (.arrowDown, 5, nil),
            (.arrowDown, 5, "Live"),
            (.arrowDown, 3, nil),
            (.arrowUp, 3, "Live"),
            (.arrowUp, 5, nil),
        ]
        for (key, at, on) in walk {
            press(rt, &t, key)
            #expect(selectedIdx(rt) == at)
            #expect(headerName(rt) == on)
        }
        letter(rt, &t, "j")
        #expect(selectedIdx(rt) == 3 && headerName(rt) == nil)
        letter(rt, &t, "k")
        #expect(selectedIdx(rt) == 5 && headerName(rt) == nil)
        press(rt, &t, .arrowDown, mods: Mods(cmd: true))
        #expect(selectedIdx(rt) == 4)
        press(rt, &t, .arrowUp, mods: Mods(cmd: true))
        #expect(selectedIdx(rt) == 0)
        press(rt, &t, .arrowUp)
        #expect(headerName(rt) == "Scenes")
        press(rt, &t, .arrowUp)
        #expect(selectedIdx(rt) == 4)
    }

    @Test("a replay runs its steps on the logical clock identically across frame rates and start times")
    func replayRunsStepsOnLogicalClockIdentically() {
        var logs: [[(String, Int64)]] = []
        for (start, dt) in [(0.0, 1.0 / 60.0), (3.3, 1.0 / 24.0)] {
            var (rt, t) = unitRuntime(open: .some("fade"))
            t = start
            rt.frame(at: t)
            letter(rt, &t, "f")
            t += dt
            rt.frame(at: t)
            letter(rt, &t, "r")
            for _ in 0..<4 {
                t += dt
                rt.frame(at: t)
            }
            letter(rt, &t, "r")
            t += dt
            rt.frame(at: t)
            #expect(showsText(rt, "fade") == "[\"start\"]")
            let count = Int(1.0 / dt)
            for _ in 0..<count {
                t += dt
                rt.frame(at: t)
            }
            let st = rt.playgroundState(as: UnitFade.self)!
            logs.append(st.log.map { ($0.0, Int64(($0.1 * 1e6).rounded())) })
        }
        #expect(logs[0].map(\.0) == ["start", "half", "end"])
        #expect(logs[0].map(\.1) == [0, 500_000, 750_000])
        #expect(logs[0].map(\.0) == logs[1].map(\.0))
        #expect(logs[0].map(\.1) == logs[1].map(\.1))
    }

    @Test("right goes into the side column and tab or left comes back")
    func rightGoesIntoSideColumnAndTabOrLeftComesBack() {
        var (rt, t) = unitRuntime(open: .some("Fade"))
        press(rt, &t, .arrowRight)
        #expect(focusedKey(rt) == "playground-trigger-r")
        press(rt, &t, .arrowDown)
        #expect(focusedKey(rt) == "playground-trigger-f")
        press(rt, &t, .arrowDown)
        #expect(focusedKey(rt) == "playground-trigger-r")
        letter(rt, &t, "j")
        #expect(selectedIdx(rt) == 5, "j does not leave story from side column")
        press(rt, &t, .tab)
        #expect(focusedKey(rt) == nil)
        press(rt, &t, .arrowRight)
        press(rt, &t, .arrowLeft)
        #expect(focusedKey(rt) == nil && selectedIdx(rt) == 5)
        press(rt, &t, .arrowDown)
        press(rt, &t, .arrowDown)
        #expect(selectedIdx(rt) == 3)
        press(rt, &t, .arrowRight)
        #expect(focusedKey(rt) == nil, "live page has no controls")
    }

    @Test("the shortcut opens and closes it without a menu, vs menu item on macOS window")
    func shortcutOpensAndClosesWithoutMenu() {
        var (rt, t) = unitRuntimeWith(unitBasePlayground(), open: .some(nil), windowed: false)
        let chord = Mods(shift: true, cmd: true)
        #expect(isOpenNow(rt))
        press(rt, &t, .command("d"), mods: chord)
        #expect(!isOpenNow(rt))
        press(rt, &t, .command("d"), mods: chord)
        #expect(isOpenNow(rt))

        var (winRt, wt) = unitRuntimeWith(unitBasePlayground(), open: .some(nil), windowed: true)
        #if os(macOS)
        let expectedMenuHandled = true
        #else
        let expectedMenuHandled = false
        #endif
        press(winRt, &wt, .command("d"), mods: chord)
        #expect(isOpenNow(winRt) == expectedMenuHandled)
    }

    @Test("leaving a story part way drops its queued steps")
    func leavingStoryPartWayDropsQueuedSteps() {
        var (rt, t) = unitRuntime(open: .some("Fade"))
        letter(rt, &t, "r")
        letter(rt, &t, "j")
        for _ in 0..<60 { rt.frame(at: stepClock(&t)) }
        letter(rt, &t, "k")
        for _ in 0..<60 { rt.frame(at: stepClock(&t)) }
        #expect(showsText(rt, "fade") == "[\"start\"]")
    }

    @Test("a new stage ends the old one's exits")
    func newStageEndsOldExits() {
        let tipView: (UnitTip, inout Cx<UnitTip>) -> El<UnitTip> = { p, _ in
            var root: El<UnitTip> = col().wFull().hFull()
            if !p.hidden {
                root = root.child(
                    el().key("tip").size(120, 120).transition(Transition.opacity).onHover { _, _, _ in }
                )
            }
            return root
        }
        let story = Story(path: "Fixes/Tip", { UnitTip() }, tipView)
            .trigger("h", "Hide") { p, _ in p.hidden = true }
        var (rt, t) = unitRuntimeWith(unitBasePlayground().story(story), open: .some("Tip"))
        let pt = centerOf(rt, "tip")
        rt.pointerMove(to: pt, at: t)
        rt.frame(at: stepClock(&t))
        letter(rt, &t, "h")
        rt.frame(at: stepClock(&t))
        let exiting: () -> Bool = { rt.elements().contains { $0.key == "tip" && $0.exiting } }
        #expect(exiting())
        letter(rt, &t, "j")
        #expect(!exiting())
        rt.pointerMove(to: Vec2(pt.x + 300, pt.y), at: t)
        rt.frame(at: stepClock(&t))
        rt.pointerMove(to: pt, at: t)
        rt.frame(at: stepClock(&t))
    }

    @Test("replacing stage cancels titlebar press")
    func replacingStageCancelsTitlebarPress() {
        let bar: (UnitReal, inout Cx<UnitReal>) -> El<UnitReal> = { _, _ in
            el().key("bar").size(120, 50).windowDrag()
        }
        let pg = unitBasePlayground().page("First", view: bar).page("Second", view: bar)
        let (rt, t) = unitRuntimeWith(pg, open: nil)
        rt.setCaption(TitlebarCaption(height: 28.0))
        try? rt.openPlayground(at: "First", variant: nil)
        let firstCenter = centerOf(rt, "bar")
        rt.pointerDown(at: firstCenter, button: .secondary, at: t)
        try? rt.openPlayground(at: "Second", variant: nil)
        let secondCenter = centerOf(rt, "bar")
        rt.pointerUp(at: secondCenter, button: .secondary, at: t)
        #expect(rt.takeWindowMenu() == nil)
        rt.pointerDown(at: secondCenter, button: .secondary, at: t)
        rt.pointerUp(at: secondCenter, button: .secondary, at: t)
        #expect(rt.takeWindowMenu() != nil)
    }

    @Test("root handlers reach the app above the bar and the stage")
    func rootHandlersReachAppAboveBarAndStage() {
        var (rt, t) = unitRuntime(open: nil)
        let fieldCenter = centerOf(rt, "field")
        rt.pointerMove(to: fieldCenter, at: t)
        rt.pointerDown(at: fieldCenter, button: .primary, mods: Mods(), at: t)
        rt.pointerUp(at: fieldCenter, button: .primary, mods: Mods(), at: t)
        rt.frame(at: stepClock(&t))
        rt.paste(ClipboardContent("hi"), at: t)
        rt.frame(at: stepClock(&t))
        _ = rt.dropFiles([URL(fileURLWithPath: "a.txt")], at: nil, at: t)
        rt.frame(at: stepClock(&t))
        rt.dispatchFocus(false, at: t)
        rt.frame(at: stepClock(&t))
        #expect(rt.state.field.text == "hi")
        #expect(rt.state.drops == 1)
        #expect(rt.state.focus.last == false)

        rt.update(at: t) { _, tx in tx.openPlayground() }
        rt.frame(at: stepClock(&t))
        let stageField = centerOf(rt, "field")
        rt.pointerMove(to: stageField, at: t)
        rt.pointerDown(at: stageField, button: .primary, mods: Mods(), at: t)
        rt.pointerUp(at: stageField, button: .primary, mods: Mods(), at: t)
        rt.frame(at: stepClock(&t))
        rt.paste(ClipboardContent("staged"), at: t)
        rt.frame(at: stepClock(&t))
        _ = rt.dropFiles([URL(fileURLWithPath: "b.txt"), URL(fileURLWithPath: "c.txt")], at: stageField, at: t)
        rt.frame(at: stepClock(&t))
        rt.dispatchFocus(true, at: t)
        rt.frame(at: stepClock(&t))
        let scene = rt.playgroundState(as: UnitReal.self)!
        #expect(scene.field.text == "staged")
        #expect(scene.drops == 2)
        #expect(scene.focus == [true])
        #expect(rt.state.field.text == "hi" && rt.state.drops == 1)
    }

    @Test("a key after a press that opens the playground reaches it")
    func keyAfterPressOpeningPlaygroundReachesIt() {
        var (rt, t) = unitRuntime(open: nil)
        let openPt = centerOf(rt, "playground-open")
        rt.pointerDown(at: openPt, button: .primary, mods: Mods(), at: t)
        rt.pointerUp(at: openPt, button: .primary, mods: Mods(), at: t)
        _ = rt.keyDown(KeyEvent(key: .arrowDown, mods: Mods()), at: t)
        rt.frame(at: stepClock(&t))
        #expect(isOpenNow(rt))
        #expect(selectedIdx(rt) == 1)
    }

    @Test("a new stage forgets what the pointer held in the old one")
    func newStageForgetsPointerHoldAndDropHover() {
        let trayView: (UnitTray, inout Cx<UnitTray>) -> El<UnitTray> = { _, _ in
            el().key("tray").wFull().hFull()
                .onDropFiles { _, _, _ in }
                .onDropHover { p, on, _ in p.hovering = on }
        }
        let story = Story(path: "Fixes/Tray", { UnitTray() }, trayView)
        var (rt, t) = unitRuntimeWith(unitBasePlayground().story(story), open: .some("Tray"))
        let at = centerOf(rt, "tray")
        rt.dragFiles([URL(fileURLWithPath: "a.txt")], at: at, at: t)
        rt.frame(at: stepClock(&t))
        #expect(rt.playgroundState(as: UnitTray.self)?.hovering == true)
        rt.pointerDown(at: at, button: .primary, mods: Mods(), at: t)
        press(rt, &t, .escape)
        letter(rt, &t, "j")
        #expect(selectedIdx(rt) == 0)
        rt.dragFilesLeave(at: t)
        rt.frame(at: stepClock(&t))
        rt.pointerMove(to: Vec2(at.x + 10, at.y), at: t)
        rt.pointerUp(at: Vec2(at.x + 10, at.y), button: .primary, mods: Mods(), at: t)
        rt.frame(at: stepClock(&t))
        #expect(rt.dropHovered == nil)
    }

    @Test("a story's time scale stays with it and restores app scale when switched or closed")
    func storyTimeScaleStaysWithIt() {
        let slowView: (UnitLab, inout Cx<UnitLab>) -> El<UnitLab> = { _, cx in
            cx.timeScale(0.25)
            return text("slow").key("slow")
        }
        var (rt, t) = unitRuntimeWith(unitBasePlayground().story(Story(path: "Fixes/Slow", { UnitLab() }, slowView)), open: .some("Slow"))
        #expect(rt.cxSettings.viewTimeScale == 0.25)
        letter(rt, &t, "j")
        #expect(rt.cxSettings.viewTimeScale == 1.0)
        letter(rt, &t, "k")
        #expect(rt.cxSettings.viewTimeScale == 0.25)
        escape(rt, &t)
        #expect(!isOpenNow(rt))
        #expect(rt.cxSettings.viewTimeScale == 1.0)
    }

    @Test("an element focused in the stage keeps its keys until escape")
    func elementFocusedInStageKeepsKeysUntilEscape() {
        let knobView: (UnitKnob, inout Cx<UnitKnob>) -> El<UnitKnob> = { k, _ in
            col().wFull().hFull()
                .child(text("value \(k.value)").key("value"))
                .child(
                    el().key("knob").size(60, 20).focusable()
                        .onClick { _ in }
                        .onKey { state, ev, _ in
                            if ev.key == .arrowUp { state.value += 1; return true }
                            if ev.key == .arrowDown { state.value -= 1; return true }
                            return false
                        }
                )
        }
        var (rt, t) = unitRuntimeWith(unitBasePlayground().story(Story(path: "Fixes/Knob", { UnitKnob() }, knobView)), open: .some("Knob"))
        let at = selectedIdx(rt)
        tap(rt, &t, "knob")
        #expect(focusedKey(rt) == "knob")
        press(rt, &t, .arrowDown)
        press(rt, &t, .arrowUp)
        press(rt, &t, .arrowUp)
        #expect(showsText(rt, "value") == "value 1" && selectedIdx(rt) == at)
        escape(rt, &t)
        #expect(isOpenNow(rt) && focusedKey(rt) == nil)
        letter(rt, &t, "j")
        #expect(selectedIdx(rt) != at)
    }

    @Test("a replay from the side column keeps the keyboard there")
    func replayFromSideColumnKeepsKeyboardThere() {
        var (rt, t) = unitRuntime(open: .some("Fade"))
        press(rt, &t, .arrowRight)
        press(rt, &t, .arrowDown)
        #expect(focusedKey(rt) == "playground-trigger-f")
        letter(rt, &t, "r")
        rt.frame(at: stepClock(&t))
        #expect(showsText(rt, "fade") == "[\"start\"]")
        #expect(focusedKey(rt) == "playground-trigger-f")
        press(rt, &t, .arrowUp)
        #expect(focusedKey(rt) == "playground-trigger-r")
    }

    @Test("scene triggers and sides match case-insensitively by name")
    func sceneTriggersAndSidesMatchByName() {
        let pg = unitBasePlayground()
            .triggerPlay("still", key: "q", label: "Add four") { s, _ in s.count += 4 }
            .side("STILL") { s, _ in text("side \(s.count)").key("still-side") }
        var (rt, t) = unitRuntimeWith(pg, open: .some("Motion/Still"))
        #expect(showsText(rt, "still-side") == "side 0")
        letter(rt, &t, "q")
        rt.frame(at: stepClock(&t))
        #expect(showsText(rt, "still-side") == "side 4")
    }

    @Test("a long story list scrolls and reaches what was off screen")
    func longStoryListScrollsAndReachesOffScreen() {
        var pg = unitBasePlayground()
        for n in 0..<30 {
            pg = pg.story(Story(path: "Many/Story \(n)", { UnitLab() }, unitLabView))
        }
        var (rt, t) = unitRuntimeWith(pg, open: .some(nil))
        rt.frame(at: stepClock(&t))
        let last = rt.playgroundLive!.order.last!
        let item = "playground-item-\(last)"
        let (_, y) = (centerOf(rt, item).x, centerOf(rt, item).y)
        #expect(y > 500.0)
        let list = findInfo(rt, "playground-list")!.rect
        rt.wheel(WheelEvent(dy: -4000.0), at: Vec2(list[0] + 20, list[1] + 100), now: t)
        rt.frame(at: stepClock(&t))
        rt.frame(at: stepClock(&t))
        let c2 = centerOf(rt, item)
        #expect(c2.y < y && c2.y < 500.0)
        let hitKey = rt.elementAt(c2.x, c2.y)?.key
        #expect(hitKey != nil)
    }
}

// MARK: - Chrome, Groups, Keys, Scenes, Stage, Variants, Widths (`playground/*_tests.rs`)

@Suite("Playground Submodule Unit Parity Tests")
struct PlaygroundSubmoduleUnitParityTests {
    @Test("chrome follows app dark predicate and otherwise follows system")
    func chromeFollowsAppDarkOrSystem() {
        func matchesColor(_ a: Color?, _ b: Color) -> Bool {
            guard let a else { return false }
            return abs(a.r - b.r) < 1e-5 && abs(a.g - b.g) < 1e-5 && abs(a.b - b.b) < 1e-5 && abs(a.a - b.a) < 1e-5
        }
        var (rt, t) = unitRuntimeWith(unitBasePlayground().dark { $0.count >= 100 }, open: .some("Fade"), windowed: true)
        #expect(matchesColor(findInfo(rt, "playground")?.fill, Tok.theme(dark: false).bg))
        rt.state.count = 100
        rt.update(at: t) { _, _ in }
        for _ in 0..<60 { rt.frame(at: stepClock(&t)) }
        #expect(matchesColor(findInfo(rt, "playground")?.fill, Tok.theme(dark: true).bg))
        #expect(findInfo(rt, "playground-theme")?.label == "Dark appearance")

        var (sysRt, st) = unitRuntime(open: .some("Fade"))
        sysRt.state.count = 100
        sysRt.update(at: st) { _, _ in }
        for _ in 0..<60 { sysRt.frame(at: stepClock(&st)) }
        #expect(matchesColor(findInfo(sysRt, "playground")?.fill, Tok.theme(dark: false).bg))
    }

    @Test("groups fold on header click, arrows, and enter; unfold when open story chosen")
    func groupsFoldingAndArrowInteraction() {
        let shown: (Runtime<UnitReal>, Int) -> Bool = { findInfo($0, "playground-item-\($1)") != nil }

        var (rt, t) = unitRuntime(open: .some("big"))
        #expect(shown(rt, 2) && shown(rt, 5))
        tap(rt, &t, "playground-group-2")
        #expect(!shown(rt, 2) && !shown(rt, 5))
        #expect(shown(rt, 3))
        #expect(headerName(rt) == "Motion" && selectedIdx(rt) == 0)
        tap(rt, &t, "playground-group-2")
        #expect(shown(rt, 2) && shown(rt, 5))

        var (rt2, t2) = unitRuntime(open: .some("Still"))
        press(rt2, &t2, .arrowUp)
        #expect(headerName(rt2) == "Motion")
        press(rt2, &t2, .arrowLeft)
        #expect(!shown(rt2, 2))
        press(rt2, &t2, .arrowDown)
        #expect(headerName(rt2) == "Live")
        press(rt2, &t2, .arrowUp)
        press(rt2, &t2, .arrowRight)
        #expect(shown(rt2, 2))
        press(rt2, &t2, .enter)
        #expect(!shown(rt2, 2))
        press(rt2, &t2, .enter)
        #expect(shown(rt2, 2))
        #expect(selectedIdx(rt2) == 2)

        var (rt3, t3) = unitRuntime(open: .some("Fade"))
        tap(rt3, &t3, "playground-group-2")
        #expect(headerName(rt3) == "Motion" && selectedIdx(rt3) == 5)
        letter(rt3, &t3, "r")
        #expect(headerName(rt3) == "Motion" && !shown(rt3, 5))
        escape(rt3, &t3)
        rt3.update(at: t3) { _, tx in tx.openPlayground() }
        rt3.frame(at: stepClock(&t3))
        #expect(!shown(rt3, 2) && !shown(rt3, 5))
        #expect(headerName(rt3) == "Motion" && selectedIdx(rt3) == 5)

        var (rt4, t4) = unitRuntime(open: .some("big"))
        tap(rt4, &t4, "playground-group-2")
        rt4.update(at: t4) { _, tx in tx.openPlaygroundAt("Fade") }
        rt4.frame(at: stepClock(&t4))
        #expect(shown(rt4, 5) && headerName(rt4) == nil && selectedIdx(rt4) == 5)
    }

    @Test("while typing predicate holds, stage onKey gets keys before playground; without it, playground keeps them")
    func typingPredicateRoutesKeys() {
        let pg = unitBasePlayground()
            .typing { $0.typing }
            .triggerPlay("big", key: "t", label: "Type") { s, _ in s.typing = true }
        var (rt, t) = unitRuntimeWith(pg, open: .some("big"))
        letter(rt, &t, "t")
        rt.frame(at: stepClock(&t))
        for ch in ["j", "r", "t", "2"] { letter(rt, &t, ch) }
        #expect(rt.playgroundState(as: UnitReal.self)?.typed == "jrt2")
        #expect(selectedIdx(rt) == 0)
        press(rt, &t, .arrowDown)
        #expect(selectedIdx(rt) == 1)

        var (rt2, t2) = unitRuntimeWith(
            unitBasePlayground().triggerPlay("big", key: "t", label: "Type") { s, _ in s.typing = true },
            open: .some("big")
        )
        letter(rt2, &t2, "t")
        rt2.frame(at: stepClock(&t2))
        letter(rt2, &t2, "j")
        #expect(selectedIdx(rt2) == 1)
    }

    @Test("scenes filter lists only kept scenes, choosing scene runs r trigger, and story runs r only on init")
    func scenesFilterAndRTriggerTiming() {
        var (rt, t) = unitRuntimeWith(unitBasePlayground().scenes { $0.contains("/") }, open: .some(nil))
        #expect(findInfo(rt, "playground-item-0") == nil && findInfo(rt, "playground-item-1") == nil)
        #expect(findInfo(rt, "playground-item-2") != nil)
        #expect(selectedIdx(rt) == 2)
        #expect(rt.playgroundLive?.findStory("big") == nil)
        #expect(rt.playgroundLive?.findStory("Still") == 2)
        letter(rt, &t, "k")
        #expect(selectedIdx(rt) == 4)

        let countUp = unitBasePlayground().triggerPlay("Still", key: "r", label: "Count up") { s, play in
            s.count = 1
            play.after(0.5) { s, _ in s.count = 2 }
        }
        var (rt2, t2) = unitRuntimeWith(countUp, open: .some("Still"), windowed: false)
        rt2.frame(at: stepClock(&t2))
        #expect(showsText(rt2, "count") == "count 1")
        for _ in 0..<36 { rt2.frame(at: stepClock(&t2)) }
        #expect(showsText(rt2, "count") == "count 2")
        letter(rt2, &t2, "j")
        letter(rt2, &t2, "k")
        rt2.frame(at: stepClock(&t2))
        #expect(showsText(rt2, "count") == "count 1")

        var (rt3, t3) = unitRuntime(open: .some("Fade"))
        rt3.frame(at: stepClock(&t3))
        #expect(showsText(rt3, "fade") == "[\"start\"]")
        for _ in 0..<60 { rt3.frame(at: stepClock(&t3)) }
        #expect(showsText(rt3, "fade") == "[\"start\", \"half\", \"end\"]")
        letter(rt3, &t3, "j")
        letter(rt3, &t3, "k")
        for _ in 0..<60 { rt3.frame(at: stepClock(&t3)) }
        #expect(showsText(rt3, "fade") == "[\"start\", \"half\", \"end\"]")
        letter(rt3, &t3, "r")
        rt3.frame(at: stepClock(&t3))
        #expect(showsText(rt3, "fade") == "[\"start\"]")
    }

    @Test("withSceneClock restores enclosing clock cleanly")
    func sceneClockScoping() {
        let outer = SceneClock(now: 4.0, dt: 0.1)
        let inner = SceneClock(now: 12.0, dt: 0.5)
        withSceneClock(outer) {
            #expect(sceneClock() == outer)
            withSceneClock(inner) {
                #expect(sceneClock() == inner)
            }
            #expect(sceneClock() == outer)
        }
        #expect(sceneClock() == SceneClock())
    }

    @Test("real state tests: fresh, fromReal, Story.isCompatible, keep, background waker, sideReal, and replay while closed")
    func realStateAndFromRealAndKeep() {
        let copyReal: (UnitReal) -> UnitReal = { real in UnitReal(count: real.count) }
        var (rt, t) = unitRuntimeWith(unitBasePlayground().fresh(copyReal), open: nil)
        rt.state.count = 7
        rt.update(at: t) { _, tx in tx.openPlaygroundAt("holding") }
        rt.frame(at: stepClock(&t))
        #expect(showsText(rt, "count") == "count 7")
        rt.update(at: t) { _, tx in tx.openPlaygroundAt("big") }
        rt.frame(at: stepClock(&t))
        #expect(showsText(rt, "count") == "count 100")
        rt.state.count = 9
        rt.update(at: t) { _, tx in tx.openPlaygroundAt("holding") }
        rt.frame(at: stepClock(&t))
        #expect(showsText(rt, "count") == "count 9")
        rt.state.count = 11
        letter(rt, &t, "r")
        #expect(showsText(rt, "count") == "count 11")
        #expect(rt.state.count == 11)

        let derived = Story<UnitLab>.fromReal("Lab/Derived", { (r: UnitReal) in UnitLab(ticks: r.count, presses: 0) }, unitLabView)
        #expect(derived.isCompatible(with: UnitReal.self))
        #expect(!Story<UnitLab>.fromReal("Lab/Other", { (l: UnitLab) in l }, unitLabView).isCompatible(with: UnitReal.self))
        var (rtD, tD) = unitRuntimeWith(unitBasePlayground().story(derived), open: nil)
        rtD.state.count = 3
        rtD.update(at: tD) { _, tx in tx.openPlaygroundAt("Derived") }
        rtD.frame(at: stepClock(&tD))
        #expect(showsText(rtD, "lab") == "ticks 3 presses 0")
        rtD.state.count = 4
        letter(rtD, &tD, "j")
        letter(rtD, &tD, "k")
        #expect(showsText(rtD, "lab") == "ticks 3 presses 0")
        letter(rtD, &tD, "r")
        #expect(showsText(rtD, "lab") == "ticks 4 presses 0")

        let keepPg = unitBasePlayground().fresh(copyReal).keep { stage, real in real.count = stage.count }
        var (rtK, tK) = unitRuntimeWith(keepPg, open: nil)
        rtK.state.count = 5
        rtK.update(at: tK) { _, tx in tx.openPlaygroundAt("Still") }
        rtK.frame(at: stepClock(&tK))
        tap(rtK, &tK, "inc")
        #expect(showsText(rtK, "count") == "count 6" && rtK.state.count == 5)
        escape(rtK, &tK)
        letter(rtK, &tK, "r")
        #expect(showsText(rtK, "count") == "count 6" && rtK.state.count == 6)
        tap(rtK, &tK, "inc")
        escape(rtK, &tK)
        letter(rtK, &tK, "j")
        #expect(rtK.state.count == 7)
        letter(rtK, &tK, "k")
        #expect(showsText(rtK, "count") == "count 7")
        tap(rtK, &tK, "inc")
        escape(rtK, &tK)
        escape(rtK, &tK)
        #expect(rtK.state.count == 8 && showsText(rtK, "count") == "count 8")

        // sideReal + keepPlayground keeps playground open
        let compare: (UnitReal, UnitReal, inout Cx<UnitReal>) -> El<UnitReal> = { stage, real, _ in
            col()
                .child(text("stage \(stage.count) real \(real.count)").key("compare"))
                .child(el().key("keep").size(40, 20).onClick { _, tx in tx.keepPlayground() })
        }
        let sideRealPg = unitBasePlayground()
            .fresh(copyReal)
            .keep { stage, real in real.count = stage.count }
            .sideReal("Still", view: compare)
        var (rtS, tS) = unitRuntimeWith(sideRealPg, open: nil)
        rtS.state.count = 3
        rtS.update(at: tS) { _, tx in tx.openPlaygroundAt("Still") }
        rtS.frame(at: stepClock(&tS))
        #expect(showsText(rtS, "compare") == "stage 3 real 3")
        tap(rtS, &tS, "inc")
        #expect(showsText(rtS, "compare") == "stage 4 real 3")
        let genBefore = rtS.playgroundLive!.generation
        tap(rtS, &tS, "keep")
        #expect(showsText(rtS, "compare") == "stage 4 real 4")
        #expect(rtS.state.count == 4 && rtS.playgroundLive?.generation == genBefore)

        // replay while closed makes no stage for next open to keep
        var (rtC, tC) = unitRuntimeWith(keepPg, open: .some("big"))
        rtC.update(at: tC) { _, tx in tx.closePlayground() }
        rtC.frame(at: stepClock(&tC))
        rtC.state.count = 5
        rtC.update(at: tC) { _, tx in tx.replayPlayground() }
        rtC.frame(at: stepClock(&tC))
        #expect(rtC.playgroundState(as: UnitReal.self) == nil)
        rtC.update(at: tC) { _, tx in tx.togglePlayground() }
        rtC.frame(at: stepClock(&tC))
        #expect(rtC.state.count == 5 && showsText(rtC, "count") == "count 100")
    }

    @Test("a fresh stage shares the real waker and background wake reaches its poll")
    func freshStageSharesRealWaker() {
        let capturedWaker = MutexBox<Waker?>(nil)
        let realInbox = MutexBox<[Int]>([])
        let stageInbox = MutexBox<[Int]>([])
        let app = App<UnitReal>(
            "waker",
            size: Vec2(800, 500),
            init: { UnitReal() },
            view: unitView
        )
        .scene("Still") { _, _ in }
        .setup { waker in
            capturedWaker.withLock { $0 = waker }
        }
        .poll { s, _, _ in
            let got = (s.inbox ?? realInbox).withLock { arr in
                let out = arr; arr.removeAll(); return out
            }
            s.count += got.reduce(0, +)
            return !got.isEmpty
        }
        .playground(
            unitBasePlayground().fresh { _ in
                UnitReal(inbox: stageInbox)
            }
        )
        let rt = app.headlessRuntime(size: Vec2(800, 500), env: Env(systemDark: false, scale: 1.0))
        let appWaker = capturedWaker.withLock { $0 }!
        _ = try? rt.openPlayground(at: "Still", variant: nil)
        rt.frame(at: 0.0)
        rt.frame(at: unitDT)
        let g = DispatchGroup()
        g.enter()
        DispatchQueue.global().async {
            stageInbox.withLock { $0.append(41) }
            appWaker.wake()
            g.leave()
        }
        g.wait()
        rt.frame(at: 2 * unitDT)
        #expect(showsText(rt, "count") == "count 41")
        #expect(rt.state.count == 0)
    }

    @Test("digits switch a story's variant, caps show order, and scene variants apply after scene fn")
    func variantsDigitsAndSceneVariants() {
        let story = Story(path: "Variants/Pressed", { UnitLab() }, unitLabView)
            .variant("Few") { p, _ in p.presses = 5 }
            .variant("Many") { p, _ in p.presses = 50 }
            .trigger("x", "Clear") { p, _ in p.presses = 0 }
        var (rt, t) = unitRuntimeWith(unitBasePlayground().story(story), open: .some("Pressed"))
        #expect(showsText(rt, "lab") == "ticks 0 presses 5")
        #expect(findInfo(rt, "playground-variant-0") != nil && findInfo(rt, "playground-variant-1") != nil)
        let all = rt.elements()
        let caps = all.filter { $0.parentIndex.map({ all[$0].key == "cap" }) ?? false }.compactMap(\.text)
        #expect(caps == ["1", "2", "R", "X"])
        letter(rt, &t, "2")
        #expect(showsText(rt, "lab") == "ticks 0 presses 5")
        press(rt, &t, .tab)
        letter(rt, &t, "2")
        #expect(showsText(rt, "lab") == "ticks 0 presses 50")
        tap(rt, &t, "bump")
        escape(rt, &t)
        letter(rt, &t, "r")
        #expect(showsText(rt, "lab") == "ticks 0 presses 50")
        press(rt, &t, .tab)
        letter(rt, &t, "3")
        #expect(showsText(rt, "lab") == "ticks 0 presses 50")
        letter(rt, &t, "x")
        rt.frame(at: stepClock(&t))
        #expect(showsText(rt, "lab") == "ticks 0 presses 0")
        tap(rt, &t, "playground-variant-0")
        #expect(showsText(rt, "lab") == "ticks 0 presses 5")
        letter(rt, &t, "2")
        escape(rt, &t)
        letter(rt, &t, "k")
        letter(rt, &t, "j")
        #expect(showsText(rt, "lab") == "ticks 0 presses 50")
        escape(rt, &t)
        rt.update(at: t) { _, tx in tx.openPlayground() }
        rt.frame(at: stepClock(&t))
        #expect(showsText(rt, "lab") == "ticks 0 presses 5")

        let scenesPg = unitBasePlayground()
            .variant("Still", name: "Ten") { s, _ in s.count = 10 }
            .variant("Still", name: "Twenty") { s, _ in s.count = 20 }
            .triggerPlay("Still", key: "d", label: "Double") { s, _ in s.count *= 2 }
        var (rtS, tS) = unitRuntimeWith(scenesPg, open: .some("Still"))
        #expect(showsText(rtS, "count") == "count 10")
        press(rtS, &tS, .tab)
        letter(rtS, &tS, "2")
        #expect(showsText(rtS, "count") == "count 20")
        letter(rtS, &tS, "d")
        rtS.frame(at: stepClock(&tS))
        #expect(showsText(rtS, "count") == "count 40")
        letter(rtS, &tS, "r")
        #expect(showsText(rtS, "count") == "count 20")
        escape(rtS, &tS)
        letter(rtS, &tS, "k")
        #expect(findInfo(rtS, "playground-variant-0") == nil)
        press(rtS, &tS, .tab)
        letter(rtS, &tS, "1")
        #expect(showsText(rtS, "count") == "count 0")
    }

    @Test("stage layouts size centred, scroll, and fill stories")
    func stageLayoutsCenterScrollFill() {
        let size = Vec2(1200, 700)
        let app = App<UnitReal>("stage", size: size, init: { UnitReal() }, view: unitView)
            .playground(
                PlaygroundHost<UnitReal>()
                    .enabled(true)
                    .story(Story(path: "Cards/Plain", { UnitLab() }, { _, _ in el().key("plain") }))
                    .story(
                        Story(path: "Cards/Tall", { UnitLab() }, { _, _ in
                            col().key("tall").wFull().children((0..<40).map { _ in el().h(40) })
                        }).stage(.scroll)
                    )
                    .story(Story(path: "Screens/Window", { UnitLab() }, { _, _ in el().key("screen") }).stage(.fill))
                    .sizes([("Small", Vec2(300, 200))])
            )

        func sizeAtSmall(_ story: String, _ key: String) -> (Float, Float) {
            let rt = app.headlessRuntime(size: size, env: Env(systemDark: false, scale: 1.0))
            try? rt.openPlayground(at: story, variant: nil)
            rt.playgroundLive?.enqueue(.size(1))
            rt.frame(at: unitDT)
            let r = rt.elements().first { $0.key == key }!.rect
            return (r[2], r[3])
        }

        let plainSize = sizeAtSmall("Cards/Plain", "plain")
        #expect(abs(plainSize.0 - 300) < 0.5 && abs(plainSize.1 - 200) < 0.5)
        let tallSize = sizeAtSmall("Cards/Tall", "tall")
        #expect(abs(tallSize.0 - (300.0 - 2.0 * PlaygroundConst.scrollMargin)) < 0.5 && abs(tallSize.1 - 1600) < 0.5)
        let screenSize = sizeAtSmall("Screens/Window", "screen")
        #expect(abs(screenSize.0 - (1200.0 - PlaygroundConst.sidebar - PlaygroundConst.side - 2.0)) < 0.5)
        #expect(abs(screenSize.1 - 700.0) < 0.5)
    }

    @Test("dragging both column edges resizes them live and double-click restores defaults")
    func draggingEdgesAndDoubleClickRestoreDefaults() {
        var saved: (Float, Float) = (0, 0)
        let pg = unitBasePlayground().widths(
            load: { (240.0, 310.0) },
            save: { a, b in saved = (a, b) }
        )
        let app = App<UnitReal>("playground", size: Vec2(1200, 700), init: { UnitReal() }, view: unitView)
            .scene("big") { s, _ in s.count = 100 }
            .playground(pg)
        let rt = app.headlessRuntime(size: Vec2(1200, 700), env: Env(systemDark: false, scale: 1.0))
        try? rt.openPlayground(at: "Fade", variant: nil)
        var t = 0.0
        rt.frame(at: stepClock(&t))

        #expect(abs((findInfo(rt, "playground-list")?.rect[2] ?? 0) - 240.0) < 0.5)
        #expect(abs((findInfo(rt, "playground-side")?.rect[2] ?? 0) - 310.0) < 0.5)

        let left = findInfo(rt, "playground-sidebar-edge")!.rect
        let (lx, ly) = (left[0] + left[2] * 0.5, left[1] + 200)
        rt.pointerDown(at: Vec2(lx, ly), button: .primary, mods: Mods(), at: t)
        rt.pointerMove(to: Vec2(lx + 60, ly), at: t)
        rt.frame(at: stepClock(&t))
        #expect(abs((findInfo(rt, "playground-list")?.rect[2] ?? 0) - 300.0) < 0.5)
        rt.pointerUp(at: Vec2(lx + 60, ly), button: .primary, mods: Mods(), at: t)
        rt.frame(at: stepClock(&t))
        #expect(abs(saved.0 - 300.0) < 0.5)

        let right = findInfo(rt, "playground-side-edge")!.rect
        let (rx, ry) = (right[0] + right[2] * 0.5, right[1] + 200)
        rt.pointerDown(at: Vec2(rx, ry), button: .primary, mods: Mods(), at: t)
        rt.pointerMove(to: Vec2(rx - 50, ry), at: t)
        rt.frame(at: stepClock(&t))
        #expect(abs((findInfo(rt, "playground-side")?.rect[2] ?? 0) - 360.0) < 0.5)
        rt.pointerUp(at: Vec2(rx - 50, ry), button: .primary, mods: Mods(), at: t)
        rt.frame(at: stepClock(&t))
        #expect(abs(saved.0 - 300.0) < 0.5 && abs(saved.1 - 360.0) < 0.5)

        let left2 = findInfo(rt, "playground-sidebar-edge")!.rect
        let (lx2, ly2) = (left2[0] + left2[2] * 0.5, left2[1] + 200)
        rt.pointerDown(at: Vec2(lx2, ly2), button: .primary, mods: Mods(), at: t)
        rt.pointerUp(at: Vec2(lx2, ly2), button: .primary, mods: Mods(), at: t)
        rt.pointerDown(at: Vec2(lx2, ly2), button: .primary, mods: Mods(), at: t)
        rt.pointerUp(at: Vec2(lx2, ly2), button: .primary, mods: Mods(), at: t)
        rt.frame(at: stepClock(&t))
        #expect(abs((findInfo(rt, "playground-list")?.rect[2] ?? 0) - PlaygroundConst.sidebar) < 0.5)
        #expect(abs(saved.0 - PlaygroundConst.sidebar) < 0.5 && abs(saved.1 - 360.0) < 0.5)

        let right2 = findInfo(rt, "playground-side-edge")!.rect
        let (rx2, ry2) = (right2[0] + right2[2] * 0.5, right2[1] + 200)
        rt.pointerDown(at: Vec2(rx2, ry2), button: .primary, mods: Mods(), at: t)
        rt.pointerUp(at: Vec2(rx2, ry2), button: .primary, mods: Mods(), at: t)
        rt.pointerDown(at: Vec2(rx2, ry2), button: .primary, mods: Mods(), at: t)
        rt.pointerUp(at: Vec2(rx2, ry2), button: .primary, mods: Mods(), at: t)
        rt.frame(at: stepClock(&t))
        #expect(abs((findInfo(rt, "playground-side")?.rect[2] ?? 0) - PlaygroundConst.side) < 0.5)
        #expect(abs(saved.0 - PlaygroundConst.sidebar) < 0.5 && abs(saved.1 - PlaygroundConst.side) < 0.5)
    }
}

// MARK: - Press (`press_tests.rs`) & Keyboard Region State Machine (`region_tests.rs`)

private struct PressListState {
    var selected: Int = 4
    var keys: [(Key, Mods)] = []
}

@Suite("Playground Press & Region Machine Parity Tests")
struct PlaygroundPressAndRegionParityTests {
    @Test("a step presses a key the stage hears as input, and pressed scroll is not input-less")
    func pressStepAndMotionGateInputAttribution() {
        let size = Vec2(1200, 700)
        func down(_ s: inout PressListState, _ tx: inout Tx) {
            s.selected += 1
            tx.scrollTo("list", offset: Vec2(0, Float(s.selected * 40 - 160)), animated: false)
        }
        func makeRt(_ scene: String) -> Runtime<PressListState> {
            let app = App<PressListState>(
                "press",
                size: size,
                init: { PressListState() },
                view: { s, _ in
                    let rows: [El<PressListState>] = (0..<30).map { i in
                        el().key("row\(i)").wFull().h(40).bg(i == s.selected ? Color.white : Color.black)
                    }
                    return col().wFull().hFull().child(
                        col().key("list").wFull().h(200).scroll(stickBottom: false).child(
                            col().key("rows").wFull().children(rows)
                        )
                    )
                }
            )
            .scene("Keys/Pressed") { _, _ in }
            .scene("Keys/Stepped") { _, _ in }
            .onKey { s, ev, tx in
                s.keys.append((ev.key, ev.mods))
                if ev.key != .arrowDown { return false }
                down(&s, &tx)
                return true
            }
            .playground(
                PlaygroundHost<PressListState>()
                    .enabled(true)
                    .triggerPlay("Keys/Pressed", key: "r", label: "Press Down") { _, play in
                        play.after(0.5) { _, play in play.press(.arrowDown) }
                    }
                    .triggerPlay("Keys/Pressed", key: "s", label: "Press Shift Down") { _, play in
                        play.press(KeyEvent(key: .arrowDown, mods: Mods(shift: true)))
                    }
                    .triggerPlay("Keys/Stepped", key: "r", label: "Step down") { _, play in
                        play.after(0.5) { s, play in down(&s, &play.tx) }
                    }
            )
            let rt = app.headlessRuntime(size: size, env: Env(systemDark: false, scale: 1.0))
            rt.frame(at: 0.0)
            try? rt.openPlayground(at: scene, variant: nil)
            return rt
        }

        let run = MotionGateRun(makeRt("Keys/Pressed"), hz: 120.0)
        let storyIdx = run.rt.playgroundLive!.selected
        _ = run.rt.keyDown(KeyEvent(key: .text("/"), mods: Mods()), at: 0.0)
        run.step()
        #expect(run.rt.elements().first(where: { $0.focused })?.key == PlaygroundConst.filterKey)
        while (run.rt.playgroundState(as: PressListState.self)?.keys ?? []).isEmpty {
            #expect(run.rec.frames < 120)
            run.step()
        }
        let st = run.rt.playgroundState(as: PressListState.self)!
        #expect(st.keys.count == 1 && st.keys[0].0 == .arrowDown && st.keys[0].1 == Mods())
        #expect(st.selected == 5)
        let frame = run.rec.frames - 1
        #expect(run.rec.inputs.last?.0 == frame)
        #expect(run.rt.elements().first(where: { $0.focused })?.key == PlaygroundConst.filterKey)
        #expect(run.rt.playgroundLive?.selected == storyIdx && run.rt.playgroundLive?.controls.filter.text == "")
        try? run.rt.playgroundTrigger("s")
        let st2 = run.rt.playgroundState(as: PressListState.self)!
        #expect(st2.keys.count >= 2 && st2.keys[1].0 == .arrowDown && st2.keys[1].1 == Mods(shift: true))

        func rowJumps(_ scene: String) -> [MotionGateFinding] {
            let r = MotionGateRun(makeRt(scene), hz: 120.0)
            r.idle(0.25)
            r.step()
            r.play(1.0)
            #expect(r.rt.playgroundState(as: PressListState.self)?.selected == 5)
            return r.finish().filter { ["jump", "offset-jump", "jerk"].contains($0.kind) && $0.element.contains("row") }
        }
        let stepped = rowJumps("Keys/Stepped")
        #expect(stepped.contains { $0.kind == "offset-jump" && ($0.element.contains("list/rows") || $0.element.contains("@list/@rows")) })
        let pressed = rowJumps("Keys/Pressed")
        #expect(pressed.isEmpty)
    }

    @Test("a pressed PageDown pages the stage, not the story list")
    func pressedPageDownPagesStageNotList() {
        struct Long {}
        let size = Vec2(1200, 700)
        let longView: (Long, inout Cx<Long>) -> El<Long> = { _, _ in
            let rows: [El<Long>] = (0..<40).map { el().key("line\($0)").wFull().h(40) }
            return col().wFull().hFull().child(
                col().key("page").wFull().h(300).scroll(stickBottom: false).child(
                    col().wFull().children(rows)
                )
            )
        }
        let story = Story(path: "Pages/Long", { Long() }, longView)
            .trigger("r", "Page down") { _, play in
                play.after(0.1) { _, play in play.press(.pageDown) }
            }
        var pg = PlaygroundHost<PressListState>().enabled(true)
        for i in 0..<60 {
            pg = pg.story(Story(path: "Filler/Story \(i)", { Long() }, longView))
        }
        pg = pg.story(story)
        let rt = App<PressListState>("press", size: size, init: { PressListState() }, view: { _, _ in el() })
            .playground(pg)
            .headlessRuntime(size: size, env: Env(systemDark: false, scale: 1.0))
        rt.frame(at: 0.0)
        try? rt.openPlayground(at: "Pages/Long", variant: nil)

        func scrolledY(_ key: String) -> Float {
            let all = rt.elements()
            let idx = all.firstIndex { $0.key == key }!
            return all.first { $0.parentIndex == idx }?.scrolled[1] ?? 0
        }
        let listStart = scrolledY("playground-list")
        var t = 0.0
        for _ in 0..<30 {
            t += unitDT
            rt.frame(at: t)
        }
        #expect(abs(scrolledY("page") - 270.0) < 0.5)
        #expect(abs(scrolledY("playground-list") - listStart) < 0.5)
    }

    @Test("PlaygroundKeyboard targeted state-machine cases match upstream region_tests")
    func keyboardTargetedCases() {
        var keys = PlaygroundKeyboard()
        #expect(keys.saw(nil))
        keys.step(.focus(focus: "side/row", region: nil))
        #expect(keys.saw("side/row"))
        #expect(!keys.saw(nil))

        keys = PlaygroundKeyboard()
        keys.step(.give(.stage, seen: nil))
        keys.step(.focus(focus: nil, region: nil))
        #expect(keys.region == .stage)
        keys.step(.focus(focus: "list/story", region: .list))
        #expect(keys.region == .list)

        keys = PlaygroundKeyboard()
        keys.step(.slot(true))
        keys.step(.give(.side, seen: "side/slot"))
        keys.step(.give(.stage, seen: "side/slot"))
        keys.step(.focus(focus: "side/slot", region: .side))
        #expect(keys.region == .stage && keys.slotFocused)

        keys = PlaygroundKeyboard()
        keys.step(.give(.stage, seen: nil))
        let slotOn = keys.step(.slot(true))
        #expect(slotOn)
        #expect(keys.region == .stage)
        let slotOff = keys.step(.slot(false))
        #expect(slotOff)
        #expect(!keys.slotFocused)

        keys = PlaygroundKeyboard()
        keys.step(.give(.list, seen: "list/story"))
        keys.step(.hold(.stage))
        keys.step(.resume(.list, back: nil))
        #expect(keys.region == .list)
        keys.step(.focus(focus: "side/variant", region: .side))
        #expect(keys.region == .side)

        keys = PlaygroundKeyboard()
        keys.step(.give(.stage, seen: "stage/old"))
        keys.step(.hold(.stage))
        keys.step(.resume(.stage, back: "stage/field"))
        #expect(keys.saw("stage/field"))
        keys.step(.focus(focus: "stage/field", region: .list))
        #expect(keys.region == .stage)

        keys = PlaygroundKeyboard()
        keys.step(.give(.side, seen: "side/slot"))
        let closedChanged = keys.step(.closed)
        #expect(closedChanged)
        #expect(keys.region == .list && keys.saw("side/slot"))
    }

    @Test("exhaustive keyboard event sequences up to depth 5 match reference Old cache model")
    func keyboardExhaustiveWalk() {
        struct OldModel {
            var region: PlaygroundRegion = .list
            var sideActive: Bool = false
            var regionSeen: String? = nil

            @discardableResult mutating func setRegion(_ r: PlaygroundRegion) -> Bool {
                let prev = region; region = r; return prev != r
            }
            @discardableResult mutating func seeFocus(_ f: String?) -> Bool {
                if regionSeen == f { return false }
                regionSeen = f
                return true
            }
            @discardableResult mutating func setSideActive(_ a: Bool) -> Bool {
                let prev = sideActive; sideActive = a; return prev != a
            }
            mutating func giveRegion(_ r: PlaygroundRegion, _ f: String?) {
                seeFocus(f); setRegion(r)
            }
            mutating func syncRegion(_ f: String?, hover: Bool, at: PlaygroundRegion?) {
                guard seeFocus(f), !hover, let r = at else { return }
                setRegion(r)
            }
            mutating func close() { region = .list }
        }
        struct NodeSpec: Equatable {
            let path: String; let column: PlaygroundRegion; let isSlot: Bool; let highlight: Bool
        }
        let listRow = NodeSpec(path: "list/row", column: .list, isSlot: false, highlight: true)
        let sideRow = NodeSpec(path: "side/row", column: .side, isSlot: false, highlight: true)
        let slotNode = NodeSpec(path: "side/slot", column: .side, isSlot: true, highlight: false)
        let fieldNode = NodeSpec(path: "stage/field", column: .stage, isSlot: false, highlight: false)

        enum Feed {
            case focus(NodeSpec?), hover(Bool), look, press(PlaygroundRegion), close, routeStart, routeEnd
        }
        let feeds: [Feed] = [
            .focus(nil), .focus(listRow), .focus(sideRow), .focus(slotNode), .focus(fieldNode),
            .hover(true), .hover(false), .look,
            .press(.list), .press(.stage), .press(.side),
            .close, .routeStart, .routeEnd,
        ]
        struct RouteState { let old: PlaygroundRegion; let new: PlaygroundRegion; let aside: (NodeSpec, Bool)? }
        struct SimState {
            var keys = PlaygroundKeyboard()
            var old = OldModel()
            var focus: NodeSpec? = nil
            var hovered = false
            var route: RouteState? = nil
            var oldFlagStale = false
            func onSlot() -> Bool { !hovered && (focus?.isSlot ?? false) }
            func allows(_ f: Feed) -> Bool {
                let routing = route != nil
                switch f {
                case .focus, .look, .press: return true
                case .hover(let lit): return !routing && hovered != lit && (focus?.highlight ?? false)
                case .close, .routeStart: return !routing
                case .routeEnd: return routing
                }
            }
            mutating func apply(_ f: Feed) -> Bool {
                switch f {
                case .focus(let next):
                    if focus?.path != next?.path { hovered = false }
                    focus = next
                    oldFlagStale = false
                    let s = onSlot()
                    old.setSideActive(s)
                    return keys.step(.slot(s))
                case .hover(let lit):
                    hovered = lit; return false
                case .look:
                    let at = hovered ? nil : focus
                    old.syncRegion(focus?.path, hover: hovered, at: focus?.column)
                    if keys.saw(focus?.path) { return false }
                    return keys.step(.focus(focus: focus?.path, region: at?.column))
                case .press(let r):
                    old.giveRegion(r, focus?.path)
                    return keys.step(.give(r, seen: focus?.path))
                case .close:
                    old.close()
                    return keys.step(.closed)
                case .routeStart:
                    let aside = focus.flatMap { $0.column != .stage ? ($0, hovered) : nil }
                    route = RouteState(old: old.region, new: keys.region, aside: aside)
                    if aside != nil { focus = nil; hovered = false }
                    old.setRegion(.stage)
                    return keys.step(.hold(.stage))
                case .routeEnd:
                    let r = route!; route = nil
                    let back = r.aside.flatMap { focus == nil ? $0 : nil }
                    old.setRegion(r.old)
                    if let (n, _) = back { old.seeFocus(n.path) }
                    var changed = keys.step(.resume(r.new, back: back?.0.path))
                    if let (n, h) = back {
                        focus = n; hovered = h
                        oldFlagStale = old.sideActive != onSlot()
                        #expect(!oldFlagStale || onSlot())
                        if keys.step(.slot(onSlot())) { changed = true }
                    }
                    return changed
                }
            }
        }
        var checked = 0
        func walk(_ sim: SimState, depth: Int) {
            for f in feeds {
                guard sim.allows(f) else { continue }
                var next = sim
                let before = (next.keys.region, next.keys.slotFocused)
                let changed = next.apply(f)
                #expect(changed == (before.0 != next.keys.region || before.1 != next.keys.slotFocused))
                #expect(next.keys.region == next.old.region)
                #expect(next.keys.slotFocused == (next.old.sideActive || next.oldFlagStale))
                #expect(next.keys.saw(next.old.regionSeen))
                checked += 1
                if depth > 1 { walk(next, depth: depth - 1) }
            }
        }
        walk(SimState(), depth: 5)
        #expect(checked > 50_000)
    }
}

// MARK: - CLI Parity (`tooling/playground_cli_tests.rs`)

@Suite("Playground CLI Parity Tests")
struct PlaygroundCLIUnitParityTests {
    private struct Pad {
        var x: Float = 0
        var size: Float = 0
        var green: Bool = false
    }

    private func makeCLIApp() -> App<Pad> {
        let padView: (Pad, inout Cx<Pad>) -> El<Pad> = { p, _ in
            let fill = p.green ? oklch(0.7, 0.2, 145) : oklch(0.6, 0.2, 30)
            return el().wFull().hFull().child(
                el().key("puck").absolute(x: p.x, y: 10).size(p.size, p.size).bg(fill)
            )
        }
        let pg = PlaygroundHost<Pad>()
            .enabled(true)
            .triggerPlay("Slide", key: "r", label: "Slide") { _, play in
                play.after(0.3) { p, _ in p.x = 60 }
            }
            .triggerPlay("Slide", key: "g", label: "Green") { p, _ in p.green = true }
            .variant("Slide", name: "Small") { p, _ in p.size = 20 }
            .variant("Slide", name: "Big") { p, _ in p.size = 40 }
        return App<Pad>("pad", size: Vec2(960, 240), init: { Pad() }, view: padView)
            .scene("Motion/Slide") { p, _ in p.size = 20 }
            .playground(pg)
    }

    private func pngDimensions(at url: URL) throws -> (UInt32, UInt32) {
        let data = try Data(contentsOf: url)
        #expect(data.count >= 24)
        let w = UInt32(data[16]) << 24 | UInt32(data[17]) << 16 | UInt32(data[18]) << 8 | UInt32(data[19])
        let h = UInt32(data[20]) << 24 | UInt32(data[21]) << 16 | UInt32(data[22]) << 8 | UInt32(data[23])
        return (w, h)
    }

    @Test("headless --playground script renders deterministically and advances logical clock")
    func headlessPlaygroundScriptDeterministic() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rune-pg-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let scriptURL = dir.appendingPathComponent("script.json")
        try #"[{"t": 0.5, "type": "type", "text": "g"}, {"t": 1.2, "type": "mark", "name": "end"}]"#
            .data(using: .utf8)!
            .write(to: scriptURL)

        func runCase(_ name: String, extra: [String]) throws -> (Data, [String]) {
            let out = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let snap = out.appendingPathComponent("snap.png")
            var argv = [
                "--force-cpu", "--playground", "Motion/Slide", "--scale", "2", "--fps", "30",
                "--snap", snap.path,
            ]
            argv.append(contentsOf: extra.map { $0.replacingOccurrences(of: "{out}", with: out.path) })
            _ = try HeadlessRunner.run(makeCLIApp(), args: ToolingArgs.parse(argv))
            let snapBytes = try Data(contentsOf: snap)
            let framesDir = out.appendingPathComponent("frames")
            let frameNames = (try? FileManager.default.contentsOfDirectory(atPath: framesDir.path))?.sorted() ?? []
            return (snapBytes, frameNames)
        }

        let extra = ["--script", scriptURL.path, "--at", "1.0", "--out", "{out}/frames", "--every", "6"]
        let (firstSnap, firstFrames) = try runCase("first", extra: extra)
        let (secondSnap, secondFrames) = try runCase("second", extra: extra)
        #expect(firstSnap == secondSnap)
        #expect(firstFrames == secondFrames && !firstFrames.isEmpty)

        let (stillSnap, _) = try runCase("still", extra: ["--at", "1.0"])
        let (startSnap, _) = try runCase("start", extra: ["--at", "0"])
        #expect(firstSnap != stillSnap, "script trigger key g changed the scene")
        #expect(stillSnap != startSnap, "choosing scene played r trigger")
    }

    @Test("headless --playground --variant, --crop, and --whole-window produce expected PNG sizes")
    func headlessVariantCropAndWholeWindow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rune-pg-crop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let parsed = ToolingArgs.parse(["--playground", "--snap", "s.png", "--crop", "1,2,3,4", "--crop", "puck", "--variant", "Big"])
        #expect(parsed.cropRects == [[1, 2, 3, 4]] && parsed.cropKey == "puck" && parsed.playgroundVariant == "Big")

        func snapSize(_ name: String, extra: [String]) throws -> (UInt32, UInt32) {
            let snap = dir.appendingPathComponent("\(name).png")
            var argv = ["--force-cpu", "--playground", "Motion/Slide", "--scale", "2", "--fps", "30", "--snap", snap.path]
            argv.append(contentsOf: extra)
            _ = try HeadlessRunner.run(makeCLIApp(), args: ToolingArgs.parse(argv))
            return try pngDimensions(at: snap)
        }

        #expect(try snapSize("small", extra: ["--variant", "1", "--crop", "puck"]) == (40, 40))
        #expect(try snapSize("big", extra: ["--variant", "Big", "--crop", "puck"]) == (80, 80))
        #expect(try snapSize("stage", extra: ["--at", "0"]) == (988, 480))
        #expect(try snapSize("whole", extra: ["--at", "0", "--whole-window"]) == (1920, 480))
        #expect(try snapSize("group", extra: ["--at", "0", "--whole-window", "--crop", "playground-group-0"]) == (368, 48))
        #expect(try snapSize("side", extra: ["--at", "0", "--whole-window", "--crop", "playground-side"]) == (528, 480))
    }

    @Test("El.liftHandlers preserves scroll/growth/virtual cold fields and handlers including virtualRows children")
    func elLiftHandlersPreservesColdFieldsAndHandlers() {
        struct Child: Equatable {
            var clicks = 0
            var inputKeys = 0
            var atBottomEvents: [Bool] = []
            var farEvents: [Bool] = []
            var visibleEvents: [Range<Int>] = []
        }
        struct Parent: Equatable {
            var child: Child? = Child()
            var isValid = true
        }

        final class Box {
            var child: Child? = Child()
            var isValid = true
        }
        let box = Box()
        var dummyParent = Parent()
        var offsetRecorded: ScrollPos? = nil

        let fade = ScrollFade.feather(14).endOnly()
        let growth = GrowthSpec(spring: MotionTokens.SNAP, edge: .feather)
        let src = (el() as El<Child>)
            .key("scroll-list")
            .scrollFade(fade)
            .scrollAnchor(true)
            .stickyTop(6)
            .growth(growth)
            .streaming(true)
            .arrivesWhole()
            .foldGlide(MotionTokens.SETTLE)
            .virtualRows(count: 2, estimatedRowHeight: 28, key: { _, i in "row-\(i)" }) { _, i in
                (el() as El<Child>).key("vrow-\(i)").onClick { s, _ in s.clicks += 10 }
            }
            .virtualRowsVersion(42)
            .focusSelected(true)
            .revealSelected(true)
            .onInputKey { s, _, _ in s.inputKeys += 1; return true }
            .onAtBottom { s, flag in s.atBottomEvents.append(flag) }
            .onFarFromBottomUnder(24, frame: "outer") { s, flag in s.farEvents.append(flag) }
            .onScrollOffset { pos in offsetRecorded = pos }
            .onVisibleRows { s, range in s.visibleEvents.append(range); return true }

        let lifted: El<Parent> = src.liftHandlers(
            isValid: { box.isValid },
            get: { box.child },
            set: { box.child = $0 }
        )

        #expect(lifted.scrollFadeStyle == fade.style)
        #expect(lifted.scrollEdgeFadeWidth == 14)
        #expect(lifted.scrollAnchorEnabled == true)
        #expect(lifted.stickyConfig != nil)
        #expect(lifted.growthSpec == growth)
        #expect(lifted.isStreaming == true)
        #expect(lifted.isArrivesWhole == true)
        #expect(lifted.foldGlideSpec?.spring == MotionTokens.SETTLE)
        #expect(lifted.virtualEstimate == 28)
        #expect(lifted.virtualRowsVersionHash == src.virtualRowsVersionHash)
        #expect(lifted.isFocusSelected == true)
        #expect(lifted.isRevealSelected == true)
        #expect(lifted.virtualRowsSource?.count == 2)
        #expect(lifted.virtualRowsSource?.key(dummyParent, 1) == "row-1")

        var tx = Tx()
        if let row = lifted.virtualRowsSource?.build(dummyParent, 0) {
            row.handlers.onClick?(&dummyParent, &tx)
        }
        #expect(lifted.handlers.onInputKey?(&dummyParent, KeyEvent(key: .enter), &tx) == true)
        lifted.handlers.onAtBottom?(&dummyParent, true)
        #expect(lifted.handlers.onFarFromBottom?.min == 24)
        #expect(lifted.handlers.onFarFromBottom?.frameKey == "outer")
        lifted.handlers.onFarFromBottom?.handler(&dummyParent, true)
        lifted.handlers.onScrollOffset?(ScrollPos(offset: Vec2(0, 12), max: Vec2(0, 100), viewport: Vec2(200, 100), drawn: Vec2(200, 200)))
        #expect(lifted.handlers.onVisibleRows?(&dummyParent, 0..<2) == true)

        #expect(box.child?.clicks == 10)
        #expect(box.child?.inputKeys == 1)
        #expect(box.child?.atBottomEvents == [true])
        #expect(box.child?.farEvents == [true])
        #expect(box.child?.visibleEvents == [0..<2])
        #expect(offsetRecorded?.offset.y == 12)
    }
}
