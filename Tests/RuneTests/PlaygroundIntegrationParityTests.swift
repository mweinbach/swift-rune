import Foundation
import Testing
@testable import Rune

private let pgDT: Double = 1.0 / 60.0

private func pgElement<S>(_ rt: Runtime<S>, _ key: String) -> ElementInfo? {
    rt.elements().first { $0.key == key && !$0.exiting }
}

private func pgShown<S>(_ rt: Runtime<S>, _ key: String) -> Bool {
    pgElement(rt, key) != nil
}

private func pgFocused<S>(_ rt: Runtime<S>) -> String? {
    rt.elements().first { $0.focused }?.key
}

private func pgSays<S>(_ rt: Runtime<S>, _ key: String) -> String {
    (pgElement(rt, key)?.text ?? "").replacingOccurrences(of: "\u{a0}", with: " ")
}

private func pgTapAt<S>(_ rt: Runtime<S>, _ x: Float, _ y: Float, clock: inout Double) {
    clock += pgDT
    rt.pointerMove(to: Vec2(x, y), at: clock)
    rt.pointerDown(at: Vec2(x, y), at: clock)
    rt.pointerUp(at: Vec2(x, y), at: clock)
    clock += pgDT
    _ = rt.frame(at: clock)
}

private func pgTap<S>(_ rt: Runtime<S>, _ key: String, clock: inout Double) {
    guard let p = rt.find(key) else {
        Issue.record("missing element \(key)")
        return
    }
    pgTapAt(rt, p.x, p.y, clock: &clock)
}

private func pgPress<S>(_ rt: Runtime<S>, _ key: Key, mods: Mods = .none, clock: inout Double) {
    clock += pgDT
    _ = rt.keyDown(KeyEvent(key: key, mods: mods), at: clock)
    _ = rt.frame(at: clock)
}

private func pgTyped<S>(_ rt: Runtime<S>, _ s: String, clock: inout Double) {
    pgPress(rt, .text(s), clock: &clock)
}

private func pgReopen<S>(_ rt: Runtime<S>, clock: inout Double) {
    rt.update { _, tx in tx.closePlayground() }
    clock += pgDT
    _ = rt.frame(at: clock)
    rt.update { _, tx in tx.openPlayground() }
    clock += pgDT
    _ = rt.frame(at: clock)
}

private func pgLabel<S>(_ rt: Runtime<S>, _ key: String) -> (String, Float) {
    let all = rt.elements()
    guard let at = all.firstIndex(where: { $0.key == key && !$0.exiting }) else {
        Issue.record("no \(key)")
        return ("", 0)
    }
    func inside(_ e: ElementInfo) -> Bool {
        var cur = e.parentIndex
        while let p = cur {
            if p == at { return true }
            cur = all[p].parentIndex
        }
        return false
    }
    if let e = all.first(where: { $0.text != nil && inside($0) }) {
        return (e.text ?? "", e.rect[0])
    }
    Issue.record("no label inside \(key)")
    return ("", 0)
}

private func pgTitleParts<S>(_ rt: Runtime<S>) -> [String] {
    let all = rt.elements()
    guard let at = all.firstIndex(where: { $0.key == "playground-title" }) else { return [] }
    return all.filter { $0.parentIndex == at }.compactMap(\.text)
}

// MARK: - 1. playground_deep.rs (7 tests)

@Suite("Playground Deep Integration Parity Tests")
struct PlaygroundDeepIntegrationTests {
    private struct Real {}
    private struct Card {}

    private func makePlayground() -> PlaygroundHost<Real> {
        let cardView: (Card, inout Cx<Card>) -> El<Card> = { _, _ in text("card").key("card") }
        return PlaygroundHost<Real>()
            .story(Story(path: "Fixtures/Linux & Windows/General/Portal", { Card() }, cardView))
            .story(Story(path: "Settings panes/General/Microphone missing", { Card() }, cardView))
            .story(Story(path: "Settings panes/General/Portal", { Card() }, cardView))
            .story(Story(path: "Prototypes/HUD/Processing", { Card() }, cardView))
            .story(Story(path: "Prototypes/Onboarding/Option · Pill", { Card() }, cardView))
            .story(Story(path: "Toasts/Sync", { Card() }, cardView))
    }

    private func makeOrdered() -> PlaygroundHost<Real> {
        makePlayground().groupOrder(["Prototypes", "Settings panes", "Not a group", "Fixtures"])
    }

    private func makeRuntime(_ playground: PlaygroundHost<Real>) -> Runtime<Real> {
        App<Real>("deep", size: Vec2(900, 700), init: { Real() }, view: { _, _ in text("the app") })
            .scene("Launch") { _, _ in }
            .scene("Fixtures/Empty") { _, _ in }
            .playground(playground)
            .headlessRuntime(size: Vec2(900, 700), env: Env(systemDark: false, scale: 1.0))
    }

    private func openTitle(_ rt: Runtime<Real>) -> String {
        pgTitleParts(rt).joined(separator: " › ")
    }

    private func rows(_ rt: Runtime<Real>) -> [String] {
        let filtered: [(Float, String)] = rt.elements().compactMap { e in
            guard !e.exiting, let k = e.key else { return nil }
            guard k.hasPrefix("playground-item-") || k.hasPrefix("playground-group-") else { return nil }
            return (e.rect[1], k)
        }
        return filtered.sorted { $0.0 < $1.0 }.map { $0.1.replacingOccurrences(of: "playground-", with: "") }
    }

    @Test("a path nests as deep as it goes and every lookup finds it")
    func pathNestsAndEveryLookupFindsIt() throws {
        let rt = makeRuntime(makePlayground())
        try rt.openPlayground(at: "Fixtures/Linux & Windows/General/Portal")
        #expect(openTitle(rt) == "Fixtures › Linux & Windows › General › Portal")
        let deep = ["group-1", "item-1", "group-2-1", "group-2-2", "item-2"]
        let r = rows(rt)
        #expect(deep.allSatisfy { r.contains($0) }, "a header at each level: \(r)")
        #expect([pgLabel(rt, "playground-group-2-1").0, pgLabel(rt, "playground-group-2-2").0] == ["Linux & Windows", "General"])
        try rt.openPlayground(at: "prototypes-onboarding-option-pill")
        #expect(openTitle(rt) == "Prototypes › Onboarding › Option · Pill", "by slug")
        try rt.openPlayground(at: "Microphone missing")
        #expect(openTitle(rt) == "Settings panes › General › Microphone missing", "by name")
        try rt.openPlayground(at: "Launch")
        #expect(openTitle(rt) == "Scenes › Launch", "a one-level path as before")
        try rt.openPlayground(at: "toasts-sync")
        #expect(openTitle(rt) == "Toasts › Sync")
    }

    @Test("group_order lists the named groups first, scenes and stories alike")
    func groupOrderListsNamedFirst() {
        let rt = makeRuntime(makeOrdered())
        var t = 0.0
        rt.update { _, tx in tx.openPlayground() }
        _ = rt.frame(at: t)
        #expect(openTitle(rt) == "Prototypes › HUD › Processing", "the first story in the list opens first")
        let expectedOrder = [
            "group-5", "group-5-1", "item-5", "group-6-1", "item-6",
            "group-3", "group-3-1", "item-3", "item-4",
            "group-1", "item-1", "group-2-1", "group-2-2", "item-2",
            "group-0", "item-0", "group-7", "item-7",
        ]
        #expect(rows(rt) == expectedOrder, "named groups first, in their order; then the rest as they first appear")
        rt.update { _, tx in tx.openPlaygroundAt("Portal") }
        _ = rt.frame(at: t)
        #expect(openTitle(rt) == "Settings panes › General › Portal", "a name two stories have finds the first in the list")
        rt.update { _, tx in tx.openPlaygroundAt("Processing") }
        _ = rt.frame(at: t)
        pgTyped(rt, "j", clock: &t)
        #expect(openTitle(rt) == "Prototypes › Onboarding › Option · Pill")
        pgTyped(rt, "j", clock: &t)
        #expect(openTitle(rt) == "Settings panes › General › Microphone missing", "J goes down the list, past its headers")
        pgPress(rt, .arrowDown, clock: &t)
        #expect(openTitle(rt) == "Settings panes › General › Portal", "and so does ↓")
        pgTyped(rt, "/", clock: &t)
        pgTyped(rt, "general", clock: &t)
        pgPress(rt, .arrowDown, clock: &t)
        #expect(openTitle(rt) == "Settings panes › General › Microphone missing", "the filter's matches are in list order too")
    }

