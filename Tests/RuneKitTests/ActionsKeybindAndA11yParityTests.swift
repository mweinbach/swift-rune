import Foundation
import Testing
@testable import RuneKit
@testable import Rune
@testable import RuneMotion

@Suite("RuneKit Actions, Keybind, Budget, CSS, Interactive & Docs A11y Parity Tests (Increment 5)")
struct ActionsKeybindAndA11yParityTests {
    // MARK: - Helpers

    private func rectFor(_ rt: Runtime<some Sendable>, key: String) -> [Float]? {
        rt.elements().first(where: { !$0.exiting && $0.key == key })?.rect
    }

    private func projectAccessibility<S>(_ root: El<S>, viewport: Vec2 = Vec2(640, 800)) -> AccessibilityNode? {
        func buildInput(_ el: El<S>) -> LayoutInputNode {
            LayoutInputNode(style: el.layout, children: el.children.map(buildInput))
        }
        let layout = LayoutEngine.compute(root: buildInput(root), viewport: viewport)
        return AccessibilityTreeBuilder.project(element: root, layout: layout)
    }

    private func collectA11yLabels(_ node: AccessibilityNode) -> [String] {
        [node.label].compactMap { $0 } + node.children.flatMap(collectA11yLabels)
    }

    @MainActor
    @Test("Rolling button label sizes at rest identically to plain text button")
    func rollingLabelSizesSameAsPlainText() {
        let kit = Kit.neutral(dark: true)
        for sample in ["Import 3 items", "Importing…"] {
            let plainRT = Runtime<String>(state: sample, viewport: Vec2(400, 100), pixelScale: 2.0, systemDark: true) { label, _ in
                row().p(20).child(
                    kit.actionButton(key: "btn", label: .text(label)) { _, _ in }
                )
            }
            let rollingRT = Runtime<String>(state: sample, viewport: Vec2(400, 100), pixelScale: 2.0, systemDark: true) { label, _ in
                row().p(20).child(
                    kit.actionButton(key: "btn", label: .rolling(key: "import-label", text: label)) { _, _ in }
                )
            }
            _ = plainRT.frame(at: 0.0)
            _ = rollingRT.frame(at: 0.0)

            let pRect = rectFor(plainRT, key: "btn")
            let rRect = rectFor(rollingRT, key: "btn")
            #expect(pRect != nil && rRect != nil)
            if let pRect, let rRect {
                #expect(abs(pRect[2] - rRect[2]) < 0.5)
                #expect(pRect[3] == rRect[3])
            }
        }
    }

    @MainActor
    @Test("Custom button label receives font and ink while keeping accessible role and label")
    func customLabelGetsButtonFontAndInk() {
        let kit = Kit.neutral(dark: true)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(400, 100), pixelScale: 2.0, systemDark: true) { _, _ in
            row()
                .child(kit.actionButton(key: "plain", label: .text("Save")) { _, _ in })
                .child(
                    kit.actionButton(
                        key: "rich",
                        label: .custom(accessibilityLabel: "Save") { font, ink in
                            text("Save").key("custom").font(font).color(ink).noWrap()
                        }
                    ) { _, _ in }
                )
        }
        _ = rt.frame(at: 0.0)
        let els = rt.elements()
        let plainBtn = els.first(where: { $0.key == "plain" })
        let richBtn = els.first(where: { $0.key == "rich" })
        let plainLabel = els.first(where: { $0.path.hasSuffix("plain/label") || $0.key == "label" })
        let customLabel = els.first(where: { $0.key == "custom" })

