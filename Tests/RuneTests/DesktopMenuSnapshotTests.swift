import Testing
@testable import Rune

@Suite("Desktop menu snapshots")
struct DesktopMenuSnapshotTests {
    private func item(
        _ id: String, _ location: NativeMenuLocation = .app,
        after: String? = nil, accelerator: String? = nil,
        keysFirst: Bool = false, enabled: Bool = true, checked: Bool = false
    ) -> NativeMenuItem<Int> {
        NativeMenuItem(id: id, title: id, location: location, afterId: after,
                       keyEquivalent: accelerator, keysFirst: keysFirst, enabled: enabled, checked: checked) { _, _ in }
    }

    @Test func groupsByVisibleTitleAndPlacesAnchoredSiblings() throws {
        var separator = NativeMenuItem<Int>.separator(location: .named("Tools"))
        separator.afterId = "anchor"
        let snapshot = DesktopMenuSnapshot(revision: 39, items: [
            item("help", .named("Help")), item("anchor", .named("Tools")), item("edit", .named("Edit")),
            item("alias", .named("Studio")), item("extra", .named("Tools")), item("file", .named("File")),
            item("one", .named("Tools"), after: "anchor"), item("window", .named("Window")), separator,
            item("app"), item("two", .named("Tools"), after: "anchor"), item("custom", .named("Music")),
            item("unresolved", .named("Music"), after: "anchor"), item("dock", .dock)
        ], applicationTitle: "Studio")

        #expect(snapshot.revision == 39)
        #expect(snapshot.sections.map(\.title) == ["Studio", "File", "Edit", "Tools", "Music", "Window", "Help"])
        #expect(snapshot.sections[0].items.map(\.id) == ["alias", "app"])
        let tools = try #require(snapshot.sections.first { $0.title == "Tools" }).items
        #expect(tools.map(\.id) == ["anchor", "one", separator.id, "two", "extra"])
        #expect(tools[2].isSeparator)
        #expect(snapshot.sections.first { $0.title == "Music" }?.items.map(\.id) == ["custom", "unresolved"])
    }

    @Test func omitsEmptyAppAndDockOnlySections() {
        let snapshot = DesktopMenuSnapshot(revision: 0, items: [
            item("docs", .named("Help")), item("new", .named("File")), item("hidden", .dock)
        ], applicationTitle: "Studio")
        #expect(snapshot.sections.map(\.title) == ["File", "Help"])
        #expect(DesktopMenuSnapshot(revision: 1, items: [item("hidden", .dock)], applicationTitle: "Studio").sections.isEmpty)
    }

    @Test func matchesEnabledLogicalKeysInVisibleOrderAndPreservesItemFlags() throws {
        #if os(Windows)
        #expect(KeyPlatform.current == .windows)
        #elseif os(macOS)
        #expect(KeyPlatform.current == .mac)
        #elseif os(Linux)
        #expect(KeyPlatform.current == .linux)
        #endif
        var separator = NativeMenuItem<Int>.separator()
        separator.keyEquivalent = "mod+s"
        let snapshot = DesktopMenuSnapshot(revision: 4, items: [
            item("dock", .dock, accelerator: "mod+s"), separator,
            item("disabled", accelerator: "mod+s", enabled: false), item("later", .named("Tools"), accelerator: "mod+s"),
            item("save", accelerator: "mod+s", keysFirst: true, checked: true),
            item("literal", accelerator: "é"), item("plus", accelerator: "mod++"),
            item("invalid", accelerator: "mod+"), item("super", accelerator: "super+w")
        ], applicationTitle: "Studio")
        let nativeModifiers: [(KeyPlatform, Mods)] = [
            (.mac, Mods(cmd: true, logo: true)),
            (.windows, Mods(ctrl: true, cmd: true)),
            (.linux, Mods(ctrl: true, cmd: true))
        ]
        for (platform, primary) in nativeModifiers {
            let event = KeyEvent(key: .command("s"), mods: primary)
            let save = try #require(snapshot.matching(event, on: platform))
            #expect(save.id == "save" && save.title == "save" && save.keysFirst && save.checked && save.enabled)
            if platform == .current { #expect(snapshot.matching(event)?.id == "save") }
            #expect(snapshot.matching(KeyEvent(key: .text("É")), on: platform)?.id == "literal")
            #expect(snapshot.matching(KeyEvent(key: .text("++")), on: platform) == nil)
            #expect(snapshot.matching(KeyEvent(key: .text("+"), mods: primary), on: platform)?.id == "plus")
            #expect(snapshot.matching(KeyEvent(key: .text("s")), on: platform) == nil)
            #expect(snapshot.matching(KeyEvent(key: .text("w"), mods: Mods(logo: true)), on: platform)?.id == "super")
            if platform != .mac {
                #expect(snapshot.matching(KeyEvent(key: .command("w"), mods: primary), on: platform) == nil)
            }
        }
        #expect(snapshot.sections[0].items.first { $0.id == "invalid" }?.accelerator == nil)
        #expect(snapshot.sections[0].items.first?.accelerator == nil)
    }
}
