import Foundation
import Testing
@testable import RuneKit
@testable import Rune
@testable import RuneRef

@Suite("RuneKit Palette, Controls, Markdown & Diff Tests")
struct RuneKitTests {
    @Test("Kit.fromPalette enforces WCAG 4.5:1 muted and 3.0:1 faint contrast and pure-black surface lift")
    func paletteContrastAndElevationLayers() {
        let pairs = [
            ("#ffffff", "#000000"),
            ("#101010", "#ffffff"),
            ("#000000", "#ededed"),
            ("#767676", "#000000"),
            ("#767676", "#ffffff"),
        ]
        for (bgHex, fgHex) in pairs {
            let bg = Color.hex(bgHex)!
            let fg = Color.hex(fgHex)!
            let kit = Kit.fromPalette(PaletteSeed(bg: bg, fg: fg, accent: Color.hex("#e5484d")!))
            #expect(bg.contrastRatio(with: kit.c.textMuted) >= 4.49, "Muted contrast failed on \(bgHex)")
            #expect(bg.contrastRatio(with: kit.c.textFaint) >= 2.99, "Faint contrast failed on \(bgHex)")
        }

        // Pure black dark seed still lifts layer01..layer04 visibly via DARK_FLOOR!
        let pureBlackKit = Kit.fromPalette(PaletteSeed(bg: .black, fg: .white, accent: .white))
        let lums = [
            pureBlackKit.c.page.luminance,
            pureBlackKit.c.layer01.luminance,
            pureBlackKit.c.layer02.luminance,
            pureBlackKit.c.layer03.luminance,
            pureBlackKit.c.layer04.luminance,
        ]
        for i in 0..<(lums.count - 1) {
            #expect(lums[i] < lums[i + 1], "Expected rising luminance at step \(i): \(lums)")
        }
    }

