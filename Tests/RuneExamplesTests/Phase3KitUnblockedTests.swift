import Foundation
import Testing
@testable import Rune
@testable import RuneKit
@testable import RuneOdometer
@testable import RuneKitTable
@testable import RuneKitTabStrip
@testable import RuneKitShell
@testable import RuneKitRichEditor
@testable import RuneLauncher

private func collectTreeTexts(_ node: Any, into out: inout [String]) {
    if let dict = node as? [String: Any] {
        if let text = dict["text"] as? String {
            out.append(text)
        }
        if let elements = dict["elements"] as? [Any] {
            for element in elements {
                collectTreeTexts(element, into: &out)
            }
        }
        if let root = dict["root"] {
            collectTreeTexts(root, into: &out)
        }
        if let children = dict["children"] as? [Any] {
            for child in children {
                collectTreeTexts(child, into: &out)
            }
        }
    } else if let arr = node as? [Any] {
        for item in arr {
            collectTreeTexts(item, into: &out)
        }
    }
}

private func collectTreeKeys(_ node: Any, into out: inout Set<String>) {
    if let dict = node as? [String: Any] {
        if let key = dict["key"] as? String {
            out.insert(key)
        }
        if let elements = dict["elements"] as? [Any] {
            for element in elements {
                collectTreeKeys(element, into: &out)
            }
        }
        if let root = dict["root"] {
            collectTreeKeys(root, into: &out)
        }
        if let children = dict["children"] as? [Any] {
            for child in children {
                collectTreeKeys(child, into: &out)
            }
        }
    } else if let arr = node as? [Any] {
        for item in arr {
            collectTreeKeys(item, into: &out)
        }
    }
}

private func findTreeNodeValue(_ node: Any, forKey targetKey: String) -> String? {
    if let dict = node as? [String: Any] {
        if (dict["key"] as? String) == targetKey, let value = dict["value"] as? String {
            return value
        }
        for (_, v) in dict {
            if let found = findTreeNodeValue(v, forKey: targetKey) {
                return found
            }
        }
    } else if let arr = node as? [Any] {
        for item in arr {
            if let found = findTreeNodeValue(item, forKey: targetKey) {
                return found
            }
        }
    }
    return nil
}

private func parseTree(_ data: Data) throws -> (keys: Set<String>, texts: [String]) {
    let json = try JSONSerialization.jsonObject(with: data)
    var keys = Set<String>()
    var texts: [String] = []
    collectTreeKeys(json, into: &keys)
    collectTreeTexts(json, into: &texts)
    return (keys, texts)
}

@Suite("Phase 3 Unblocked Kit & Odometer Examples", .serialized)
@MainActor
struct Phase3KitUnblockedTests {
    @Test("odometer: RollingText initial state and Up/Down/Step/Big step script replay")
    func odometerRollingTextAndButtons() throws {
        let initial = try HeadlessRunner.run(RuneOdometerApp.makeSpec(), args: ToolingArgs.parse([]))
        let parsed0 = try parseTree(initial.treeJSON)
        #expect(parsed0.keys.contains("head"))
        #expect(parsed0.keys.contains("head-usage"))
        #expect(parsed0.keys.contains("head-crumbs"))
        #expect(parsed0.keys.contains("head-lead"))
        #expect(parsed0.keys.contains("head-plain"))
        #expect(parsed0.keys.contains("up"))
        #expect(parsed0.keys.contains("down"))
        #expect(parsed0.keys.contains("step"))
        #expect(parsed0.keys.contains("big"))
        #expect(!parsed0.texts.contains("RollingText"))

        let script = """
        [
          {"t": 0.05, "key": "up", "type": "tap"},
          {"t": 0.20, "key": "step", "type": "tap"},
          {"t": 0.35, "key": "big", "type": "tap"}
        ]
        """
        let after = try HeadlessRunner.run(
            RuneOdometerApp.makeSpec(),
            args: ToolingArgs.parse(["--script", script, "--at", "1.50"])
        )
        let parsed1 = try parseTree(after.treeJSON)
        // RollingText splits digits/chars into individual text leaves (`1`, `0`, `s`, `$`, `1`, `0`, `.`, `4`, `5`, `1`, `1`, `1`, `.`, `7`, `K`).
        let joined = parsed1.texts.joined(separator: " ")
        #expect(joined.contains("1 0 s"))
        #expect(joined.contains("$ 1 0 . 4 5"))
        #expect(joined.contains("1 1 1 . 7 K"))
    }

