import Foundation
import Testing
@testable import Rune
@testable import RuneKit
@testable import RuneMotion
@testable import RuneRef
@testable import RuneRefHashes
@testable import RuneKitGlyphs
@testable import RuneKitScrollX
@testable import RuneKitTree
@testable import RuneScrollKeys
@testable import RuneTextGlide
@testable import RuneTextCoverage
@testable import RuneSlowClick
@testable import RuneKitShortcutRecorder
@testable import RuneSticky
@testable import RuneExpressivePress
@testable import RuneMotionCurves

@Suite("Phase 3 crate-level examples", .serialized)
@MainActor
struct Phase3CrateExamplesTests {
    @Test("rune-ref-hashes computes deterministic 16-seed BLAKE3 corpus matching upstream goldens")
    func refHashesCorpus() throws {
        let entries = try RuneRefHashesApp.computeHashes()
        #expect(entries.count == 16)
        #expect(entries.first?.seed == 0)
        #expect(entries.first?.hash == "36f6aefc4d7c36910ee798986eb39062edc40385728f9aefe9c11b665daa1478")
        #expect(entries.last?.seed == 15)
        #expect(entries.last?.hash == "e42a98b4aba1b188c6579c9f2b2b5fa1a292b166ecf27c0a9f62cd40f9eec26e")
        #expect(entries.allSatisfy { $0.hash.count == 64 })
        let second = try RuneRefHashesApp.computeHashes()
        #expect(entries.map(\.hash) == second.map(\.hash))
    }

    @Test("rune-kit-glyphs renders all 28 KitIcons light beside dark")
    func kitGlyphsRendersAll28() throws {
        #expect(RuneKitGlyphsApp.catalog.count == 28)
        let out = try HeadlessRunner.run(RuneKitGlyphsApp.makeApp(), args: ToolingArgs())
        let tree = String(decoding: out.treeJSON, as: UTF8.self)
        #expect(tree.contains("star-filled"))
        #expect(tree.contains("check-small"))
    }

    @Test("rune-kit-scroll-x renders horizontal filmstrip and wide markdown")
    func kitScrollXRendersFilmstripAndMarkdown() throws {
        let out = try HeadlessRunner.run(RuneKitScrollXApp.makeApp(), args: ToolingArgs())
        let tree = String(decoding: out.treeJSON, as: UTF8.self)
        #expect(tree.contains("\"tile0\""))
        #expect(tree.contains("\"tile11\""))
        #expect(tree.contains("Clip 12"))
    }

    @Test("rune-kit-tree supports standard and --big 50k mode")
    func kitTreeNormalAndBig() throws {
        let normal = try HeadlessRunner.run(
            RuneKitTreeApp.makeApp(arguments: []),
            args: ToolingArgs()
        )
        let normalTree = String(decoding: normal.treeJSON, as: UTF8.self)
        #expect(normalTree.contains("files-crates\\/rune-kit\\/src\\/tree.rs"))
        #expect(normalTree.contains("File · +1140 −0"))

        let normalState = RuneKitTreeApp.initialState(big: false)
        let folderTotals = RuneKitTreeApp.totals(for: "crates", state: normalState)
        #expect(folderTotals.isFolder)
        #expect(folderTotals.added > 2000)

        let big = RuneKitTreeApp.initialState(big: true)
        #expect(big.entries.count == 50_000)
    }

    @Test("rune-scroll-keys updates selection and scrolls viewport on Up/Down")
    func scrollKeysNavigation() throws {
        var board = RuneScrollKeysApp.Board()
        var tx = Tx()
        for _ in 0..<8 {
            #expect(RuneScrollKeysApp.onKey(&board, KeyEvent(key: .arrowDown), &tx))
        }
        #expect(board.selected == 12)
        #expect(board.top > 0)
        let out = try HeadlessRunner.run(RuneScrollKeysApp.makeApp(), args: ToolingArgs())
        let tree = String(decoding: out.treeJSON, as: UTF8.self)
        #expect(tree.contains("\"card-4\""))
    }

    @Test("rune-text-glide and rune-text-coverage render scenes headlessly")
    func textGlideAndCoverage() throws {
        let glide = try HeadlessRunner.run(RuneTextGlideApp.makeApp(), args: ToolingArgs())
        #expect(!glide.treeJSON.isEmpty)

        for scene in ["emoji", "math", "align"] {
            let cov = try HeadlessRunner.run(
                RuneTextCoverageApp.makeApp(),
                args: ToolingArgs.parse(["--scene", scene])
            )
            #expect(!cov.treeJSON.isEmpty)
        }
    }