    @Test("without group_order, scenes come first as before")
    func withoutGroupOrderScenesFirst() {
        let rt = makeRuntime(makePlayground())
        rt.update { _, tx in tx.openPlayground() }
        _ = rt.frame(at: 0.0)
        #expect(openTitle(rt) == "Scenes › Launch")
        #expect(Array(rows(rt).prefix(4)) == ["group-0", "item-0", "group-1", "item-1"])
    }

    @Test("start_folded folds everything but the open story's groups")
    func startFoldedFoldsEverythingElse() {
        let rt = makeRuntime(makeOrdered().startFolded(true))
        var t = 0.0
        rt.update { _, tx in tx.openPlaygroundAt("prototypes-onboarding-option-pill") }
        _ = rt.frame(at: t)
        #expect(rows(rt) == ["group-5", "group-5-1", "group-6-1", "item-6", "group-3", "group-1", "group-0", "group-7"])
        pgTap(rt, "playground-group-3", clock: &t)
        #expect(pgShown(rt, "playground-group-3-1") && !pgShown(rt, "playground-item-3"), "a group unfolds one level, the ones inside it still folded")
        pgReopen(rt, clock: &t)
        #expect(pgShown(rt, "playground-group-3-1"), "and stays unfolded while the app runs")
        #expect(pgShown(rt, "playground-item-6"), "the open story's groups unfold as it opens")
    }

    @Test("start_folded saves the unfolded groups and loads them next run")
    func startFoldedSavesAndLoads() throws {
        var saved: [String] = []
        let rt = makeRuntime(makeOrdered().startFolded(true).folds(load: { [] }, save: { saved = $0 }))
        var t = 0.0
        try rt.openPlayground(at: "Processing")
        pgTap(rt, "playground-group-1", clock: &t)
        pgTap(rt, "playground-group-2-1", clock: &t)
        #expect(saved == ["Prototypes", "Prototypes/HUD", "Fixtures", "Fixtures/Linux & Windows"], "full paths of the groups left open")
        let names = saved
        let next = makeRuntime(makeOrdered().startFolded(true).folds(load: { names }, save: { _ in }))
        next.update { _, tx in tx.openPlaygroundAt("Toasts/Sync") }
        _ = next.frame(at: 0.0)
        #expect(pgShown(next, "playground-group-2-2") && !pgShown(next, "playground-item-2"), "next run, the same groups open")
        #expect(pgShown(next, "playground-item-5") && !pgShown(next, "playground-group-3-1"), "and the rest folded")
        #expect(pgShown(next, "playground-item-7"), "with the open story's")
    }

    @Test("folds save full paths and load old one-level names")
    func foldsSaveFullPathsAndLoadOldOneLevel() throws {
        var saved: [String] = []
        let load = { ["Toasts", "Fixtures/Linux & Windows/General", "Gone"] }
        let rt = makeRuntime(makeOrdered().folds(load: load, save: { saved = $0 }))
        var t = 0.0
        try rt.openPlayground(at: "Processing")
        #expect(!pgShown(rt, "playground-item-7") && !pgShown(rt, "playground-item-2") && pgShown(rt, "playground-group-2-2"), "an old name and a deep path both load")
        pgTap(rt, "playground-group-6-1", clock: &t)
        #expect(saved == ["Fixtures/Linux & Windows/General", "Toasts", "Prototypes/Onboarding"])
    }

    @Test("the filter edits like a field and down goes into its matches")
    func filterEditsAndDownEntersMatches() throws {
        let rt = makeRuntime(makeOrdered())
        var t = 0.0
        try rt.openPlayground(at: "Toasts/Sync")
        pgTap(rt, "playground-filter", clock: &t)
        #expect(pgFocused(rt) == "playground-filter", "a click focuses it")
        pgTyped(rt, "hud", clock: &t)
        pgPress(rt, .command("a"), mods: Mods(cmd: true), clock: &t)
        pgTyped(rt, "portal", clock: &t)
        #expect(rows(rt) == ["group-3", "group-3-1", "item-4", "group-1", "group-2-1", "group-2-2", "item-2"], "⌘A selects what's typed, which typing replaces")
        pgPress(rt, .arrowDown, clock: &t)
        #expect(openTitle(rt) == "Settings panes › General › Portal" && pgFocused(rt) == nil, "↓ goes to the first match, and the list has the keyboard")
        pgTyped(rt, "j", clock: &t)
        #expect(openTitle(rt) == "Fixtures › Linux & Windows › General › Portal")
        pgTyped(rt, "k", clock: &t)
        pgPress(rt, .arrowUp, clock: &t)
        #expect(pgFocused(rt) == "playground-filter", "↑ from the first match goes back up to the field")
        pgPress(rt, .escape, clock: &t)
        #expect(pgFocused(rt) == "playground-filter", "Esc empties it first")
        #expect(pgShown(rt, "playground-item-5"))
        pgPress(rt, .escape, clock: &t)
        #expect(pgFocused(rt) == nil, "then leaves")
        #expect(rt.playgroundState(as: Card.self) != nil, "with the playground still open")
    }
}

// MARK: - 2. playground_folds.rs (2 tests)

@Suite("Playground Folds Integration Parity Tests")
struct PlaygroundFoldsIntegrationTests {
    private struct Real {}
    private struct Card {}

    private func makePlayground() -> PlaygroundHost<Real> {
        let cardView: (Card, inout Cx<Card>) -> El<Card> = { _, _ in text("card").key("card") }
        return PlaygroundHost<Real>()
            .story(Story(path: "Cards/Plain", { Card() }, cardView))
            .story(Story(path: "Cards/Raised", { Card() }, cardView))
            .story(Story(path: "Lists/Short", { Card() }, cardView))
    }

    private func makeRuntime(_ playground: PlaygroundHost<Real>) -> Runtime<Real> {
        App<Real>("folds", size: Vec2(800, 500), init: { Real() }, view: { _, _ in text("the app") })
            .playground(playground)
            .headlessRuntime(size: Vec2(800, 500), env: Env(systemDark: false, scale: 1.0))
    }

    @Test("a folded group stays folded after the playground closes")
    func foldedGroupStaysFolded() throws {
        let rt = makeRuntime(makePlayground())
        var t = 0.0
        try rt.openPlayground(at: "Lists/Short")
        #expect(pgShown(rt, "playground-item-1"))
        pgTap(rt, "playground-group-0", clock: &t)
        #expect(!pgShown(rt, "playground-item-1"), "Cards folded")
        pgReopen(rt, clock: &t)
        #expect(!pgShown(rt, "playground-item-1"), "and still folded, reopened")
        #expect(pgShown(rt, "playground-item-2"), "Lists isn't")
    }

    @Test("folds loads once and saves each change")
    func foldsLoadsOnceAndSavesEachChange() throws {
        var saved: [[String]] = []
        var loads = 0
        let pg = makePlayground().folds(
            load: {
                loads += 1
                return ["Cards", "Gone"]
            },
            save: { groups in saved.append(groups) }
        )
        let rt = makeRuntime(pg)
        var t = 0.0
        #expect(loads == 0, "nothing loads until the playground opens")
        try rt.openPlayground(at: "Lists/Short")
        #expect(!pgShown(rt, "playground-item-0") && pgShown(rt, "playground-item-2"), "Cards loads folded")
        pgTap(rt, "playground-group-2", clock: &t)
        pgTap(rt, "playground-group-0", clock: &t)
        #expect(saved == [["Cards", "Lists"], ["Lists"]], "a group it doesn't have is dropped")
        pgReopen(rt, clock: &t)
        #expect(loads == 1, "loaded once")
        try rt.openPlayground(at: "Lists/Short")
        #expect(saved.last?.count == 0, "opening a story in a folded group unfolds it, and saves that")
    }
}

// MARK: - 3. playground_keys.rs (2 tests)

@Suite("Playground Keys Integration Parity Tests")
struct PlaygroundKeysIntegrationTests {
    private struct Real {
        var scene: String = ""
        var palette: Bool = false
        var typed: String = ""
    }