        #expect(richBtn?.role == .button && richBtn?.label == "Save")
        #expect(customLabel != nil && plainLabel != nil)
        #expect(customLabel?.textColor == plainLabel?.textColor)
        if let p = plainBtn?.rect, let r = richBtn?.rect {
            #expect(abs(p[2] - r[2]) < 0.5)
        }
    }

    @MainActor
    @Test("Rolling button animates label change, updates accessible label, and keeps neighbour icon spacing")
    func rollingButtonUpdatesAccessibleLabelAndAnimatesWidth() {
        let kit = Kit.neutral(dark: true)
        let rt = Runtime<String>(state: "Import 3 items", viewport: Vec2(500, 100), pixelScale: 2.0, systemDark: true) { label, _ in
            row().p(20).gap(8).children([
                kit.actionButton(
                    key: "button",
                    label: .rolling(key: "import-row-label", text: label),
                    leadingIcon: KitIcons.lock
                ) { _, _ in },
                kit.actionButton(key: "cancel", label: .text("Cancel")) { _, _ in },
            ])
        }
        _ = rt.frame(at: 0.0)

        let btnBefore = rt.elements().first(where: { $0.key == "button" })
        let cancelBefore = rectFor(rt, key: "cancel")
        #expect(btnBefore?.role == .button && btnBefore?.label == "Import 3 items")
        let widthBefore = btnBefore?.rect[2] ?? 0

        rt.update(at: 0.01) { s, _ in s = "Importing…" }
        _ = rt.frame(at: 0.02)

        let btnAfterImmediate = rt.elements().first(where: { $0.key == "button" })
        #expect(btnAfterImmediate?.label == "Importing…")

        for i in 1...60 {
            _ = rt.frame(at: 0.02 + Double(i) * (1.0 / 60.0))
        }
        let widthAfter = rectFor(rt, key: "button")?[2] ?? 0
        let cancelAfter = rectFor(rt, key: "cancel")
        #expect(widthBefore - widthAfter > 5.0)
        if let cancelBefore, let cancelAfter {
            #expect(cancelAfter[0] < cancelBefore[0])
        }
    }

    @MainActor
    @Test("ActionDispatcher and Kit.actionBar dispatch commands, filter queries, and set shortcut tooltips")
    func actionDispatcherAndActionBarParity() {
        struct AppState: Sendable {
            var count = 0
            var log: [String] = []
        }

        let items: [ActionItem<AppState>] = [
            ActionItem(id: "inc", title: "Increment", subtitle: "Add one", shortcut: "⌘+", help: "Increase counter", rollingKey: "inc-roll") { st in
                st.count += 1
                st.log.append("inc")
            },
            ActionItem(id: "save", title: "Save", shortcut: "⌘S") { st in
                st.log.append("save")
            },
            ActionItem(id: "locked", title: "Locked", disabled: true) { st in
                st.log.append("locked")
            },
        ]

        let dispatcher = ActionDispatcher(items: items)
        var state = AppState()
        #expect(dispatcher.canDispatch(id: "inc"))
        #expect(!dispatcher.canDispatch(id: "locked"))
        #expect(dispatcher.item(for: "inc")?.shortcut == "⌘+")
        #expect(!dispatcher.dispatch(id: "locked", state: &state))
        #expect(dispatcher.dispatch(id: "inc", state: &state))
        #expect(state.count == 1 && state.log == ["inc"])
        #expect(dispatcher.filter(query: "add one").map(\.id) == ["inc"])
        #expect(dispatcher.dispatchFirstMatch(query: "increment", state: &state))
        #expect(state.count == 2)

        let kit = Kit.neutral(dark: true)
        let builtBtn = kit.actionButton(
            key: "solo",
            label: .text("Save"),
            leadingIcon: KitIcons.lock,
            help: nil,
            shortcut: "⌘S"
        ) { _, _ in } as El<AppState>
        #expect(builtBtn.a11yDescription == "")
        #expect(builtBtn.a11yShortcutHint == "⌘S")
        #expect(builtBtn.children.allSatisfy { $0.isA11yHidden })

        let rt = Runtime<AppState>(state: AppState(), viewport: Vec2(400, 120), pixelScale: 1.0, systemDark: true) { _, _ in
            kit.actionBar(key: "bar", items: items)
        }
        _ = rt.frame(at: 0.0)
        let incBtn = rt.elements().first(where: { $0.key == "bar-inc" })
        let saveBtn = rt.elements().first(where: { $0.key == "bar-save" })
        let lockedBtn = rt.elements().first(where: { $0.key == "bar-locked" })
        #expect(incBtn?.help == "Increase counter  ⌘+")
        #expect(incBtn?.a11yDescription == "Increase counter")
        #expect(saveBtn?.help == "Save  ⌘S")
        #expect(saveBtn?.a11yDescription == "")
        #expect(incBtn?.focusable == true)
        #expect(lockedBtn?.focusable == false)

        if let r = incBtn?.rect {
            let hit = Vec2(r[0] + r[2] * 0.5, r[1] + r[3] * 0.5)
            rt.pointerMove(to: hit, at: 0.01)
            rt.pointerDown(at: hit, at: 0.01)
            rt.pointerUp(at: hit, at: 0.01)
            _ = rt.frame(at: 0.02)
            #expect(rt.state.count == 1 && rt.state.log == ["inc"])
        }
    }

    // MARK: - Interactive & Elevate (`tests/interactive.rs`)

    @MainActor
    @Test("Kit.interactive tracks hover & press and Kit.elevate adds shadow primitives")
    func kitInteractiveAndElevateParity() {
        let kit = Kit.neutral(dark: true)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { _, _ in
            let rowEl: El<Int> = kit.interactive(
                el().key("row").size(100, 28).bg(kit.c.layer01).onClick { n, _ in n += 1 }
            )
            let cardEl: El<Int> = kit.elevate(
                el().key("card").size(100, 28).bg(kit.c.layer01),
                kit.elevation.floating
            )
            return col().wFull().hFull().children([rowEl, cardEl])
        }
        _ = rt.frame(at: 0.0)
        let rowRest = rt.elements().first(where: { $0.key == "row" })
        #expect(rowRest != nil && rowRest?.hover == 0 && rowRest?.press == 0)

        rt.pointerMove(to: Vec2(50, 14), at: 0.01)
        let hoveredFrame = rt.frame(at: 0.35)
        let rowHovered = rt.elements().first(where: { $0.key == "row" })
        #expect((rowHovered?.hover ?? 0) > 0.9 && rowHovered?.press == 0)

        rt.pointerDown(at: Vec2(50, 14), at: 0.36)
        _ = rt.frame(at: 0.70)
        let rowPressed = rt.elements().first(where: { $0.key == "row" })
        #expect((rowPressed?.press ?? 0) > 0.9)

        rt.pointerUp(at: Vec2(50, 14), at: 0.71)
        _ = rt.frame(at: 0.72)
        #expect(rt.state == 1)

        let plainRT = Runtime<Int>(state: 0, viewport: Vec2(200, 200), pixelScale: 1.0, systemDark: true) { _, _ in
            let rEl: El<Int> = el().key("row").size(100, 28).bg(kit.c.layer01)
            let cEl: El<Int> = el().key("card").size(100, 28).bg(kit.c.layer01)
            return col().wFull().hFull().children([rEl, cEl])
        }
        let plainFrame = plainRT.frame(at: 0.0)
        #expect(!kit.elevation.floating.isEmpty)
        #expect(hoveredFrame.primitives.count >= plainFrame.primitives.count + kit.elevation.floating.count)
    }

    // MARK: - Keybind (`src/keybind.rs`)

    @MainActor
    @Test("Kit.keybind uppercases single ASCII keys, preserves named keys & dotless i, and sets group label")
    func keybindKeycapAndVariantParity() {
        #expect(Kit.keycapLabel("k") == "K")
        #expect(Kit.keycapLabel("Space") == "Space")
        #expect(Kit.keycapLabel("⌘") == "⌘")
        #expect(Kit.keycapLabel("ı") == "ı") // Turkish dotless ı uppercases to I, whose lower is i != ı

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(300, 120), pixelScale: 1.0, systemDark: true) { _, _ in
            col().gap(8).children([
                kit.keybind(["⌘", "k"], variant: .neutral).key("kb-neutral"),
                kit.keybind(["Ctrl", "Space"], variant: .ghost).key("kb-ghost"),
                kit.keybind(["⌘", "P"], variant: .outline).key("kb-outline"),
            ])
        }
        _ = rt.frame(at: 0.0)
        let els = rt.elements()
        let kbNeutral = els.first(where: { $0.key == "kb-neutral" })
        let kbGhost = els.first(where: { $0.key == "kb-ghost" })
        #expect(kbNeutral?.role == .group && kbNeutral?.label == "⌘ k")
        #expect(kbGhost?.role == .group && kbGhost?.label == "Ctrl Space")
        #expect(els.contains(where: { $0.text == "K" }))
        #expect(els.contains(where: { $0.text == "Space" }))
        #expect(els.filter { $0.key == "key0" || $0.key == "key1" }.allSatisfy { $0.a11yHidden })
        let kbEl: El<Int> = kit.keybind(["⌘", "k"], variant: .neutral)
        if let tree = projectAccessibility(kbEl) {
            let labels = collectA11yLabels(tree)
            #expect(labels == ["⌘ k"])
        } else {
            Issue.record("Expected AccessibilityNode for keybind")
        }
    }

    // MARK: - Budget & CSS (`src/budget.rs`, `src/css.rs`, `src/kit.rs`)

    @Test("BudgetCache retains last two commit generations and evicts older LRU entries down to 3/4 limit")
    func budgetCacheCommitGenerationsAndLRUEviction() {
        let budget = BudgetCache<String, Int>(limitBytes: 100)
        budget.advanceCommit() // gen 1
        for k in ["a", "b", "c"] {
            budget.insert(k, value: 1, bytes: 60)
        }
        // All 3 inserted in gen 1 -> keep all 3 despite bytes = 180 (> 100)
        #expect(budget.count == 3 && budget.bytes == 180)
        #expect(budget.usedNow("c"))

        budget.advanceCommit() // gen 2
        #expect(!budget.usedNow("c"))
        #expect(budget.peek("c") == 1)
        #expect(!budget.usedNow("c")) // peek must not bump commit generation
        #expect(budget.get("c") == 1)
        #expect(budget.usedNow("c"))

        budget.advanceCommit() // gen 3: a, b from gen 1 are >= 2 commits old; c is gen 2 (kept)
        budget.insert("d", value: 2, bytes: 60)
        #expect(budget.peek("a") == nil && budget.peek("b") == nil)
        #expect(budget.peek("c") == 1 && budget.peek("d") == 2)
        #expect(budget.bytes == 120)

        budget.advanceCommit() // gen 4
        budget.advanceCommit() // gen 5: both c and d are old
        budget.insert("e", value: 3, bytes: 10)
        #expect(budget.peek("c") == nil && budget.peek("d") == 2 && budget.peek("e") == 3)
        #expect(budget.bytes == 70)

        #expect(budget.remove("d"))
        #expect(!budget.remove("missing"))
        #expect(budget.bytes == 10)
    }

    @Test("KitCSS parses box-shadow layers, inset, drops transparent layers, and parses px lengths")
    func kitCSSBoxShadowsAndLengths() {
        let shadows = KitCSS.boxShadows(
            "#0000001a 0px 1px 1.5px 0px, #ffffff29 0px 0px 0px 0.5px inset, #00000000 0px 0px 0px 0px",
            colorTransform: { $0.alpha(0.5) }
        )
        #expect(shadows.count == 2)
        #expect(shadows[0].y == 1.0 && shadows[0].blur == 1.5 && !shadows[0].inset && abs(shadows[0].color.a - 0.5) < 0.001)
        #expect(shadows[1].spread == 0.5 && shadows[1].inset)
        #expect(KitCSS.px(" 12.5px ") == 12.5)
        #expect(KitCSS.px("8") == 8.0)
        #expect(KitCSS.px("bad") == nil)
    }

    @Test("Kit.neutral populates all semantic tokens without unintended transparent placeholders")
    func kitNeutralTokensNonTransparent() {
        for dark in [false, true] {
            let kit = Kit.neutral(dark: dark)
            let tokens: [Color] = [
                kit.c.surfaceRaisedBase,
                kit.c.surfaceRaisedHover,
                kit.c.borderWeak,
                kit.c.borderHover,
                kit.c.borderActive,
                kit.c.borderDisabled,
                kit.c.textStrong,
                kit.c.textWeak,
                kit.c.textInvertStrong,
                kit.c.iconWeaker,
                kit.c.stdIcon,
                kit.c.stdIconInvert,
                kit.c.stdIconStrong,
                kit.c.stdText,
            ]
            #expect(tokens.allSatisfy { $0.a > 0.0 })
            #expect(kit.light(0.25).a == 0.25)
            #expect(kit.darkAlpha(0.4).a == 0.4)
        }
    }

    // MARK: - Docs & Notes Accessibility (`tests/a11y/docs.rs`)

    @MainActor
    @Test("Markdown, Notes, and Mermaid expose accessible headings, lists, checkboxes, facts, steps, callouts, and figures")
    func docsAccessibilityTreeMatchesDocumentStructure() {
        struct DocState: Sendable {
            var chosenLink: String?
            var toggledTask: Bool?
        }

        let doc = """
        # Release notes

        Read [the guide](https://example.com/guide) first.

        ## Changes

        * [x] tests pass
        * [ ] docs

        - Faster start
        - Smaller downloads

        > Quoted advice.

        | Name | Size |
        | --- | ---: |
        | app | 4 MB |
        """

        let noteSrc = """
        ```facts
        Status: {done} shipped
        Owner: Ada
        ```

        ```steps
        {built} Parser · fast path
        {todo} Docs
        ```

        > [!warning]
        > Back up first.
        """

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<DocState>(state: DocState(), viewport: Vec2(640, 1400), pixelScale: 1.0, systemDark: true) { _, _ in
            col().wFull().gap(16).children([
                Markdown(doc)
                    .onLink { st, url, _ in st.chosenLink = url }
                    .onTask { st, _, _, checked, _ in st.toggledTask = checked }
                    .build(kit)
                    .key("doc"),
                kit.note(noteSrc, key: "note"),
                Markdown("```mermaid\ngraph TD\n  A[Start] --> B[Stop]\n```\n")
                    .build(kit)
                    .key("diag"),
            ])
        }
        _ = rt.frame(at: 0.0)
        let els = rt.elements()

        // Headings + levels
        let headings = els.filter { $0.role == .heading }
        #expect(headings.count == 2)
        #expect(headings[0].text == "Release notes" && headings[0].level == 1)
        #expect(headings[1].text == "Changes" && headings[1].level == 2)

        // Interactive task checkboxes
        let boxes = els.filter { $0.role == .checkbox }
        #expect(boxes.count == 2)
        #expect(boxes[0].label == "tests pass" && boxes[0].selected == "true")
        #expect(boxes[1].label == "docs" && boxes[1].selected == "false" && boxes[1].focusable)

        // Notes facts, steps, callout groups & list items
        let factsGroup = els.first(where: { $0.key == "note/p0" })
        let fact0 = els.first(where: { $0.key == "note/p0-fact-0" })
        let fact1 = els.first(where: { $0.key == "note/p0-fact-1" })
        #expect(factsGroup?.role == .group && factsGroup?.label == "facts")
        #expect(fact0?.role == .listItem && fact0?.label == "Status: done shipped")
        #expect(fact1?.role == .listItem && fact1?.label == "Owner: Ada")

        let stepsGroup = els.first(where: { $0.key == "note/p1" })
        let step0 = els.first(where: { $0.key == "note/p1-step-0" })
        #expect(stepsGroup?.role == .group && stepsGroup?.label == "1 of 2 built")
        #expect(step0?.role == .listItem && step0?.label == "Parser, built, fast path")

        let callout = els.first(where: { $0.key == "note/p2" })
        #expect(callout?.role == .group && callout?.label == "warning")
        #expect(els.contains(where: { ($0.text ?? "").contains("Back up first.") }))

        // Verify positionInSet & a11yHidden no-echo parity on Notes elements
        let noteEl: El<DocState> = kit.note(noteSrc, key: "note")
        func findEl(_ node: El<DocState>, key: String) -> El<DocState>? {
            if node.keyId == key { return node }
            for ch in node.children {
                if let hit = findEl(ch, key: key) { return hit }
            }
            return nil
        }
        #expect(findEl(noteEl, key: "note/p0-fact-0")?.a11yPosInSet?.position == 1)
        #expect(findEl(noteEl, key: "note/p0-fact-0")?.a11yPosInSet?.size == 2)
        #expect(findEl(noteEl, key: "note/p0-fact-1")?.a11yPosInSet?.position == 2)
        #expect(findEl(noteEl, key: "note/p0-fact-1")?.a11yPosInSet?.size == 2)
        #expect(findEl(noteEl, key: "note/p1-step-0")?.a11yPosInSet?.position == 1)
        #expect(findEl(noteEl, key: "note/p1-step-0")?.a11yPosInSet?.size == 2)
        if let tree = projectAccessibility(noteEl) {
            let labels = collectA11yLabels(tree)
            #expect(labels.contains("Status: done shipped"))
            #expect(!labels.contains("STATUS") && !labels.contains("WARNING"))
            #expect(!labels.contains("done"))
        } else {
            Issue.record("Expected AccessibilityNode for note")
        }

        // Mermaid diagram figure label
        #expect(els.contains(where: { $0.label == "Flowchart" }))

        // Clicking unchecked task triggers callback
        if let r = boxes[1].rect as [Float]? {
            let hit = Vec2(r[0] + 8, r[1] + r[3] * 0.5)
            rt.pointerMove(to: hit, at: 0.01)
            rt.pointerDown(at: hit, at: 0.01)
            rt.pointerUp(at: hit, at: 0.01)
            _ = rt.frame(at: 0.02)
            #expect(rt.state.toggledTask == true)
        }
    }

    @Test("tests/button_label.rs: 120-frame rolling spring smoothness, constant icon offset, and neighbour gap invariant (#193-#194)")
    func buttonLabel120FrameRollingSmoothness() {
        let kit = Kit.neutral(dark: false)
        let copyIcon = SVGIcon(viewBox: 16, paths: ["M3 3h10v10H3z"])

        let rt = Runtime<String>(
            state: "Copy",
            viewport: Vec2(480, 120),
            view: { label, _ in
                row().key("bar").p(12).gap(8).itemsCenter()
                    .child(
                        kit.actionButton(
                            key: "roll-btn",
                            label: .rolling(key: "roll-lbl", text: label),
                            leadingIcon: copyIcon,
                            onClick: { _, _ in }
                        )
                    )
                    .child(
                        kit.actionButton(
                            key: "after-btn",
                            label: .text("Share"),
                            onClick: { _, _ in }
                        )
                        .animateLayout(LayoutAnim.widthLeads(kit.motion.control))
                    )
            }
        )

        _ = rt.frame(at: 0.0)
        guard let btn0 = rectFor(rt, key: "roll-btn"),
              let after0 = rectFor(rt, key: "after-btn") else {
            Issue.record("Missing initial rolling button elements")
            return
        }
        let icon0 = rt.elements().first(where: {
            !$0.exiting && $0.key == "icon" && $0.rect[0] >= btn0[0] && $0.rect[0] <= btn0[0] + btn0[2]
        })?.rect
        guard let icon0 else {
            Issue.record("Missing initial icon rect")
            return
        }

        let initialWidth = btn0[2]
        let initialIconInset = icon0[0] - btn0[0]
        let initialGap = after0[0] - (btn0[0] + btn0[2])
        #expect(abs(initialGap - 8.0) < 0.5)

        // Trigger label change and sample 120 frames at 60Hz
        rt.update(at: 0.016) { s, _ in
            s = "Copied to clipboard!"
        }
        var widths: [Float] = []
        var maxStep: Float = 0
        var maxGapDrift: Float = 0
        var maxIconDrift: Float = 0

        for frameIdx in 1...120 {
            let t = Double(frameIdx) * (1.0 / 60.0) + 0.016
            _ = rt.frame(at: t)
            guard let b = rectFor(rt, key: "roll-btn"),
                  let a = rectFor(rt, key: "after-btn") else {
                Issue.record("Missing elements on frame \(frameIdx)")
                return
            }
            if let ic = rt.elements().first(where: { !$0.exiting && $0.key == "icon" && $0.rect[0] >= b[0] && $0.rect[0] <= b[0] + b[2] })?.rect {
                maxIconDrift = max(maxIconDrift, abs((ic[0] - b[0]) - initialIconInset))
            }
            maxGapDrift = max(maxGapDrift, abs((a[0] - (b[0] + b[2])) - initialGap))
            if let prev = widths.last {
                maxStep = max(maxStep, abs(b[2] - prev))
            }
            widths.append(b[2])
        }

        let finalWidth = widths.last ?? 0
        #expect(finalWidth > initialWidth + 40)
        #expect(widths.contains(where: { $0 > initialWidth + 5 && $0 < finalWidth - 5 }))
        #expect(maxStep < 18.0)
        #expect(maxGapDrift < 0.5)
        #expect(maxIconDrift < 0.5)

        let a11yBtn = rt.elements().first(where: { !$0.exiting && $0.key == "roll-btn" })
        #expect(a11yBtn?.label == "Copied to clipboard!")
    }
}