    @Test("kit-table: 100k artifacts initial render and column sorting")
    func kitTable100kAndSort() throws {
        var s = initialTableExampleState()
        #expect(s.rows.count == 100_000)
        #expect(s.table.sortColumn == "name")
        #expect(s.table.sortDir == .ascending)
        #expect(s.table.selectedCount == 1)
        #expect(s.table.selected == [s.rows[2].id])

        let out = try HeadlessRunner.run(RuneKitTableApp.makeSpec(), args: ToolingArgs.parse([]))
        let parsed = try parseTree(out.treeJSON)
        #expect(parsed.keys.contains("frame"))
        #expect(parsed.keys.contains("status"))
        #expect(parsed.texts.contains("100,000 artifacts · 1 selected"))

        sortArtifacts(&s, col: "size", dir: .descending)
        #expect(s.rows[0].size >= s.rows[1].size)
        sortArtifacts(&s, col: "time", dir: .ascending)
        #expect(s.rows[0].ms <= s.rows[1].ms)
    }

    @Test("kit-tab-strip: tabs, overflow (40), single (1) scenes and script actions")
    func kitTabStripScenesAndActions() throws {
        let tabsOut = try HeadlessRunner.run(RuneKitTabStripApp.makeApp(), args: ToolingArgs.parse(["--scene", "tabs"]))
        let tabsParsed = try parseTree(tabsOut.treeJSON)
        #expect(tabsParsed.keys.contains("top"))
        #expect(tabsParsed.keys.contains("side"))
        #expect(tabsParsed.keys.contains("sample-0"))
        #expect(tabsParsed.keys.contains("sample-1"))
        #expect(tabsParsed.keys.contains("sample-2"))
        #expect(tabsParsed.texts.contains("Formatting tour"))

        let overflowState = withDemoTabs(count: 40, active: 2)
        #expect(overflowState.tabs.count == 40)
        #expect(overflowState.active == "s2")
        _ = try HeadlessRunner.run(RuneKitTabStripApp.makeApp(), args: ToolingArgs.parse(["--scene", "overflow"]))

        let singleState = withDemoTabs(count: 1, active: 0)
        #expect(singleState.tabs.count == 1)
        #expect(singleState.active == "s0")
        let singleOut = try HeadlessRunner.run(RuneKitTabStripApp.makeApp(), args: ToolingArgs.parse(["--scene", "single"]))
        let singleParsed = try parseTree(singleOut.treeJSON)
        #expect(singleParsed.texts.contains("Formatting tour"))

        let script = """
        [
          {"t": 0.05, "key": "new-tab", "type": "tap"},
          {"t": 0.20, "key": "add-many", "type": "tap"}
        ]
        """
        let scriptedOut = try HeadlessRunner.run(
            RuneKitTabStripApp.makeApp(),
            args: ToolingArgs.parse(["--scene", "tabs", "--script", script, "--at", "0.50"])
        )
        let scriptedParsed = try parseTree(scriptedOut.treeJSON)
        #expect(scriptedParsed.texts.contains("New session"))
    }

    @Test("kit-shell: default, virtual (5k), page scenes and keyboard shortcuts")
    func kitShellScenesAndShortcuts() throws {
        let defaultOut = try HeadlessRunner.run(RuneKitShellApp.makeApp(), args: ToolingArgs.parse(["--scene", "default"]))
        let defaultParsed = try parseTree(defaultOut.treeJSON)
        #expect(defaultParsed.texts.contains("Home"))
        #expect(defaultParsed.texts.contains("Settings"))
        #expect(defaultParsed.texts.contains("Fix scroll jank in the list"))

        let virtualState = initialShellExampleState(arguments: ["virtual"])
        #expect(virtualState.virtualised)
        #expect(virtualState.sessions.count == 5_000)
        let virtualOut = try HeadlessRunner.run(RuneKitShellApp.makeApp(), args: ToolingArgs.parse(["--scene", "virtual"]))
        let virtualParsed = try parseTree(virtualOut.treeJSON)
        #expect(virtualParsed.texts.contains("Session 5000"))

        let pageOut = try HeadlessRunner.run(RuneKitShellApp.makeApp(), args: ToolingArgs.parse(["--scene", "page"]))
        let pageParsed = try parseTree(pageOut.treeJSON)
        #expect(pageParsed.texts.contains("Settings"))
        #expect(pageParsed.texts.contains("Workspace Settings"))

        var s = initialShellExampleState(arguments: [])
        #expect(s.sidebar.isOpen)
        #expect(!s.inspector.isOpen)
        var tx = Tx()
        let toggledSidebar = shellExampleOnKey(
            &s,
            ev: KeyEvent(key: .text("b"), mods: Mods(shift: true, cmd: true)),
            &tx
        )
        #expect(toggledSidebar)
        #expect(!s.sidebar.isOpen)

        let toggledInspector = shellExampleOnKey(
            &s,
            ev: KeyEvent(key: .text("i"), mods: Mods(alt: true, cmd: true)),
            &tx
        )
        #expect(toggledInspector)
        #expect(s.inspector.isOpen)
    }