    private func makeRuntime() throws -> Runtime<Real> {
        let app = App<Real>("keys", size: Vec2(900, 600), init: { Real() }, view: { s, _ in
            text("\(s.scene) \(s.palette) \(s.typed)").key("real")
        })
        .scene("Launch") { s, _ in s.scene = "launch" }
        .scene("Palette/Search") { s, _ in s.scene = "search" }
        .onKey { s, ev, _ in
            switch ev.key {
            case .command("k") where ev.mods.cmd:
                s.palette = !s.palette
            case .escape where s.palette:
                s.palette = false
            case .text(let t):
                s.typed += t
            default:
                return false
            }
            return true
        }
        .playground(PlaygroundHost<Real>())
        let rt = app.headlessRuntime(size: Vec2(900, 600), env: Env(systemDark: false, scale: 1.0))
        try rt.openPlayground(at: "Launch")
        return rt
    }

    private func stageState(_ rt: Runtime<Real>) -> (String, Bool, String) {
        let s = rt.playgroundState(as: Real.self)!
        return (s.scene, s.palette, s.typed)
    }

    @Test("a story opened from the list hears the keys the list leaves")
    func storyHearsKeysListLeaves() throws {
        let rt = try makeRuntime()
        var t = 0.0
        pgPress(rt, .arrowDown, clock: &t)
        pgPress(rt, .arrowDown, clock: &t)
        #expect(stageState(rt).0 == "search", "↓ opens the next story, the keyboard still on the list")
        #expect(pgSays(rt, "playground-hint").hasPrefix("↑↓ stories"))
        pgPress(rt, .command("k"), mods: Mods(cmd: true), clock: &t)
        #expect(stageState(rt).1, "⌘K reaches the story's on_key")
        pgTyped(rt, "3", clock: &t)
        #expect(stageState(rt).2 == "3", "and so does a digit")
        #expect(!rt.state.palette && rt.state.typed.isEmpty, "the stage's state, not the app's")
        pgPress(rt, .escape, clock: &t)
        #expect(stageState(rt).1 == false, "Esc goes to the story first")
        pgTyped(rt, "k", clock: &t)
        let st1 = stageState(rt)
        #expect(st1.0 == "launch" && st1.1 == false && st1.2 == "", "K is the list's: it moves to the story above")
        pgPress(rt, .arrowDown, clock: &t)
        pgPress(rt, .arrowDown, clock: &t)
        pgPress(rt, .arrowUp, clock: &t)
        pgPress(rt, .arrowUp, clock: &t)
        let st2 = stageState(rt)
        #expect(st2.0 == "launch" && st2.1 == false && st2.2 == "", "so are the arrows, and none reach the story")
        pgPress(rt, .tab, clock: &t)
        pgPress(rt, .command("k"), mods: Mods(cmd: true), clock: &t)
        #expect(stageState(rt).1, "from the side column too")
        pgPress(rt, .escape, clock: &t)
        #expect(stageState(rt).1 && pgSays(rt, "playground-hint").hasPrefix("↑↓ stories"), "Esc there goes back to the list")
        pgPress(rt, .escape, clock: &t)
        #expect(!stageState(rt).1, "where Esc closes the story's palette")
        pgPress(rt, .escape, clock: &t)
        #expect(rt.playgroundState(as: Real.self) == nil, "then leaves")
    }

    @Test("typing in the filter filters")
    func typingInFilterFilters() throws {
        let rt = try makeRuntime()
        var t = 0.0
        pgTyped(rt, "/", clock: &t)
        pgTyped(rt, "sea", clock: &t)
        pgTyped(rt, "2", clock: &t)
        #expect(!pgShown(rt, "playground-item-0") && !pgShown(rt, "playground-item-1"), "nothing matches \"sea2\"")
        let st = stageState(rt)
        #expect(st.0 == "launch" && st.1 == false && st.2 == "", "the field keeps what's typed")
        pgPress(rt, .backspace, clock: &t)
        #expect(pgShown(rt, "playground-item-1") && !pgShown(rt, "playground-item-0"))
        pgPress(rt, .command("k"), mods: Mods(cmd: true), clock: &t)
        #expect(stageState(rt).1, "a chord the field doesn't use reaches the story")
        pgPress(rt, .enter, clock: &t)
        #expect(stageState(rt).0 == "search", "Return opens the first match")
    }
}

// MARK: - 4. playground_links.rs (6 tests)

@Suite("Playground Links Integration Parity Tests")
struct PlaygroundLinksIntegrationTests {
    private struct Real {}
    private struct Upload {
        var bytes: UInt32 = 0
    }
    private final class ViewCounter {
        var count = 0
    }

    private func makeRuntime(counter: ViewCounter = ViewCounter()) -> Runtime<Real> {
        let uploadView: (Upload, inout Cx<Upload>) -> El<Upload> = { u, _ in
            text("\(u.bytes) bytes").key("upload")
        }
        let pg = PlaygroundHost<Real>()
            .story(
                Story(path: "Timeline/Send", { Upload() }, uploadView)
                    .variant("Small") { u, _ in u.bytes = 10 }
                    .variant("Large") { u, _ in u.bytes = 1_000_000 }
            )
            .story(Story(path: "Lists/Many devices", { Upload() }, uploadView))
        return App<Real>("links", size: Vec2(800, 500), init: { Real() }, view: { _, _ in
            counter.count += 1
            return text("the app").key("app")
        })
        .playground(pg)
        .headlessRuntime(size: Vec2(800, 500), env: Env(systemDark: false, scale: 1.0))
    }

    @Test("a slug is the path lowercased with dashes")
    func slugPathLowercasedWithDashes() {
        #expect(PlaygroundSlug.slug(for: "Timeline/Send") == "timeline-send")
        #expect(PlaygroundSlug.slug(for: "Lists/Many devices") == "lists-many-devices")
        #expect(PlaygroundSlug.slug(for: "  Toasts / Sync -- toast!  ") == "toasts-sync-toast")
        #expect(PlaygroundSlug.slug(for: "Café/Crème brûlée") == "café-crème-brûlée")
        #expect(PlaygroundSlug.slug(for: "Motion/Fade 2") == "motion-fade-2")
    }

    @Test("every lookup takes a slug")
    func everyLookupTakesSlug() throws {
        let rt = makeRuntime()
        try rt.openPlayground(at: "lists-many-devices")
        #expect(rt.playgroundState(as: Upload.self)?.bytes == 0)
        try rt.openPlayground(at: "timeline-send", variant: "Large")
        #expect(rt.playgroundState(as: Upload.self)?.bytes == 1_000_000)
    }

    @Test("a link before the first frame opens straight onto the story")
    func linkBeforeFirstFrameOpensStory() {
        let counter = ViewCounter()
        let rt = makeRuntime(counter: counter)
        rt.update { _, tx in tx.openPlaygroundAt("timeline-send", variant: "Large") }
        _ = rt.frame(at: 0.0)
        #expect(rt.playgroundElement("upload")?.text == "1000000 bytes", "the first frame shows the story")
        #expect(counter.count == 0, "and the app's view never ran")
    }

    @Test("from a handler it moves an open playground to the story")
    func handlerMovesOpenPlayground() throws {
        let rt = makeRuntime()
        try rt.openPlayground(at: "Lists/Many devices")
        rt.update { _, tx in tx.openPlaygroundAt("Send", variant: "2") }
        _ = rt.frame(at: 0.0)
        #expect(rt.playgroundState(as: Upload.self)?.bytes == 1_000_000, "by name, on the variant by number")
    }

    @Test("an unknown story opens the list instead of stopping the app")
    func unknownStoryOpensList() {
        let rt = makeRuntime()
        rt.update { _, tx in tx.openPlaygroundAt("timeline-nope") }
        _ = rt.frame(at: 0.0)
        #expect(rt.find("playground-list") != nil, "the playground is open, on its list")
        #expect(rt.playgroundState(as: Upload.self)?.bytes == 10, "on the first story, as it would open without a name")
    }

    @Test("an unknown variant opens the story as it would without one")
    func unknownVariantOpensFirst() {
        let rt = makeRuntime()
        rt.update { _, tx in tx.openPlaygroundAt("Timeline/Send", variant: "Huge") }
        _ = rt.frame(at: 0.0)
        #expect(rt.playgroundState(as: Upload.self)?.bytes == 10, "its first variant")
    }
}

// MARK: - 5. playground_replay.rs (3 tests)

@Suite("Playground Replay Integration Parity Tests")
struct PlaygroundReplayIntegrationTests {
    private struct Real {}
    private struct Count {
        var n: UInt32 = 0
    }