    @Test("rune-slow-click and rune-sticky render and handle actions")
    func slowClickAndSticky() throws {
        let slow = try HeadlessRunner.run(RuneSlowClickApp.makeApp(), args: ToolingArgs())
        let slowTree = String(decoding: slow.treeJSON, as: UTF8.self)
        #expect(slowTree.contains("saved 0"))

        let rt = Runtime(
            state: StickyState(),
            viewport: Vec2(440, 380),
            pixelScale: 1.0,
            systemDark: true,
            view: RuneStickyApp.view
        )
        rt.frame(at: 0.0)
        let hdr = try #require(rt.element(byKey: "hdr-0")?.rect)
        let center = Vec2(hdr[0] + hdr[2] * 0.5, hdr[1] + hdr[3] * 0.5)
        rt.pointerMove(to: center, at: 0.05)
        rt.pointerDown(at: center, at: 0.05)
        rt.pointerUp(at: center, at: 0.06)
        rt.frame(at: 0.06)
        #expect(rt.state.collapsed[0] == true)
    }

    @Test("rune-kit-shortcut-recorder detects conflict on Ctrl+Shift+Space and records valid chord")
    func kitShortcutRecorderBehavior() throws {
        var s = ShortcutRecorderDemoState()
        s.recorder.begin()
        var tx = Tx()
        let conflictHandled = RuneKitShortcutRecorderApp.onKey(
            state: &s,
            event: KeyEvent(key: .space, mods: Mods(shift: true, ctrl: true)),
            tx: &tx
        )
        #expect(conflictHandled)
        #expect(s.recorder.error == .conflict)
        #expect(s.recorder.shortcut == nil)
        #expect(s.registered == nil)
        #expect(s.owner != nil)

        s.recorder.begin()
        let okHandled = RuneKitShortcutRecorderApp.onKey(
            state: &s,
            event: KeyEvent(key: .text("k"), mods: Mods(cmd: true)),
            tx: &tx
        )
        #expect(okHandled)
        let expected = ShortcutChord(key: "k", modifiers: [.command])
        #expect(s.recorder.shortcut == expected)
        #expect(s.registered == expected)
        #expect(RuneKitShortcutRecorderApp.onKey(state: &s, event: KeyEvent(key: .text("k"), mods: Mods(cmd: true)), tx: &tx))
        #expect(s.activations == 1)

        // Subsequent conflict refusal must preserve the existing recorded shortcut.
        s.recorder.begin()
        #expect(RuneKitShortcutRecorderApp.onKey(
            state: &s,
            event: KeyEvent(key: .space, mods: Mods(shift: true, ctrl: true)),
            tx: &tx
        ))
        #expect(s.recorder.error == .conflict)
        #expect(s.recorder.shortcut == expected)
        #expect(s.registered == expected)

        let out = try HeadlessRunner.run(RuneKitShortcutRecorderApp.makeApp(), args: ToolingArgs())
        #expect(String(decoding: out.treeJSON, as: UTF8.self).contains("Launcher shortcut"))
    }

    @Test("rune-expressive-press handles p/u/r keys and renders still scene")
    func expressivePressScenesAndKeys() throws {
        var s = ExpressivePressState()
        var tx = Tx()
        #expect(RuneExpressivePressApp.onKey(state: &s, event: KeyEvent(key: .text("p")), tx: &tx))
        #expect(s.pressed)
        #expect(RuneExpressivePressApp.onKey(state: &s, event: KeyEvent(key: .text("r")), tx: &tx))
        #expect(s.grown)
        #expect(RuneExpressivePressApp.onKey(state: &s, event: KeyEvent(key: .text("u")), tx: &tx))
        #expect(!s.pressed)

        let still = try HeadlessRunner.run(
            RuneExpressivePressApp.makeApp(),
            args: ToolingArgs.parse(["--scene", "still"])
        )
        let tree = String(decoding: still.treeJSON, as: UTF8.self)
        #expect(tree.contains("Rest"))
        #expect(tree.contains("Pressed"))
    }

    @Test("rune-motion-curves emits all 5 SVG plot sheets")
    func motionCurvesGeneratesSVGs() {
        let outputs = RuneMotionCurvesGenerator.generateAll()
        #expect(outputs.map(\.filename) == [
            "tokens.svg",
            "swiftui.svg",
            "curves.svg",
            "retarget.svg",
            "presence-and-paths.svg",
        ])
        for item in outputs {
            #expect(item.svg.hasPrefix("<svg "))
            #expect(item.svg.hasSuffix("</svg>"))
            #expect(item.svg.contains("<path "))
        }
    }
}