    @Test("kit-rich-editor: rich marks, mention pills, syntax decorations, and toolbar script replay")
    func kitRichEditorParity() throws {
        let initial = RichEditorState()
        #expect(initial.edit.hasRichMark(.bold))
        #expect(initial.edit.displayPills().map(\.id) == [
            "agent:review",
            "file:crates/rune/src/edit.rs",
        ])

        let syntax = SyntaxTheme.fromKit(Kit.neutral(dark: true))
        let spans = richCodeBlockSpans(edit: initial.edit, theme: syntax)
        #expect(!spans.isEmpty)

        var mutated = initial
        insertRichMention(&mutated.edit)
        #expect(mutated.edit.displayPills().contains(where: { $0.id == "file:crates/rune/src/text.rs" }))

        let head = try HeadlessRunner.run(RuneKitRichEditorApp.makeSpec(), args: ToolingArgs.parse([]))
        let parsed = try parseTree(head.treeJSON)
        #expect(parsed.texts.contains("Rich composer"))
        #expect(parsed.keys.contains("toolbar"))
        for btnKey in ["bold", "italic", "underline", "strike", "code", "link", "mention", "bullet", "numbered", "quote", "codeblock"] {
            #expect(parsed.keys.contains(btnKey))
        }

        let headJSON = try JSONSerialization.jsonObject(with: head.treeJSON)
        let beforeValue = findTreeNodeValue(headJSON, forKey: "composer-input-input") ?? ""
        #expect(beforeValue.contains("edit.rs"))
        #expect(!beforeValue.contains("text.rs"))

        // Script replay: tap "@" mention button and verify mention pill insertion in rendered tree.
        let steps: [[String: Any]] = [
            ["t": 0.05, "type": "tap", "key": "mention"],
        ]
        let scriptData = try JSONSerialization.data(withJSONObject: steps)
        let scriptString = String(decoding: scriptData, as: UTF8.self)
        let after = try HeadlessRunner.run(
            RuneKitRichEditorApp.makeSpec(),
            args: ToolingArgs.parse(["--script", scriptString])
        )
        let afterParsed = try parseTree(after.treeJSON)
        #expect(afterParsed.keys.contains("composer-input-input"))
        let afterJSON = try JSONSerialization.jsonObject(with: after.treeJSON)
        let afterValue = findTreeNodeValue(afterJSON, forKey: "composer-input-input") ?? ""
        #expect(afterValue.contains("text.rs"))
    }

    @Test("launcher: multi-window notes + launcher + globalShortcut cmd+space + desktop menu-bar")
    func launcherMultiWindowAndGlobalShortcut() throws {
        let listOut = try RuneMultiWindow.runHeadless(
            RuneLauncherApp.makeWindows(desktop: false),
            args: ToolingArgs.parse(["--list-windows"])
        )
        #expect(listOut.windowKeys == ["notes", "launcher"])

        let desktopList = try RuneMultiWindow.runHeadless(
            RuneLauncherApp.makeWindows(desktop: true),
            args: ToolingArgs.parse(["--list-windows"])
        )
        #expect(desktopList.windowKeys == ["notes", "launcher", "menu-bar"])

        let notesOut = try RuneMultiWindow.runHeadless(
            RuneLauncherApp.makeWindows(desktop: false),
            args: ToolingArgs.parse(["--window", "notes"])
        )
        let notesParsed = try parseTree(notesOut.treeJSON)
        #expect(notesParsed.texts.contains("Groceries"))
        #expect(notesParsed.texts.contains("⌘Space to search"))

        // Trigger the registered `cmd+space` globalShortcut in the `launcher` window, filter to "li" (query autofocuses on launch).
        let steps: [[String: Any]] = [
            ["t": 0.05, "shortcut": "cmd+space"],
            ["t": 0.30, "type": "type", "text": "li", "every": 0.01],
        ]
        let scriptData = try JSONSerialization.data(withJSONObject: steps)
        let scriptString = String(decoding: scriptData, as: UTF8.self)
        let launcherOut = try RuneMultiWindow.runHeadless(
            RuneLauncherApp.makeWindows(desktop: false),
            args: ToolingArgs.parse(["--window", "launcher", "--script", scriptString])
        )
        let launcherParsed = try parseTree(launcherOut.treeJSON)
        #expect(launcherParsed.keys.contains("panel"))
        #expect(launcherParsed.keys.contains("results"))
        #expect(launcherParsed.keys.contains("result-1"))
        #expect(launcherParsed.keys.contains("result-2"))
        #expect(!launcherParsed.keys.contains("result-0"))
        #expect(!launcherParsed.keys.contains("result-3"))
    }
}