    private func makeRuntime() -> Runtime<Real> {
        let story = Story(path: "Motion/Count", { Count() }, { c, _ in text("\(c.n)").key("count") })
            .trigger("r", "Replay") { c, _ in c.n += 1 }
            .trigger("s", "Step") { c, _ in c.n += 100 }
        return App<Real>("replay", size: Vec2(400, 300), init: { Real() }, view: { _, _ in text("app") })
            .playground(PlaygroundHost<Real>().story(story))
            .headlessRuntime(size: Vec2(400, 300), env: Env(systemDark: false, scale: 1.0))
    }

    private func handler(_ rt: Runtime<Real>, _ f: (inout Tx) -> Void) {
        rt.update { _, tx in f(&tx) }
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.0)
    }

    @Test("a handler triggers and replays the open story")
    func handlerTriggersAndReplays() throws {
        let rt = makeRuntime()
        try rt.openPlayground(at: "motion-count")
        #expect(rt.playgroundState(as: Count.self)?.n == 1, "opening runs 'r' once")
        handler(rt) { $0.playgroundTrigger("s") }
        #expect(rt.playgroundState(as: Count.self)?.n == 101)
        handler(rt) { $0.replayPlayground() }
        #expect(rt.playgroundState(as: Count.self)?.n == 1, "replay makes the stage again, then runs 'r'")
        handler(rt) { $0.playgroundTrigger("S") }
        handler(rt) { $0.playgroundTrigger("R") }
        #expect(rt.playgroundState(as: Count.self)?.n == 1, "'r' is replay")
        handler(rt) { $0.playgroundTrigger("x") }
        #expect(rt.playgroundState(as: Count.self)?.n == 1, "an unknown key does nothing")
    }

    @Test("a link opens then replays in one handler")
    func linkOpensThenReplays() {
        let rt = makeRuntime()
        handler(rt) { tx in
            tx.openPlaygroundAt("motion-count")
            tx.playgroundTrigger("s")
            tx.replayPlayground()
        }
        #expect(rt.playgroundState(as: Count.self)?.n == 1, "the replay applies to the story the link opened")
    }

    @Test("closed it does nothing")
    func closedDoesNothing() {
        let rt = makeRuntime()
        handler(rt) { tx in
            tx.replayPlayground()
            tx.playgroundTrigger("s")
        }
        #expect(rt.playgroundState(as: Count.self) == nil)
    }
}

// MARK: - 6. playground_side_keys.rs (7 tests: 5 active + 2 gated on @text El.link)

@Suite("Playground Side Keys Integration Parity Tests")
struct PlaygroundSideKeysIntegrationTests {
    private struct Real {
        var level: Int32 = 0
    }

    private struct Dial {
        var value: Int32 = 0
        var failed: Bool = false
        var opened: Bool = false
    }

    private func makeRuntime() -> Runtime<Real> {
        let dialView: (Dial, inout Cx<Dial>) -> El<Dial> = { d, _ in
            text("dial \(d.value)").key("dial")
        }
        let linkedView: (Dial, inout Cx<Dial>) -> El<Dial> = { _, _ in
            el().key("docs").w(200).h(20).focusable().onClick { d, _ in d.opened = true }
        }
        let dialKey: (inout Dial, KeyEvent, inout Tx) -> Bool = { d, ev, _ in
            switch ev.key {
            case .arrowUp: d.value += 1
            case .arrowDown: d.value -= 1
            default: return false
            }
            return true
        }
        let pg = PlaygroundHost<Real>()
            .story(
                Story(path: "Dials/Dial", { Dial() }, dialView)
                    .sideKeys(dialKey) { d, active, _ in
                        text("\(active ? "active" : "idle") \(d.value)").key("dial-side")
                    }
                    .trigger("f", "Fail") { d, _ in d.failed = true }
            )
            .story(
                Story(path: "Dials/Plain", { Dial() }, dialView)
                    .side { d, _ in text("plain \(d.value)").key("plain-side") }
            )
            .story(
                Story(path: "Dials/Linked", { Dial() }, linkedView)
                    .sideKeys(dialKey) { d, active, _ in
                        text("\(active ? "active" : "idle") \(d.value)").key("linked-side")
                    }
                    .trigger("e", "Press Esc") { _, play in play.press(.escape) }
            )
            .sideKeys(
                "Meter/High",
                onKey: { s, ev, _ in
                    guard ev.key == .arrowUp else { return false }
                    s.level += 5
                    return true
                },
                view: { s, active, _ in
                    text("\(active ? "active" : "idle") \(s.level)").key("meter-side")
                }
            )
        return App<Real>("dials", size: Vec2(800, 500), init: { Real() }, view: { s, _ in
            text("level \(s.level)").key("level")
        })
        .scene("Meter/High") { s, _ in s.level = 50 }
        .playground(pg)
        .headlessRuntime(size: Vec2(800, 500), env: Env(systemDark: false, scale: 1.0))
    }

    private func onSlot(_ rt: Runtime<Real>) -> Bool {
        pgFocused(rt)?.hasPrefix("playground-slot-") == true
    }

    @Test("the side view knows when the keyboard is on it")
    func sideViewKnowsKeyboardFocus() throws {
        let rt = makeRuntime()
        var t = 0.0
        try rt.openPlayground(at: "Dials/Dial")
        #expect(pgSays(rt, "dial-side") == "idle 0")
        pgPress(rt, .arrowRight, clock: &t)
        #expect(pgSays(rt, "dial-side") == "active 0", "→ puts the keyboard on it")
        pgPress(rt, .escape, clock: &t)
        #expect(pgSays(rt, "dial-side") == "idle 0", "Esc leaves")
        #expect(rt.playgroundState(as: Dial.self) != nil, "and the playground stays open")
        pgPress(rt, .tab, clock: &t)
        #expect(pgSays(rt, "dial-side") == "active 0", "so does Tab")
        pgPress(rt, .tab, clock: &t)
        #expect(pgSays(rt, "dial-side") == "idle 0", "and Tab leaves again")
    }

    @Test("its hook gets keys first and left no longer leaves")
    func hookGetsKeysFirstAndLeftStays() throws {
        let rt = makeRuntime()
        var t = 0.0
        try rt.openPlayground(at: "dials-dial")
        pgPress(rt, .arrowRight, clock: &t)
        pgPress(rt, .arrowUp, clock: &t)
        pgPress(rt, .arrowUp, clock: &t)
        pgPress(rt, .arrowDown, clock: &t)
        let d1 = rt.playgroundState(as: Dial.self)!
        #expect(d1.value == 1 && !d1.failed, "↑↓ are the hook's, not the side column's")
        pgPress(rt, .arrowLeft, clock: &t)
        #expect(pgSays(rt, "dial-side") == "active 1", "← stays")
        pgTyped(rt, "f", clock: &t)
        t += pgDT
        _ = rt.frame(at: t)
        let d2 = rt.playgroundState(as: Dial.self)!
        #expect(d2.value == 1 && d2.failed, "a key it leaves runs the trigger it's on")
    }

    @Test(
        "a stage link that keeps the slot's focus leaves it the keys and the mark",
        .disabled("Requires @text El.link(TextLink) / Runtime link click preserving focus (crates/rune/src/el/text.rs:397)")
    )
    func stageLinkKeepsSlotFocus() throws {
        let rt = makeRuntime()
        var t = 0.0
        try rt.openPlayground(at: "Dials/Linked")
        pgPress(rt, .arrowRight, clock: &t)
        pgTap(rt, "docs", clock: &t)
        #expect(rt.playgroundState(as: Dial.self)?.opened == true)
        #expect(onSlot(rt))
        #expect(pgSays(rt, "linked-side") == "active 0")
    }

    @Test("a step's key that blurs the slot it puts back keeps the mark")
    func stepKeyBlursSlotKeepsMark() throws {
        let rt = makeRuntime()
        var t = 0.0
        try rt.openPlayground(at: "Dials/Linked")
        pgPress(rt, .arrowRight, clock: &t)
        pgTyped(rt, "e", clock: &t)
        t += pgDT
        _ = rt.frame(at: t)
        t += pgDT
        _ = rt.frame(at: t)
        #expect(onSlot(rt), "focus came back to the slot")
        #expect(pgSays(rt, "linked-side") == "active 0", "and so did its mark")
    }

    @Test(
        "every input sequence routes as dev routes it",
        .disabled("Requires @text El.link(TextLink) / Runtime link click preserving focus (crates/rune/src/el/text.rs:397)")
    )
    func everyInputSequenceRoutesAsDev() throws {
        let rt = makeRuntime()
        try rt.openPlayground(at: "Dials/Linked")
        #expect(pgSays(rt, "linked-side") == "idle 0")
    }