    @Test("Markdown parser & renderer handle headings, inline spans, GFM tables, and fenced Swift code")
    func markdownParsingAndRendering() {
        let md = """
        # Architecture

        Rune renders **crisp** *GPU* primitives with `RuneRef` and [Metal](https://developer.apple.com/metal/).

        | Crate | Purpose |
        | --- | --- |
        | RuneMotion | Analytic springs |
        | RuneKit | UI components |

        ```swift
        // Sample view
        func view(s: Int) -> String {
            return "ok"
        }
        ```
        """
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 4)
        if case let .table(headers, rows) = blocks[2] {
            #expect(headers == ["Crate", "Purpose"])
            #expect(rows.count == 2)
        } else {
            Issue.record("Expected GFM table at block 2")
        }

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(500, 600)) { _, _ in
            kit.markdown(md)
        }
        let scene = rt.frame(at: 0.0)
        #expect(scene.primitives.count > 20)
    }

    @Test("FileDiff LCS computation, unified git patch parser, and unified/split diffView")
    func diffComputationAndRendering() {
        let oldSrc = "line 1\nline 2\nline 3"
        let newSrc = "line 1\nline two\nline 3\nline 4"
        let computed = FileDiff.between(old: oldSrc, new: newSrc, path: "main.swift")
        #expect(computed.additionsCount == 2)
        #expect(computed.deletionsCount == 1)

        let patch = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -10,3 +10,4 @@
         let a = 1
        -let b = 2
        +let b = 20
        +let c = 30
         return a + b
        """
        let parsed = FileDiff.parseUnified(patch)
        #expect(parsed.count == 1)
        #expect(parsed[0].newPath == "Sources/App.swift")
        #expect(parsed[0].additionsCount == 2)
        #expect(parsed[0].deletionsCount == 1)

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(640, 400)) { _, _ in
            col().gap(12)
                .child(kit.diffView(key: "u", parsed[0], style: .unified))
                .child(kit.diffView(key: "s", parsed[0], style: .split))
        }
        let scene = rt.frame(at: 0.0)
        #expect(!scene.primitives.isEmpty)
    }

    @Test("Kit controls interactive smoke test: SegmentedControl, Switch, Checkbox, Collapsible")
    func kitControlsInteraction() {
        struct UIState {
            var tab = "general"
            var enabled = false
            var checked = false
            var expanded = false
        }

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<UIState>(state: UIState(), viewport: Vec2(480, 400)) { s, _ in
            col().sizeFull().p(16).gap(12)
                .child(
                    kit.segmentedControl(
                        key: "tabs",
                        options: [(id: "general", label: "General"), (id: "motion", label: "Motion")],
                        selected: s.tab
                    ) { st, id in st.tab = id }
                )
                .child(kit.switchControl(key: "sw", isOn: s.enabled) { st, v in st.enabled = v })
                .child(kit.checkbox(key: "cb", checked: s.checked, label: "Agree") { st, v in st.checked = v })
                .child(
                    kit.collapsible(key: "col", title: "More", isOpen: s.expanded, onToggle: { st, o in st.expanded = o }) {
                        text("Details inside")
                    }
                )
        }

        _ = rt.frame(at: 0.0)
        let pillBefore = rt.element(byKey: "tabs-active-pill")!.rect[0]

        // Click second tab -> shared-element active pill flies across screen space (`Travel.screen`)!
        let motionTab = rt.element(byKey: "tabs-motion")!.rect
        let tabCenter = Vec2(motionTab[0] + motionTab[2] * 0.5, motionTab[1] + motionTab[3] * 0.5)
        rt.pointerDown(at: tabCenter, at: 0.1)
        rt.pointerUp(at: tabCenter, at: 0.15)
        #expect(rt.state.tab == "motion")

        _ = rt.frame(at: 0.20)
        let pillMid = rt.element(byKey: "tabs-active-pill")!.rect[0]
        #expect(pillMid > pillBefore)
        #expect(rt.isAnimating)
    }

    @Test("Palette focus modes, elevation ring overrides, warm hue preservation, and alpha helpers")
    func paletteFocusRingsWarmHueAndHelpers() {
        let seed = PaletteSeed(
            bg: .black,
            fg: .white,
            accent: Color.hex("#ff2a2a")!
        )
        #expect(Kit.fromPalette(seed, focus: .ink).c.borderFocus == .white)
        #expect(Kit.fromPalette(seed, focus: .accent).c.borderFocus == seed.accent)
        let customBlue = Color.hex("#3b82f6")!
        #expect(Kit.fromPalette(seed, focus: .custom(customBlue)).c.borderFocus == customBlue)

        // Default focus is blue (blue channel > red channel)
        let defaultKit = Kit.fromPalette(seed)
        #expect(defaultKit.c.borderFocus.b > defaultKit.c.borderFocus.r)
        #expect(defaultKit.blendOver == .black)
        #expect(defaultKit.c.borderMuted.a < defaultKit.c.borderBase.a)
        #expect(defaultKit.c.borderBase.a < defaultKit.c.borderStrong.a)

        // Elevation rings follow c.borderBase overrides via shadowLayers
        var k = Kit.fromPalette(PaletteSeed(
            bg: Color.hex("#0a0a0a")!,
            fg: Color.hex("#ededed")!,
            accent: Color.hex("#e5484d")!
        ))
        let overrideColor = Color.hex("#336699")!
        k.c.borderBase = overrideColor
        let rings = k.shadowLayers(k.elevation.floating).filter { $0.blur == 0.0 }
        #expect(!rings.isEmpty)
        #expect(rings.allSatisfy { $0.color == overrideColor })

        // Warm palette preserves warm hue (positive yellow/orange chroma) in derived neutrals
        let warmKit = Kit.fromPalette(PaletteSeed(
            bg: Color.hex("#e8e4dc")!,
            fg: .black,
            accent: Color.hex("#d81414")!
        ))
        let lab = warmKit.c.textMuted.toOKLab()
        let chroma = hypotf(lab[1], lab[2])
        #expect(chroma > 0.009)

        // Alpha/selection helpers
        #expect(warmKit.selection().a > 0)
        #expect(warmKit.light(0.5).a > 0)
        #expect(warmKit.darkAlpha(0.5).a > 0)
        #expect(warmKit.lightOn(0.2, backdrop: .black).a > 0)
    }

    @Test("Slider renders track, fill, and knob, and responds to drag & keyboard steps")
    func sliderKnobAndInteraction() {
        struct S { var v: Float = 0.5 }
        let kit = Kit.neutral(dark: true)
        let rt = Runtime<S>(state: S(), viewport: Vec2(300, 120)) { s, _ in
            row().sizeFull().center()
                .child(kit.slider(key: "sl", value: s.v, range: 0...1, width: 200) { st, val in st.v = val })
        }
        _ = rt.frame(at: 0.0)
        #expect(rt.element(byKey: "sl-track") != nil)
        #expect(rt.element(byKey: "sl-fill") != nil)
        #expect(rt.element(byKey: "sl-knob") != nil)

        let slRect = rt.element(byKey: "sl")!.rect
        let rightEnd = Vec2(slRect[0] + slRect[2] * 0.9, slRect[1] + slRect[3] * 0.5)
        rt.pointerDown(at: rightEnd, at: 0.1)
        rt.pointerUp(at: rightEnd, at: 0.15)
        #expect(rt.state.v > 0.8)

        _ = rt.keyDown(KeyEvent(key: .arrowLeft), at: 0.2)
        #expect(rt.state.v < 0.95)
    }

    @Test("Checkbox indeterminate, Button variants, IconButton variants, and Toast tones")
    func controlsVariantsAndToasts() {
        struct S { var clicks = 0 }
        let kit = Kit.neutral(dark: true)
        let rt = Runtime<S>(state: S(), viewport: Vec2(600, 480)) { _, _ in
            col().sizeFull().p(16).gap(8)
                .child(
                    row().gap(8)
                        .child(kit.button(key: "b1", "Primary", variant: .primary, leadingIcon: KitIcons.plus) { st, _ in st.clicks += 1 })
                        .child(kit.button(key: "b2", "Accent", variant: .accent, trailingIcon: KitIcons.arrowRight) { st, _ in st.clicks += 1 })
                        .child(kit.button(key: "b3", "Danger", variant: .danger, disabled: true) { st, _ in st.clicks += 1 })
                        .child(kit.iconButton(key: "ib1", svg: KitIcons.close, label: "Close", variant: .accent) { st, _ in st.clicks += 1 })
                )
                .child(kit.checkbox(key: "cb-mix", checked: false, indeterminate: true, label: "Mixed") { _, _ in })
                .child(kit.toast(key: "t-ok", message: "Saved", tone: .success) { _ in })
                .child(kit.toast(key: "t-err", message: "Failed", tone: .danger) { _ in })
        }
        let scene = rt.frame(at: 0.0)
        #expect(!scene.primitives.isEmpty)
        #expect(rt.element(byKey: "cb-mix-indeterminate") != nil)
        #expect(rt.element(byKey: "t-ok") != nil)
        #expect(rt.element(byKey: "t-err") != nil)

        let b1 = rt.element(byKey: "b1")!.rect
        rt.pointerDown(at: Vec2(b1[0] + 10, b1[1] + 10), at: 0.1)
        rt.pointerUp(at: Vec2(b1[0] + 10, b1[1] + 10), at: 0.15)
        #expect(rt.state.clicks == 1)

        // Disabled button must be inert
        let b3 = rt.element(byKey: "b3")!.rect
        rt.pointerDown(at: Vec2(b3[0] + 10, b3[1] + 10), at: 0.2)
        rt.pointerUp(at: Vec2(b3[0] + 10, b3[1] + 10), at: 0.25)
        #expect(rt.state.clicks == 1)
    }

    @Test("Accordion, List, Select, Dialog, TabStrip, Menu, Combobox, Tooltip & ToastStack")
    func componentsAndOverlaysSmokeTest() {
        struct S {
            var expanded: Set<String> = ["a"]
            var selectedTab = "t1"
            var selectedItem = "opt1"
            var selectOpen = true
            var dialogOpen = true
            var search = TextEdit("")
            var comboQuery = TextEdit("")
            var comboOpen = true
        }

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<S>(state: S(), viewport: Vec2(800, 700)) { s, _ in
            let tb: El<S> = kit.windowTitlebar(key: "tb", title: "App", subtitle: "v1.0")
            let tabs: El<S> = kit.tabStrip(
                key: "tabs",
                tabs: [TabItem(id: "t1", title: "Main", dirty: true), TabItem(id: "t2", title: "Diff")],
                selected: s.selectedTab,
                onSelect: { st, id in st.selectedTab = id },
                onClose: { _, _ in }
            )
            let acc: El<S> = kit.accordion(
                key: "acc",
                items: [
                    AccordionItem(id: "a", title: "Section A") { text("Body A") },
                    AccordionItem(id: "b", title: "Section B") { text("Body B") },
                ],
                expanded: s.expanded
            ) { st, id, open in
                if open { st.expanded.insert(id) } else { st.expanded.remove(id) }
            }
            let lst: El<S> = kit.list(key: "lst", items: [
                kit.listItem(key: "li1", title: "First", subtitle: "Detail", selected: true) { _, _ in },
                kit.listItem(key: "li2", title: "Second", trailing: kit.keybind(["⌘", "K"])) { _, _ in },
            ])
            let sel: El<S> = kit.select(
                key: "sel",
                options: [(id: "opt1", label: "One"), (id: "opt2", label: "Two")],
                selected: s.selectedItem,
                isOpen: s.selectOpen,
                onToggleOpen: { st, o in st.selectOpen = o },
                onSelect: { st, id in st.selectedItem = id }
            )
            let cbx: El<S> = kit.combobox(
                key: "cbx",
                options: [ComboboxOption(id: "c1", label: "Alpha"), ComboboxOption(id: "c2", label: "Beta")],
                selected: "c1",
                queryKeyPath: \.comboQuery,
                queryText: s.comboQuery.text,
                isOpen: s.comboOpen,
                onToggleOpen: { st, o in st.comboOpen = o },
                onSelect: { _, _ in }
            )
            let mnu: El<S> = kit.menu(key: "mnu", entries: [
                .section("Actions"),
                .item(id: "copy", label: "Copy", shortcut: ["⌘", "C"]) { _, _ in },
                .separator,
                .item(id: "del", label: "Delete", destructive: true) { _, _ in },
            ])

            let mainCol: El<S> = col().sizeFull().p(16).gap(10)
                .child(tb)
                .child(tabs)
                .child(acc)
                .child(lst)
                .child(kit.searchField(key: "sf", \.search, onClear: { st in st.search.clear() }))
                .child(kit.loader(key: "ldr", label: "Syncing"))
                .child(kit.rollingText(key: "rt", "42 items"))
                .child(sel)
                .child(cbx)
                .child(mnu)
                .child(kit.tooltip(key: "tip", text: "Hint", isVisible: true, trigger: text("Hover me")))
                .child(kit.scrollBar(key: "sb", contentFraction: 0.4, scrollFraction: 0.2, trackHeight: 100))

            var root: El<S> = col().sizeFull().child(mainCol)
                .child(kit.toastStack(toasts: [ToastEntry(id: "t1", message: "Ready", tone: .info)]) { _, _ in })
            if s.dialogOpen {
                root = root.child(
                    kit.dialog(key: "dlg", title: "Confirm", onDismiss: { st in st.dialogOpen = false }, body: text("Proceed?"))
                )
            }
            return root
        }

        let scene = rt.frame(at: 0.0)
        #expect(!scene.primitives.isEmpty)
        #expect(rt.element(byKey: "acc-a-body") != nil)
        #expect(rt.element(byKey: "acc-b-body") == nil)
        #expect(rt.element(byKey: "sel-menu") != nil)
        #expect(rt.element(byKey: "cbx-popup") != nil)
        #expect(rt.element(byKey: "tip-tip") != nil)
        #expect(rt.element(byKey: "dlg-sheet") != nil)

        // Escape dismisses modal dialog
        _ = rt.keyDown(KeyEvent(key: .escape), at: 0.1)
        #expect(rt.state.dialogOpen == false)
    }

    @Test("Markdown parser handles paragraph interruption, strike/underscore spans, blockquotes, Python/SQL highlight & find")
    func markdownExtendedParsingAndHighlight() {
        let md = """
        Intro paragraph
        + First bullet
        + Second bullet

        > Quote with **bold** and `code` and ~~old~~ _italics_

        ```python
        # Python comment
        def greet(name):
            return "hi"
        ```
        """
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 4)
        #expect(blocks[0] == .paragraph("Intro paragraph"))
        if case .unorderedList(let items) = blocks[1] {
            #expect(items == ["First bullet", "Second bullet"])
        } else {
            Issue.record("Expected unorderedList at block 1")
        }

        let kit = Kit.neutral(dark: true)
        let pySpans = MarkdownParser.highlightCode("# comment\ndef f(): return 1", language: "python", kit: kit)
        #expect(pySpans.contains(where: { $0.text.contains("# comment") && $0.italic }))

        let matches = MarkdownParser.findMatches(in: md, query: "bullet")
        #expect(matches.count == 2)
    }

    @Test("FileDiff wordDiff and copyableText")
    func diffWordDiffAndCopy() {
        let words = FileDiff.wordDiff(old: "let a = 1", new: "let b = 1")
        #expect(words.contains(where: { $0.kind == .removed && $0.text == "a" }))
        #expect(words.contains(where: { $0.kind == .added && $0.text == "b" }))

        let diff = FileDiff.between(old: "one\ntwo", new: "one\nthree", path: "f.swift")
        let copied = diff.copyableText(includeRemoved: false)
        #expect(copied == "one\nthree")
    }
}