    @Test("a side without keys keeps the old keys")
    func sideWithoutKeysKeepsOldKeys() throws {
        let rt = makeRuntime()
        var t = 0.0
        try rt.openPlayground(at: "Dials/Plain")
        pgPress(rt, .arrowRight, clock: &t)
        #expect(pgFocused(rt)?.hasPrefix("playground-trigger") == true, "→ goes to its first control")
        pgPress(rt, .arrowLeft, clock: &t)
        #expect(pgFocused(rt) == nil, "← leaves")
    }

    @Test("a scene takes keys on its stage state")
    func sceneTakesKeysOnStageState() throws {
        let rt = makeRuntime()
        var t = 0.0
        try rt.openPlayground(at: "meter-high")
        pgPress(rt, .arrowRight, clock: &t)
        pgPress(rt, .arrowUp, clock: &t)
        #expect(pgSays(rt, "meter-side") == "active 55")
        #expect(rt.state.level == 0, "the real state is untouched")
    }
}

// MARK: - 7. playground_stage.rs (6 tests)

@Suite("Playground Stage Integration Parity Tests")
struct PlaygroundStageIntegrationTests {
    private static let viewSize = Vec2(1200, 700)
    private static let stageW: Float = 1200.0 - 200.0 - 264.0 - 2.0

    private struct Pad {
        var rows: Int = 0
    }
    private struct Card {}

    private func makeRuntime() -> Runtime<Pad> {
        let cardView: (Card, inout Cx<Card>) -> El<Card> = { _, _ in text("card").key("card") }
        let tallView: (Card, inout Cx<Card>) -> El<Card> = { _, _ in
            col().key("tall").wFull().children((0..<40).map { _ in el().h(40) })
        }
        let screenView: (Card, inout Cx<Card>) -> El<Card> = { _, _ in el().key("screen") }
        let pg = PlaygroundHost<Pad>()
            .triggerPlay("Full", key: "d", label: "Double") { s, _ in s.rows *= 2 }
            .stage("Long/Scene", .scroll)
            .story(Story(path: "Cards/Plain", { Card() }, cardView))
            .story(Story(path: "Cards/Raised", { Card() }, cardView).trigger("p", "Pop") { _, _ in })
            .story(Story(path: "Cards/Tall", { Card() }, tallView).stage(.scroll))
            .story(Story(path: "Screens/Window", { Card() }, screenView).stage(.fill))
        return App<Pad>("stage", size: Self.viewSize, init: { Pad() }, view: { s, _ in
            col().key("pad").wFull().children((0..<s.rows).map { _ in el().h(40) })
        })
        .scene("Pad/Empty") { _, _ in }
        .scene("Pad/Full") { s, _ in s.rows = 3 }
        .scene("Long/Scene") { s, _ in s.rows = 40 }
        .playground(pg)
        .headlessRuntime(size: Self.viewSize, env: Env(systemDark: false, scale: 1.0))
    }

    private func rect(_ rt: Runtime<Pad>, _ key: String) -> [Float] {
        pgElement(rt, key)!.rect
    }

    private func stageRect(_ rt: Runtime<Pad>) -> [Float] {
        rt.elements().first { e in
            !e.exiting &&
                e.key?.hasPrefix("playground-stage-") == true &&
                Int(e.key!.dropFirst("playground-stage-".count)) != nil
        }!.rect
    }

    private func close(_ a: [Float], _ b: [Float]) -> Bool {
        a.count == 4 && b.count == 4 && zip(a, b).allSatisfy { abs($0 - $1) < 0.5 }
    }

    @Test("each header counts its stories")
    func eachHeaderCountsStories() throws {
        let rt = makeRuntime()
        try rt.openPlayground(at: "Cards/Plain")
        #expect(pgSays(rt, "playground-count-0") == "2", "Pad")
        #expect(pgSays(rt, "playground-count-2") == "1", "Long")
        #expect(pgSays(rt, "playground-count-3") == "3", "Cards")
        #expect(pgSays(rt, "playground-count-6") == "1", "Screens")
    }

    @Test("a folded group still counts its stories")
    func foldedGroupCountsStories() throws {
        let rt = makeRuntime()
        var t = 0.0
        try rt.openPlayground(at: "Pad/Empty")
        pgTap(rt, "playground-group-3", clock: &t)
        #expect(pgElement(rt, "playground-item-3") == nil, "Cards folded")
        #expect(pgElement(rt, "playground-count-3")?.text == "3")
    }

    @Test("only stories with triggers have a motion mark")
    func onlyStoriesWithTriggersHaveMotionMark() throws {
        let rt = makeRuntime()
        try rt.openPlayground(at: "Cards/Plain")
        let marked = (0..<7).filter { pgElement(rt, "playground-motion-\($0)") != nil }
        #expect(marked == [1, 4], "the scene with a trigger and the story with one")
    }

    @Test("a scroll stage starts its content at the top and scrolls")
    func scrollStageStartsAtTopAndScrolls() throws {
        let rt = makeRuntime()
        try rt.openPlayground(at: "Cards/Tall")
        let stage = stageRect(rt)
        #expect(close(stage, [201.0, 0.0, Self.stageW, Self.viewSize.y]), "the stage fills its room: \(stage)")
        let top = rect(rt, "tall")
        #expect(close(top, [stage[0] + 24.0, stage[1] + 24.0, stage[2] - 48.0, 1600.0]), "inside the margin, at its own height: \(top)")
        _ = rt.frame(at: pgDT)
        rt.wheel(WheelEvent(dy: -300.0), at: Vec2(stage[0] + stage[2] / 2.0, stage[1] + stage[3] / 2.0), now: pgDT)
        _ = rt.frame(at: pgDT)
        let scrolled = rect(rt, "tall")
        #expect(abs(scrolled[1] - (top[1] - 300.0)) < 0.5, "the stage scrolled: \(scrolled)")
    }

    @Test("a scene takes its stage from the playground")
    func sceneTakesStageFromPlayground() throws {
        let rt = makeRuntime()
        try rt.openPlayground(at: "Long/Scene")
        let stage = stageRect(rt)
        let top = rect(rt, "pad")
        #expect(abs(top[1] - (stage[1] + 24.0)) < 0.5 && abs(top[3] - 1600.0) < 0.5, "a scrolling page: \(top)")
        try rt.openPlayground(at: "Pad/Full")
        #expect(close(rect(rt, "pad"), stage), "the others stay centred, the size of the stage")
    }

    @Test("a fill stage gives the root the whole stage")
    func fillStageGivesRootWholeStage() throws {
        let rt = makeRuntime()
        try rt.openPlayground(at: "Screens/Window")
        let stage = stageRect(rt)
        #expect(close(stage, [201.0, 0.0, Self.stageW, Self.viewSize.y]), "the stage fills its room: \(stage)")
        #expect(close(rect(rt, "screen"), stage))
    }
}

// MARK: - 8. playground_table.rs (1 test)

@Suite("Playground Table Integration Parity Tests")
struct PlaygroundTableIntegrationTests {
    private struct Real {}
    private struct Counter {
        var n: UInt32
    }
    private struct Row {
        let path: String
        let start: UInt32
        let step: UInt32
        let label: String
    }

    @Test("fifty stories from a table, each with its own row")
    func fiftyStoriesFromTable() throws {
        let rows: [Row] = (0..<UInt32(50)).map { i in
            Row(path: "Group \(i / 10)/Story \(i)", start: i * 10, step: i + 1, label: "row \(i)")
        }
        var pg = PlaygroundHost<Real>()
        for row in rows {
            let story = Story(path: row.path, { Counter(n: row.start) }, { c, _ in
                text("\(row.label) \(c.n)").key("counter")
            })
            .trigger("a", "Add") { c, _ in c.n += row.step }
            .trigger("l", "Add later") { _, play in
                play.after(0.5) { c, _ in c.n += row.step }
            }
            .triggerTx("z", "Zero") { c, tx in
                c.n = 0
                tx.instant()
            }
            .variant("As listed") { _, _ in }
            .variant("Doubled") { c, _ in c.n = row.start * 2 }
            pg = pg.story(story)
        }
        let rt = App<Real>("table", size: Vec2(800, 500), init: { Real() }, view: { _, _ in text("the app") })
            .playground(pg)
            .headlessRuntime(size: Vec2(800, 500), env: Env(systemDark: false, scale: 1.0))

        #expect(PlaygroundSlug.slug(for: "Group 3/Story 37") == "group-3-story-37")
        try rt.openPlayground(at: "group-3-story-37")
        #expect((rt.playgroundElement("counter")?.text ?? "") == "row 37 370", "its init and view captured its row")
        try rt.playgroundTrigger("a")
        #expect(rt.playgroundState(as: Counter.self)?.n == 408, "and its trigger, the row's step")
        try rt.playgroundTrigger("l")
        var t = 0.0
        for _ in 0..<40 {
            t += pgDT
            _ = rt.frame(at: t)
        }
        #expect(rt.playgroundState(as: Counter.self)?.n == 446, "a step it queued captured the row too")
        try rt.playgroundTrigger("z")
        #expect(rt.playgroundState(as: Counter.self)?.n == 0, "a trigger that takes just the Tx")
        try rt.openPlayground(at: "group-0-story-4", variant: "Doubled")
        #expect((rt.playgroundElement("counter")?.text ?? "") == "row 4 80", "a variant that captured its row")
    }
}

// MARK: - 9. playground_testing.rs (11 tests)

@Suite("Playground Testing Integration Parity Tests")
struct PlaygroundTestingIntegrationTests {
    private struct Pad {
        var count: UInt32 = 0
    }
    private struct Upload {
        var bytes: UInt32 = 0
        var phase: String = ""
    }
    private struct Pulse {
        var beats: UInt32 = 0
        var settled: Bool = false
    }
    private struct Glow {
        var lit: Bool = false
    }

    private func uploadStory() -> Story<Upload> {
        Story(path: "Progress/Upload", { Upload() }, { u, _ in text("\(u.phase) \(u.bytes)").key("upload") })
            .trigger("r", "Run") { u, play in
                u.phase = "sending"
                play.after(0.5) { u, play in
                    u.phase = "sent"
                    play.after(0.25) { u, _ in u.phase = "done" }
                }
            }
            .trigger("f", "Fail") { u, _ in u.phase = "failed" }
            .variant("Small") { u, _ in u.bytes = 10 }
            .variant("Large") { u, _ in u.bytes = 1_000_000 }
    }

    private func makePlayground() -> PlaygroundHost<Pad> {
        PlaygroundHost<Pad>()
            .story(uploadStory())
            .story(Story<Upload>.fromReal("Progress/Mine", { (real: Pad) in Upload(bytes: real.count, phase: "mine") }) { u, _ in
                text("\(u.phase) \(u.bytes)").key("upload")
            })
            .triggerPlay("Full", key: "d", label: "Double") { s, _ in s.count *= 2 }
            .variant("Full", name: "Few") { s, _ in s.count = 3 }
            .variant("Full", name: "Many") { s, _ in s.count = 99 }
    }

    private func makeRuntime(_ playground: PlaygroundHost<Pad>) -> Runtime<Pad> {
        App<Pad>("pad", size: Vec2(800, 500), init: { Pad() }, view: { s, _ in
            col().wFull().hFull()
                .child(text("count \(s.count)").key("count"))
                .child(el().key("inc").size(40, 20).onClick { s, _ in s.count += 1 })
        })
        .scene("Pad/Empty") { _, _ in }
        .scene("Pad/Full") { s, _ in s.count = 10 }
        .playground(playground)
        .headlessRuntime(size: Vec2(800, 500), env: Env(systemDark: false, scale: 1.0))
    }

    private func advance(_ rt: Runtime<Pad>, secs: Double, clock: inout Double) {
        let steps = Int((secs / pgDT).rounded())
        for _ in 0..<steps {
            clock += pgDT
            _ = rt.frame(at: clock)
        }
    }

    private func phase(_ rt: Runtime<Pad>) -> String {
        rt.playgroundState(as: Upload.self)!.phase
    }

    @Test("a story opens by path and its r trigger runs at once")
    func storyOpensAndRunsR() throws {
        let rt = makeRuntime(makePlayground())
        #expect(rt.playgroundState(as: Upload.self) == nil, "closed until opened")
        try rt.openPlayground(at: "Progress/Upload")
        #expect(phase(rt) == "sending")
        #expect(rt.playgroundElement("upload")?.text == "sending 10", "on its first variant")
        #expect(rt.playgroundState(as: Pad.self) == nil, "the stage's type is the story's own")
    }

    @Test("play_after steps run on the logical clock")
    func playAfterStepsRunOnLogicalClock() throws {
        let rt = makeRuntime(makePlayground())
        var t = 0.0
        try rt.openPlayground(at: "Upload")
        advance(rt, secs: 0.4, clock: &t)
        #expect(phase(rt) == "sending")
        advance(rt, secs: 0.2, clock: &t)
        #expect(phase(rt) == "sent", "half a second after the trigger")
        advance(rt, secs: 0.1, clock: &t)
        #expect(phase(rt) == "sent")
        advance(rt, secs: 0.1, clock: &t)
        #expect(phase(rt) == "done", "a quarter second after the step that queued it")
    }

    @Test("a trigger runs by its key and r replays")
    func triggerRunsAndRReplays() throws {
        let rt = makeRuntime(makePlayground())
        var t = 0.0
        try rt.openPlayground(at: "Progress/Upload")
        advance(rt, secs: 1.0, clock: &t)
        #expect(phase(rt) == "done")
        try rt.playgroundTrigger("f")
        #expect(phase(rt) == "failed")
        try rt.playgroundTrigger("r")
        #expect(phase(rt) == "sending", "the stage made again, its 'r' run")
        advance(rt, secs: 0.6, clock: &t)
        #expect(phase(rt) == "sent", "and its steps queued again")
    }

    @Test("a scene trigger acts on the stage and never the real state")
    func sceneTriggerActsOnStageOnly() throws {
        let rt = makeRuntime(makePlayground())
        rt.state.count = 4
        try rt.openPlayground(at: "Pad/Full")
        try rt.playgroundTrigger("d")
        #expect(rt.playgroundState(as: Pad.self)?.count == 6, "on its first variant, Few")
        #expect(rt.playgroundElement("count")?.text == "count 6")
        #expect(rt.state.count == 4, "the real state is untouched")
    }

    @Test("a variant opens with its own setup")
    func variantOpensWithOwnSetup() throws {
        let rt = makeRuntime(makePlayground())
        try rt.openPlayground(at: "Progress/Upload", variant: "Large")
        #expect(rt.playgroundState(as: Upload.self)?.bytes == 1_000_000)
        try rt.openPlayground(at: "Progress/Upload", variant: "1")
        #expect(rt.playgroundState(as: Upload.self)?.bytes == 10, "by number, and made again")
        try rt.openPlayground(at: "Full", variant: "many")
        #expect(rt.playgroundState(as: Pad.self)?.count == 99, "the scene fn, then the variant's")
    }

    @Test("a story from_real reads the real state and leaves it")
    func storyFromRealReadsAndLeavesReal() throws {
        let rt = makeRuntime(makePlayground())
        rt.state.count = 7
        try rt.openPlayground(at: "Progress/Mine")
        #expect(rt.playgroundState(as: Upload.self)?.bytes == 7)
        #expect(rt.state.count == 7)
    }

    @Test("only keep from a side_real control writes the real state")
    func onlyKeepFromSideRealWritesReal() throws {
        let pg = makePlayground()
            .keep { stage, real in real.count = stage.count }
            .sideReal("Full") { stage, real, _ in
                col()
                    .child(text("stage \(stage.count) real \(real.count)").key("compare"))
                    .child(el().key("keep").size(40, 20).onClick { _, tx in tx.keepPlayground() })
            }
        let rt = makeRuntime(pg)
        var t = 0.0
        try rt.openPlayground(at: "Full")
        try rt.playgroundTrigger("d")
        t += pgDT
        _ = rt.frame(at: t)
        #expect(rt.state.count == 0, "the trigger changed the stage only")
        #expect(rt.playgroundElement("compare") == nil, "the side column isn't the stage")
        let p = rt.find("keep")!
        t += pgDT
        rt.pointerDown(at: p, at: t)
        rt.pointerUp(at: p, at: t)
        t += pgDT
        _ = rt.frame(at: t)
        #expect(rt.state.count == 6, "kept")
        let compare = rt.elements().first { $0.key == "compare" }?.text
        #expect(compare == "stage 6 real 6")
    }

    @Test("a trigger that clears stops the loop and runs only its own steps")
    func triggerClearStopsLoop() throws {
        func beat(_ p: inout Pulse, _ play: inout Play<Pulse>) {
            p.beats += 1
            play.after(0.25, beat)
        }
        let pulse = Story(path: "Motion/Pulse", { Pulse() }, { p, _ in text("beats \(p.beats)").key("pulse") })
            .trigger("r", "Pulse", beat)
            .trigger("s", "Settle") { _, play in
                play.clear()
                play.after(0.2) { p, _ in p.settled = true }
            }
        let rt = makeRuntime(makePlayground().story(pulse))
        var t = 0.0
        try rt.openPlayground(at: "Pulse")
        advance(rt, secs: 1.1, clock: &t)
        func beats() -> (UInt32, Bool)? {
            rt.playgroundState(as: Pulse.self).map { ($0.beats, $0.settled) }
        }
        #expect(beats().map { $0.0 == 5 && !$0.1 } == true, "a beat every quarter second from the open")
        try rt.playgroundTrigger("s")
        #expect(beats().map { $0.0 == 5 && !$0.1 } == true, "clearing leaves the state alone")
        advance(rt, secs: 0.1, clock: &t)
        #expect(beats().map { $0.0 == 5 && !$0.1 } == true, "the loop's next beat is gone")
        advance(rt, secs: 0.15, clock: &t)
        #expect(beats().map { $0.0 == 5 && $0.1 } == true, "the step queued after the clear ran")
        advance(rt, secs: 1.0, clock: &t)
        #expect(beats().map { $0.0 == 5 && $0.1 } == true)
        #expect(rt.playgroundElement("pulse")?.text == "beats 5")
    }

    @Test("replays land their steps on the same frame every time")
    func replaysLandSameFrameEveryTime() throws {
        let glow = Story(path: "Motion/Glow", { Glow() }, { g, _ in text(g.lit ? "lit" : "dark").key("glow") })
            .trigger("r", "Glow") { g, play in
                g.lit = false
                play.after(0.4) { g, _ in g.lit = true }
            }
        let rt = makeRuntime(makePlayground().story(glow))
        try rt.openPlayground(at: "Motion/Glow")
        let dt = 1.0 / 120.0
        var t = 0.0
        var frames: [Int?] = []
        for _ in 0..<3 {
            try rt.playgroundTrigger("r")
            var litOn: Int? = nil
            for step in 1...120 {
                t += dt
                _ = rt.frame(at: t)
                if litOn == nil, rt.playgroundState(as: Glow.self)?.lit == true {
                    litOn = step
                    break
                }
            }
            frames.append(litOn)
            for _ in 0..<(120 - (litOn ?? 120)) {
                t += dt
                _ = rt.frame(at: t)
            }
        }
        #expect(frames == [48, 48, 48], "0.4 s at 120 Hz is frame 48 on every replay")
    }

    @Test("an unknown story throws with the available story list")
    func unknownStoryThrowsWithList() {
        let rt = makeRuntime(makePlayground())
        do {
            try rt.openPlayground(at: "Nope")
            Issue.record("expected PlaygroundLookupError.unknownStory")
        } catch let PlaygroundLookupError.unknownStory(name, available) {
            #expect(name == "Nope")
            #expect(available.contains("Progress/Upload"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("an unknown trigger throws with the available trigger keys")
    func unknownTriggerThrowsWithKeys() throws {
        let rt = makeRuntime(makePlayground())
        try rt.openPlayground(at: "Progress/Upload")
        do {
            try rt.playgroundTrigger("z")
            Issue.record("expected PlaygroundLookupError.unknownVariant")
        } catch let PlaygroundLookupError.unknownVariant(name, story, available) {
            #expect(name == "z")
            #expect(story == "Progress/Upload")
            #expect(!available.isEmpty)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

// MARK: - 10. playground_tree.rs (8 tests)

@Suite("Playground Tree Integration Parity Tests")
struct PlaygroundTreeIntegrationTests {
    private static let listHint = "↑↓ stories · ←→ groups · / filter · Tab controls · Esc back"

    private struct Real {}
    private struct Card {
        var variant: UInt8 = 0
        var knob: String = ""
    }

    private func makePlayground() -> PlaygroundHost<Real> {
        let cardView: (Card, inout Cx<Card>) -> El<Card> = { c, _ in
            text("card \(c.variant)").key("card").onClick { _, _ in }
        }
        let knobKey: (inout Card, KeyEvent, inout Tx) -> Bool = { c, ev, _ in
            guard case .text(let s) = ev.key, !s.isEmpty, s.allSatisfy(\.isASCII), s.allSatisfy(\.isNumber) else {
                return false
            }
            c.knob += s
            return true
        }
        return PlaygroundHost<Real>()
            .story(
                Story(path: "Sidebar/Rows/Plain", { Card() }, cardView)
                    .variant("One") { c, _ in c.variant = 1 }
                    .variant("Two") { c, _ in c.variant = 2 }
            )
            .story(Story(path: "Sidebar/Rows/Pinned", { Card() }, cardView))
            .story(Story(path: "Sidebar/Filter buttons/Compact", { Card() }, cardView))
            .story(Story(path: "Sidebar/Filter buttons/Wide", { Card() }, cardView))
            .story(Story(path: "Sidebar/Header", { Card() }, cardView))
            .story(
                Story(path: "Dock/Icons", { Card() }, cardView)
                    .sideKeys(knobKey) { c, active, _ in
                        text("\(active ? "on" : "off") \(c.knob)").key("knob")
                    }
            )
    }

    private func makeRuntime(_ playground: PlaygroundHost<Real>, open: String) throws -> Runtime<Real> {
        let rt = App<Real>("tree", size: Vec2(900, 600), init: { Real() }, view: { _, _ in text("the app") })
            .playground(playground)
            .headlessRuntime(size: Vec2(900, 600), env: Env(systemDark: false, scale: 1.0))
        try rt.openPlayground(at: open)
        return rt
    }

    private func title(_ rt: Runtime<Real>) -> String {
        let parts = pgTitleParts(rt)
        return parts.count > 1 ? parts[1] : ""
    }

    private func cardState(_ rt: Runtime<Real>) -> (UInt8, String) {
        let c = rt.playgroundState(as: Card.self)!
        return (c.variant, c.knob)
    }

    @Test("a path nests groups one level per slash")
    func pathNestsGroupsOneLevelPerSlash() throws {
        let rt = try makeRuntime(makePlayground(), open: "Sidebar/Filter buttons/Compact")
        let order = [
            "playground-group-0", "playground-group-0-1", "playground-item-0", "playground-item-1",
            "playground-group-2-1", "playground-item-2", "playground-item-3", "playground-item-4",
            "playground-group-5", "playground-item-5",
        ]
        let ys = order.map { pgElement(rt, $0)!.rect[1] }
        #expect(zip(ys, ys.dropFirst()).allSatisfy { $0 < $1 }, "rows in tree order: \(ys)")
        #expect(pgLabel(rt, "playground-group-2-1").0 == "Filter buttons", "a group inside another shows its own name")
        let sidebar = pgLabel(rt, "playground-group-0").1
        let rowsX = pgLabel(rt, "playground-group-0-1").1
        let compact = pgLabel(rt, "playground-item-2").1
        let header = pgLabel(rt, "playground-item-4").1
        #expect(header == sidebar, "a story lines up with its group's name")
        #expect((rowsX - sidebar) == 12.0 && (compact - header) == 12.0, "each level indents 12 pt")
        #expect([
            pgSays(rt, "playground-count-0"),
            pgSays(rt, "playground-count-0-1"),
            pgSays(rt, "playground-count-2-1"),
            pgSays(rt, "playground-count-5"),
        ] == ["5", "2", "2", "1"], "a header counts every story inside it")
        #expect(pgLabel(rt, "playground-title").0 == "Sidebar › Filter buttons")
        #expect(title(rt) == "Compact")
    }

    @Test("every level folds and a fold inside one outlasts its parents")
    func everyLevelFoldsAndOutlastsParents() throws {
        let rt = try makeRuntime(makePlayground(), open: "Dock/Icons")
        var t = 0.0
        pgTap(rt, "playground-group-2-1", clock: &t)
        #expect(!pgShown(rt, "playground-item-2") && !pgShown(rt, "playground-item-3"), "Filter buttons folds")
        #expect(pgShown(rt, "playground-item-0") && pgShown(rt, "playground-item-4"), "the rest of Sidebar doesn't")
        pgTap(rt, "playground-group-0", clock: &t)
        #expect(!pgShown(rt, "playground-group-0-1") && !pgShown(rt, "playground-group-2-1") && !pgShown(rt, "playground-item-4"), "Sidebar folds what's inside it")
        #expect(pgShown(rt, "playground-item-5"), "Dock stays")
        pgTap(rt, "playground-group-0", clock: &t)
        #expect(pgShown(rt, "playground-item-0") && pgShown(rt, "playground-group-2-1"))
        #expect(!pgShown(rt, "playground-item-2"), "Filter buttons is still folded")
    }

    @Test("folds keep groups at any level by their path")
    func foldsKeepGroupsByPath() throws {
        var saved: [[String]] = []
        let pg = makePlayground().folds(
            load: { ["Sidebar/Filter buttons", "Dock"] },
            save: { groups in saved.append(groups) }
        )
        let rt = try makeRuntime(pg, open: "Sidebar/Header")
        var t = 0.0
        #expect(!pgShown(rt, "playground-item-2") && pgShown(rt, "playground-group-2-1"), "a nested group loads folded")
        #expect(!pgShown(rt, "playground-item-5"), "and a top one, by name as before")
        pgTap(rt, "playground-group-0-1", clock: &t)
        #expect(saved.last == ["Sidebar/Filter buttons", "Dock", "Sidebar/Rows"])
        try rt.openPlayground(at: "Sidebar/Filter buttons/Wide")
        #expect(pgShown(rt, "playground-item-3"), "opening a story unfolds the groups around it")
        #expect(saved.last == ["Dock", "Sidebar/Rows"])
    }

    @Test("arrows walk into and out of nested groups")
    func arrowsWalkNestedGroups() throws {
        let rt = try makeRuntime(makePlayground(), open: "Sidebar/Filter buttons/Compact")
        var t = 0.0
        pgPress(rt, .arrowLeft, clock: &t)
        pgPress(rt, .arrowLeft, clock: &t)
        #expect(!pgShown(rt, "playground-item-2"), "← goes to the story's group, then folds it")
        pgPress(rt, .arrowLeft, clock: &t)
        pgPress(rt, .arrowLeft, clock: &t)
        #expect(!pgShown(rt, "playground-group-0-1"), "then up to the group around it, and folds that")
        pgPress(rt, .arrowLeft, clock: &t)
        #expect(!pgShown(rt, "playground-group-0-1"), "at the top, ← stays")
        pgPress(rt, .arrowRight, clock: &t)
        #expect(pgShown(rt, "playground-group-0-1") && !pgShown(rt, "playground-item-2"), "→ unfolds one level")
        pgPress(rt, .arrowRight, clock: &t)
        pgPress(rt, .arrowDown, clock: &t)
        #expect(title(rt) == "Plain", "→ steps into the group: Rows, then its first story")
        pgPress(rt, .arrowDown, clock: &t)
        pgPress(rt, .arrowDown, clock: &t)
        pgPress(rt, .arrowRight, clock: &t)
        #expect(pgShown(rt, "playground-item-2"), "→ on a folded header unfolds it")
        pgPress(rt, .arrowDown, clock: &t)
        #expect(title(rt) == "Compact")
        pgPress(rt, .arrowDown, clock: &t)
        pgPress(rt, .arrowDown, clock: &t)
        #expect(title(rt) == "Header", "down past a subgroup to the stories beside it")
    }

    @Test("the filter keeps matches and the groups above them")
    func filterKeepsMatchesAndParentGroups() throws {
        let rt = try makeRuntime(makePlayground(), open: "Sidebar/Rows/Plain")
        var t = 0.0
        pgTyped(rt, "/", clock: &t)
        #expect(pgFocused(rt) == "playground-filter", "/ focuses the filter")
        pgTyped(rt, "filter wi", clock: &t)
        #expect(pgShown(rt, "playground-group-0") && pgShown(rt, "playground-group-2-1") && pgShown(rt, "playground-item-3"))
        #expect(!pgShown(rt, "playground-item-0") && !pgShown(rt, "playground-item-2") && !pgShown(rt, "playground-group-5"), "the rest goes")
        #expect(pgSays(rt, "playground-count-0") == "1", "counts count matches")
        pgPress(rt, .enter, clock: &t)
        #expect(title(rt) == "Wide" && pgFocused(rt) == nil, "Return opens the first match and gives the list the keyboard")
        pgTyped(rt, "/", clock: &t)
        pgPress(rt, .escape, clock: &t)
        #expect(pgShown(rt, "playground-item-0"), "Esc empties it")
    }

    @Test("the keyboard moves from the list to the side column and back")
    func keyboardMovesListToSideAndBack() throws {
        let rt = try makeRuntime(makePlayground(), open: "Sidebar/Rows/Plain")
        var t = 0.0
        #expect(pgSays(rt, "playground-hint") == Self.listHint)
        pgTyped(rt, "2", clock: &t)
        #expect(cardState(rt).0 == 1, "from the list, a digit isn't a variant")
        pgPress(rt, .tab, clock: &t)
        #expect(pgSays(rt, "playground-hint") == "↑↓ controls · 1–2 variants · Esc stories")
        #expect(pgFocused(rt) == "playground-variant-0")
        pgTyped(rt, "2", clock: &t)
        #expect(cardState(rt).0 == 2, "in the side column it is")
        pgPress(rt, .escape, clock: &t)
        #expect(pgSays(rt, "playground-hint") == Self.listHint && pgFocused(rt) == nil, "Esc goes back to the list")
        pgPress(rt, .arrowDown, clock: &t)
        #expect(title(rt) == "Pinned", "whose arrows work again")
        pgPress(rt, .arrowRight, clock: &t)
        #expect(pgSays(rt, "playground-hint").hasPrefix("↑↓ controls"), "→ from a story goes over too")
    }

    @Test("side_keys hear only the side column")
    func sideKeysHearOnlySideColumn() throws {
        let rt = try makeRuntime(makePlayground(), open: "Dock/Icons")
        var t = 0.0
        pgTyped(rt, "3", clock: &t)
        #expect(cardState(rt).1 == "", "the list has the keyboard, so the knob hears nothing")
        pgPress(rt, .arrowRight, clock: &t)
        pgTyped(rt, "3", clock: &t)
        #expect(pgSays(rt, "knob") == "on 3")
        pgPress(rt, .escape, clock: &t)
        pgTyped(rt, "4", clock: &t)
        #expect(pgSays(rt, "knob") == "off 3")
    }

    @Test("a click gives its column the keyboard")
    func clickGivesColumnKeyboard() throws {
        let rt = try makeRuntime(makePlayground(), open: "Sidebar/Rows/Plain")
        var t = 0.0
        pgTap(rt, "card", clock: &t)
        #expect(pgSays(rt, "playground-hint") == "Keys go to the story · Esc stories")
        #expect(pgShown(rt, "playground-stage-ring"), "a ring shows the stage has it")
        pgPress(rt, .arrowDown, clock: &t)
        pgTyped(rt, "j", clock: &t)
        #expect(title(rt) == "Plain", "the list's keys aren't the stage's")
        let side = pgElement(rt, "playground-side")!.rect
        pgTapAt(rt, side[0] + side[2] * 0.5, side[1] + side[3] * 0.6, clock: &t)
        #expect(pgSays(rt, "playground-hint").hasPrefix("↑↓ controls"), "a click on the side column's background takes it there")
        #expect(!pgShown(rt, "playground-stage-ring"))
        pgTyped(rt, "2", clock: &t)
        #expect(cardState(rt).0 == 2)
        pgTap(rt, "playground-item-1", clock: &t)
        #expect(pgSays(rt, "playground-hint") == Self.listHint && title(rt) == "Pinned")
        pgPress(rt, .escape, clock: &t)
        #expect(rt.playgroundState(as: Card.self) == nil, "Esc from the list goes back to the app")
    }

    @Test("column resize edges show resizeColumn cursor on hover")
    func resizeEdgesUseResizeColumnCursor() throws {
        let rt = try makeRuntime(makePlayground(), open: "Sidebar/Rows/Plain")
        var t = 0.0
        for edgeKey in ["playground-sidebar-edge", "playground-side-edge"] {
            let rect = try #require(pgElement(rt, edgeKey)?.rect)
            t += 0.02
            rt.pointerMove(to: Vec2(rect[0] + rect[2] * 0.5, rect[1] + rect[3] * 0.5), at: t)
            _ = rt.frame(at: t)
            #expect(rt.currentCursor() == .resizeColumn, "Expected resizeColumn cursor over \(edgeKey)")
        }
    }
}
