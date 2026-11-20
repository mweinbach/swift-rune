import Foundation
import Testing
@testable import RuneKit
@testable import Rune
import RuneMotion

@Suite("RuneKit Controls & Feedback Upstream Parity Tests")
struct ControlsAndFeedbackTests {
    @Test("Button forced states, variants, activation and AppKit size metrics")
    func buttonStatesAndMetrics() throws {
        let k = Kit.neutral(dark: false)
        let base = Button<Int>(key: "save", "Save").onPress { state, _ in state += 1 }
        let rest = base.build(k)
        #expect(Button<Int>("No handler").build(k).handlers.onClick == nil)
        #expect(rest.layout.height == .points(24))
        #expect(rest.hoverBg == k.c.hover)
        #expect(rest.pressBg == kitPressOver(k.c.hover, k.c.pressed))
        for (size, height, pad, radius, glyph) in [
            (ControlSize.mini, Float(16), Float(8), k.radius.sm, Float(12)),
            (.small, 20, 10, k.radius.sm, 14), (.regular, 24, 12, k.radius.md, 16),
            (.large, 28, 14, k.radius.lg, 16), (.extraLarge, 36, 18, k.radius.xl, 16)
        ] {
            let sized = base.size(size).leadingIcon(k.glyph.copy).build(k)
            #expect(sized.layout.height == .points(height))
            #expect(sized.layout.padding.left == pad)
            #expect(sized.corners == .all(radius))
            #expect(sized.children.first?.iconPayload?.1 == glyph)
        }
        let ghost = base.variant(.ghostMuted)
        let hover = ghost.state(.hover).build(k)
        let pressed = ghost.state(.pressed).build(k)
        #expect(hover.background == k.c.hover)
        #expect(pressed.background == k.c.pressed)
        #expect(hover.hoverBg == nil && pressed.pressBg == nil)
        #expect(ghost.expanded(true).build(k).children.last?.textColor == k.c.textBase)
        let focus = base.disabled().state(.focus).build(k)
        #expect(focus.focusable)
        #expect(focus.focusRingWidth == 2.0)
        #expect(focus.focusRingOffset == 2.0)
        #expect(focus.elOutline == Outline(width: 2.0, offset: 2.0, color: k.c.borderFocus))
        #expect(focus.hoverBg == nil)
        let disabled = base.state(.disabled).disabled(false).build(k).key("off")
        let loading = base.variant(.loading).build(k).key("busy")
        #expect(loading.background == k.c.layer02)
        #expect(loading.shadows.first?.spread == 0.5)
        #expect(base.variant(.outline).build(k).shadows.first?.spread == 1)
        #expect(base.variant(.warning).build(k).children.last?.textColor == k.c.warning.fg)
        #expect(base.variant(.ghostFaint).build(k).children.last?.textColor == k.c.textFaint)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(400, 300)) { _, _ in
            col().child(focus).child(disabled).child(loading)
        }
        _ = rt.frame(at: 0)
        #expect(rt.accessibilityAction("save", .press, at: 0.1))
        for id in ["off", "busy"] {
            let e = try #require(rt.element(byKey: id))
            #expect(e.disabled && !e.focusable)
            #expect(!rt.accessibilityAction(id, .press, at: 0.2))
            let center = Vec2(e.rect[0] + e.rect[2] / 2, e.rect[1] + e.rect[3] / 2)
            rt.pointerDown(at: center, at: 0.3)
            rt.pointerUp(at: center, at: 0.4)
        }
        #expect(rt.state == 1)
    }

    @Test("Toggles and radio groups expose one named control, checked state, descriptions and positions")
    func controlAccessibilityAndSelection() throws {
        let k = Kit.neutral(dark: false)
        let mixed = Checkbox<Int>(checked: false).indeterminate().build(k)
        let mark = try #require(mixed.children.first?.children.first?.iconPayload)
        #expect(mark.0 == k.glyph.check && mark.1 == 10)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(500, 400)) { index, _ in
            col().child(Checkbox<Int>(checked: false).indeterminate(true).label("Sync")
                .description("Pending").build(k, key: "sync"))
                .child(Switch<Int>(checked: true).label("Radio").hideLabel().disabled(true).build(k, key: "switch"))
                .child(RadioGroup<Int>().label("Plan").description("Choose a plan")
                    .item(RadioItem(label: "Free", checked: true).description("Basic"))
                    .build(k, key: "plan"))
                .child(SegmentedControl<Int>(labels: ["List", "Grid", "Other"], selected: index)
                    .label("View").segmentState(2, .disabled)
                    .onPick { value, pick, _ in value = pick }.build(k, key: "view"))
        }
        _ = rt.frame(at: 0)
        func flatten(_ node: AccessibilityNode) -> [AccessibilityNode] { [node] + node.children.flatMap(flatten) }
        let nodes = flatten(rt.accessibilitySnapshot())
        func node(_ label: String) throws -> AccessibilityNode {
            let matches = nodes.filter { $0.label == label }
            #expect(matches.count == 1, "Duplicate \(label) nodes: \(matches.map(\.id))")
            return try #require(matches.first)
        }
        let sync = try node("Sync")
        #expect(sync.toggled == .mixed && sync.help == "Pending" && sync.children.isEmpty)
        let radio = try node("Radio")
        #expect(radio.toggled == .trueState && radio.isDisabled && radio.children.isEmpty)
        let plan = try node("Plan")
        #expect(plan.role == .radiogroup && plan.help == "Choose a plan")
        let free = try node("Free")
        #expect(free.role == .radio && free.toggled == .trueState && free.help == "Basic")
        #expect(free.positionInSet == 0 && free.sizeOfSet == 1 && free.children.isEmpty)
        #expect(try node("View").role == .radiogroup)
        let grid = try node("Grid")
        #expect(grid.role == .radio && grid.toggled == .falseState && grid.children.isEmpty)
        #expect(grid.positionInSet == 1 && grid.sizeOfSet == 3)
        #expect(try node("Other").isDisabled)
        #expect(rt.accessibilityAction("view-segment1", .press, at: 0.1))
        #expect(rt.state == 1)
        _ = rt.frame(at: 0.2)
        #expect(rt.element(byKey: "view-segment1")?.checked == .trueState)
        #expect(!rt.accessibilityAction("view-segment2", .press, at: 0.3))
    }

    @Test("An explicit state can re-enable an accordion or disclosure trigger")
    func disclosureStateOverridesDisabled() throws {
        let k = Kit.neutral(dark: false)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(500, 400)) { _, _ in
            col().child(Collapsible<Int>("Expand").disabled().state(.rest)
                    .onToggle { $0 += 1 }.build(k))
                .child(Accordion<Int>().item(AccordionSection<Int>("Details").disabled().state(.hover)
                    .onToggle { $0 += 2 }).build(k))
        }
        _ = rt.frame(at: 0)
        for label in ["Expand", "Details"] {
            let trigger = try #require(rt.elements().first { $0.role == .button && $0.label == label })
            #expect(rt.accessibilityAction(trigger.path, .press, at: 0.1))
        }
        #expect(rt.state == 3)
    }

    @Test("Switch compact sizes, web/standard modes, hover/pressed thumb stretch, hidden label, and toggle")
    func switchModesSizesAndToggle() {
        struct State {
            var on = false
            var toggles = 0
        }

        let kit = Kit.neutral(dark: false)
        let rt = Runtime<State>(state: State(), viewport: Vec2(420, 320)) { s, _ in
            col().gap(10).p(12)
                .child(
                    Switch<State>(checked: s.on)
                        .label("Notifications")
                        .description("Email updates")
                        .controlSize(.regular)
                        .onToggle { st in
                            st.on.toggle()
                            st.toggles += 1
                        }
                        .build(kit, key: "sw-main")
                )
                .child(
                    Switch<State>(checked: true)
                        .label("Hidden")
                        .hideLabel()
                        .web()
                        .state(.hover)
                        .build(kit, key: "sw-web")
                )
                .child(
                    Switch<State>(checked: false)
                        .standard()
                        .state(.pressed)
                        .build(kit, key: "sw-std")
                )
                .child(
                    Switch<State>(checked: false)
                        .label("Disabled")
                        .disabled(true)
                        .onToggle { st in st.toggles += 10 }
                        .build(kit, key: "sw-dis")
                )
        }

        _ = rt.frame(at: 0)
        // Regular compact switch track = 54x24, thumb = 32x20 at inset 2
        let mainCtrl = rt.element(byKey: "sw-main-control")!.rect
        #expect(mainCtrl[2] == 54)
        #expect(mainCtrl[3] == 24)
        let mainThumbOff = rt.element(byKey: "sw-main-thumb")!.rect
        #expect(mainThumbOff[2] == 32)
        #expect(mainThumbOff[3] == 20)

        // Web hover track = 24x16, stretched thumb = 13x12
        let webCtrl = rt.element(byKey: "sw-web-control")!.rect
        #expect(webCtrl[2] == 24)
        #expect(webCtrl[3] == 16)
        let webThumb = rt.element(byKey: "sw-web-thumb")!.rect
        #expect(webThumb[2] == 13)
        #expect(webThumb[3] == 12)
        #expect(rt.element(byKey: "sw-web-label") == nil)

        // Standard pressed off thumb = 20x16 inside 28x16 track
        let stdCtrl = rt.element(byKey: "sw-std-control")!.rect
        #expect(stdCtrl[2] == 28)
        #expect(stdCtrl[3] == 16)
        let stdThumb = rt.element(byKey: "sw-std-thumb")!.rect
        #expect(stdThumb[2] == 20)
        #expect(stdThumb[3] == 16)

        // Click directly on the active switch track -> toggles
        let swPt = Vec2(mainCtrl[0] + mainCtrl[2] * 0.5, mainCtrl[1] + mainCtrl[3] * 0.5)
        rt.pointerDown(at: swPt, at: 0.1)
        rt.pointerUp(at: swPt, at: 0.15)
        #expect(rt.state.on == true)
        #expect(rt.state.toggles == 1)

        // Click disabled switch -> inert
        let disRect = rt.element(byKey: "sw-dis")!.rect
        let disPt = Vec2(disRect[0] + disRect[2] * 0.5, disRect[1] + disRect[3] * 0.5)
        rt.pointerDown(at: disPt, at: 0.2)
        rt.pointerUp(at: disPt, at: 0.25)
        #expect(rt.state.toggles == 1)
    }

    @Test("Checkbox checked, indeterminate, custom icon, hidden label, disabled, and click")
    func checkboxParity() {
        struct State {
            var checked = false
            var count = 0
        }

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<State>(state: State(), viewport: Vec2(360, 260)) { s, _ in
            col().gap(8).p(12)
                .child(
                    Checkbox<State>(checked: s.checked)
                        .label("Accept terms")
                        .description("Required to continue")
                        .onToggle { st in
                            st.checked.toggle()
                            st.count += 1
                        }
                        .build(kit, key: "cb-main")
                )
                .child(
                    Checkbox<State>(checked: false)
                        .indeterminate(true)
                        .icon(KitIcons.plus)
                        .hideLabel()
                        .label("Select all")
                        .build(kit, key: "cb-mix")
                )
                .child(
                    Checkbox<State>(checked: true)
                        .label("Locked")
                        .disabled(true)
                        .onToggle { st in st.count += 10 }
                        .build(kit, key: "cb-dis")
                )
        }

        _ = rt.frame(at: 0)
        #expect(rt.element(byKey: "cb-main-control")!.rect[2] == 16)
        #expect(rt.element(byKey: "cb-main-control")!.rect[3] == 16)
        #expect(rt.element(byKey: "cb-main-label") != nil)
        #expect(rt.element(byKey: "cb-main-description") != nil)
        #expect(rt.element(byKey: "cb-mix-label") == nil)
        #expect(rt.element(byKey: "cb-mix-mark") != nil)

        let cbRect = rt.element(byKey: "cb-main-control")!.rect
        let pt = Vec2(cbRect[0] + cbRect[2] * 0.5, cbRect[1] + cbRect[3] * 0.5)
        rt.pointerDown(at: pt, at: 0.1)
        rt.pointerUp(at: pt, at: 0.15)
        #expect(rt.state.checked == true)
        #expect(rt.state.count == 1)

        let disRect = rt.element(byKey: "cb-dis")!.rect
        let disPt = Vec2(disRect[0] + disRect[2] * 0.5, disRect[1] + disRect[3] * 0.5)
        rt.pointerDown(at: disPt, at: 0.2)
        rt.pointerUp(at: disPt, at: 0.25)
        #expect(rt.state.count == 1)
    }

    @Test("RadioItem and RadioGroup selection, descriptions, invalid, and disabled propagation")
    func radioGroupParity() {
        struct State {
            var choice = 0
        }

        let kit = Kit.neutral(dark: false)
        let rt = Runtime<State>(state: State(), viewport: Vec2(360, 320)) { s, _ in
            col().gap(12).p(12)
                .child(
                    RadioGroup<State>()
                        .label("Plan")
                        .description("Billed monthly")
                        .invalid(s.choice == 0)
                        .item(
                            RadioItem(label: "Free", checked: s.choice == 0)
                                .description("Basic quota")
                                .onSelect { st in st.choice = 0 }
                        )
                        .item(
                            RadioItem(label: "Pro", checked: s.choice == 1)
                                .onSelect { st in st.choice = 1 }
                        )
                        .build(kit, key: "rg")
                )
                .child(
                    RadioGroup<State>()
                        .disabled(true)
                        .item(
                            RadioItem(label: "Locked", checked: true)
                                .onSelect { st in st.choice = 99 }
                        )
                        .build(kit, key: "rg-dis")
                )
        }

        _ = rt.frame(at: 0)
        #expect(rt.element(byKey: "rg-label") != nil)
        #expect(rt.element(byKey: "rg-description") != nil)
        #expect(rt.element(byKey: "rg-item0-dot") != nil)
        #expect(rt.element(byKey: "rg-item1-dot") == nil)

        let item1 = rt.element(byKey: "rg-item1")!.rect
        let pt = Vec2(item1[0] + item1[2] * 0.5, item1[1] + item1[3] * 0.5)
        rt.pointerDown(at: pt, at: 0.1)
        rt.pointerUp(at: pt, at: 0.15)
        #expect(rt.state.choice == 1)

        _ = rt.frame(at: 0.2)
        #expect(rt.element(byKey: "rg-item1-dot") != nil)
        #expect(rt.element(byKey: "rg-item0-dot") == nil)

        // Disabled group ignores clicks
        let disItem = rt.element(byKey: "rg-dis-item0")!.rect
        let disPt = Vec2(disItem[0] + disItem[2] * 0.5, disItem[1] + disItem[3] * 0.5)
        rt.pointerDown(at: disPt, at: 0.3)
        rt.pointerUp(at: disPt, at: 0.35)
        #expect(rt.state.choice == 1)
    }

    @Test("SegmentedControl supports fixed points width, fill width, fit equal columns, and pick handler")
    func segmentedControlParity() {
        struct State {
            var picked = 0
        }

        let kit = Kit.neutral(dark: true)
        let rt = Runtime<State>(state: State(), viewport: Vec2(460, 260)) { s, _ in
            col().wFull().gap(12).p(16)
                .child(
                    SegmentedControl<State>(labels: ["Code", "Preview", "Diff"], selected: s.picked)
                        .label("View")
                        .width(240)
                        .segmentState(2, .disabled)
                        .onPick { st, idx, _ in st.picked = idx }
                        .build(kit, key: "seg-pts")
                )
                .child(
                    SegmentedControl<State>(labels: ["Short", "Longer Label"], selected: 1)
                        .fit()
                        .build(kit, key: "seg-fit")
                )
                .child(
                    SegmentedControl<State>(labels: ["A", "B"], selected: 0)
                        .width(nil)
                        .build(kit, key: "seg-fill")
                )
        }

        _ = rt.frame(at: 0)
        #expect(rt.element(byKey: "seg-pts")!.rect[2] == 240)
        #expect(rt.element(byKey: "seg-pts-indicator")!.rect[2] == 80)
        #expect(rt.element(byKey: "seg-pts-indicator")!.rect[0] == 16) // 16 padding + 0

        let fit0 = rt.element(byKey: "seg-fit-segment0")!.rect[2]
        let fit1 = rt.element(byKey: "seg-fit-segment1")!.rect[2]
        #expect(abs(fit0 - fit1) < 1e-3)
        #expect(rt.element(byKey: "seg-fill")!.rect[2] == 428)

        // Click segment 1 -> moves selection
        let seg1 = rt.element(byKey: "seg-pts-segment1")!.rect
        let pt1 = Vec2(seg1[0] + seg1[2] * 0.5, seg1[1] + seg1[3] * 0.5)
        rt.pointerDown(at: pt1, at: 0.1)
        rt.pointerUp(at: pt1, at: 0.15)
        #expect(rt.state.picked == 1)

        // Click disabled segment 2 -> inert
        let seg2 = rt.element(byKey: "seg-pts-segment2")!.rect
        let pt2 = Vec2(seg2[0] + seg2[2] * 0.5, seg2[1] + seg2[3] * 0.5)
        rt.pointerDown(at: pt2, at: 0.2)
        rt.pointerUp(at: pt2, at: 0.25)
        #expect(rt.state.picked == 1)
    }

    @Test("Feedback builders: Spinner, Loader, Progress, and quantized ProgressCircle")
    func feedbackBuildersParity() {
        #expect(RadarGrid.dots.count == 25)
        let centerDot = RadarGrid.dots[12]
        #expect(centerDot.isCenter)
        #expect(centerDot.cycle == nil)
        #expect(abs(centerDot.stillOpacity - 0.64) < 0.01)

        let outerDot = RadarGrid.dots[0]
        #expect(outerDot.cycle?.fps == 60.0)
        let sampled = RadarGrid.phaseOpacity(dot: outerDot, at: 0.45)
        #expect(sampled >= 0.19 && sampled <= 1.01)

        // Quantized arc icons at 0%, 50%, 100%
        #expect(ProgressCircle<Int>.arcIcon(for: 0).paths.isEmpty)
        let halfArc = ProgressCircle<Int>.arcIcon(for: 0.5)
        #expect(halfArc.paths.count == 1)
        #expect(halfArc.paths[0].contains(" 0 1 8.000 14.000"))
        #expect(ProgressCircle<Int>.arcIcon(for: 1.0) == Loader<Int>.ringIcon)

        let kit = Kit.neutral(dark: false)
        let rt = Runtime<Int>(state: 0, viewport: Vec2(400, 300)) { _, _ in
            col().gap(10).p(16)
                .child(Spinner<Int>().size(18).build(kit, key: "sp"))
                .child(Loader<Int>().size(16).build(kit, key: "ld"))
                .child(Progress<Int>(value: 0.6).label("Sync").showValue().build(kit, key: "pr-det"))
                .child(Progress<Int>(value: nil).label("Waiting").build(kit, key: "pr-ind"))
                .child(ProgressCircle<Int>(value: 0.75).size(20).label("Upload").build(kit, key: "pc"))
        }

        let scene = rt.frame(at: 0)
        #expect(!scene.primitives.isEmpty)
        #expect(rt.element(byKey: "sp-d12") != nil)
        #expect(rt.element(byKey: "ld-ring") != nil)
        #expect(rt.element(byKey: "ld-arc") != nil)
        #expect(rt.element(byKey: "pr-det-track")!.rect[3] == 8)
        #expect(rt.element(byKey: "pr-det-value") != nil)
        #expect(abs(rt.element(byKey: "pr-ind-fill")!.rect[2] / rt.element(byKey: "pr-ind-track")!.rect[2] - 0.25) < 0.02)
        #expect(rt.element(byKey: "pc")!.rect[2] == 20)
    }

    @Test("§2 #399: Switch lays out exact switchMetrics track sizes for all 5 ControlSize cases")
    func switchAllControlSizesParity() {
        let kit = Kit.neutral(dark: true)
        let expected: [(ControlSize, Float, Float)] = [
            (.mini, 36, 16),
            (.small, 44, 20),
            (.regular, 54, 24),
            (.large, 64, 28),
            (.extraLarge, 80, 36),
        ]
        let rt = Runtime<Int>(state: 0, viewport: Vec2(320, 400)) { _, _ in
            var c: El<Int> = col().gap(8).p(12)
            for (sz, _, _) in expected {
                c = c.child(Switch<Int>(checked: true).controlSize(sz).label("Mode").build(kit, key: "sw-\(sz)"))
            }
            return c
        }
        _ = rt.frame(at: 0)
        for (sz, w, h) in expected {
            let rect = rt.element(byKey: "sw-\(sz)-control")!.rect
            #expect(abs(rect[2] - w) < 0.01)
            #expect(abs(rect[3] - h) < 0.01)
        }
    }

    @Test("#1296: unified keyboard focus rings across buttons, toggles, radios, segments, inputs, select, collapsible and tab strip")
    func unifiedKeyboardFocusRings() throws {
        struct S {
            var edit = TextEdit("hello")
        }
        let k = Kit.neutral(dark: true)
        let focusOutlineOut = Outline(width: 2.0, offset: 2.0, color: k.c.borderFocus)
        let focusOutlineIn = Outline(width: 2.0, offset: -2.0, color: k.c.borderFocus)

        func findKey<T>(_ root: El<T>, _ key: String) -> El<T>? {
            if root.keyId == key { return root }
            for child in root.children {
                if let hit = findKey(child, key) { return hit }
            }
            return nil
        }

        // 1. Button & IconButton: 2pt ring, 2pt out.
        let btn = Button<S>(key: "btn", "Save").state(.focus).build(k)
        #expect(btn.focusRingWidth == 2.0 && btn.focusRingOffset == 2.0 && btn.focusRingColor == k.c.borderFocus)
        #expect(btn.elOutline == focusOutlineOut)

        let iconBtn = IconButton<S>(key: "ibtn", svg: k.glyph.copy).label("Copy").state(.focus).build(k)
        #expect(iconBtn.focusRingWidth == 2.0 && iconBtn.focusRingOffset == 2.0 && iconBtn.focusRingColor == k.c.borderFocus)
        #expect(iconBtn.elOutline == focusOutlineOut)

        // 2. Collapsible trigger: radius 4, 2pt ring 2pt out.
        let collapsible = Collapsible<S>("Details").build(k)
        let colTrigger = try #require(findKey(collapsible, "trigger"))
        #expect(colTrigger.corners == .all(4.0))
        #expect(colTrigger.focusRingWidth == 2.0 && colTrigger.focusRingOffset == 2.0 && colTrigger.focusRingColor == k.c.borderFocus)

        // 3. Checkbox: no focus border override; control carries 2pt ring 2pt out; root leaves focusRingColor nil.
        let cbRest = Checkbox<S>(checked: false).label("Check").build(k, key: "cb")
        let cbFocus = Checkbox<S>(checked: false).label("Check").state(.focus).build(k, key: "cb")
        let cbCheckedFocus = Checkbox<S>(checked: true).label("Check").state(.focus).build(k, key: "cb")
        let cbRestCtrl = try #require(findKey(cbRest, "cb-control"))
        let cbFocusCtrl = try #require(findKey(cbFocus, "cb-control"))
        let cbCheckedCtrl = try #require(findKey(cbCheckedFocus, "cb-control"))
        #expect(cbRest.focusRingColor == nil && cbFocus.focusRingColor == nil)
        #expect(cbFocusCtrl.borderColor == cbRestCtrl.borderColor)
        #expect(cbFocusCtrl.borderColor == k.c.borderWeak)
        #expect(cbCheckedCtrl.borderColor == k.c.stdBorder)
        #expect(cbRestCtrl.focusRingWidth == 2.0 && cbRestCtrl.focusRingOffset == 2.0 && cbRestCtrl.focusRingColor == k.c.borderFocus)
        #expect(cbRestCtrl.elOutline == nil)
        #expect(cbFocusCtrl.elOutline == focusOutlineOut)

        // 4. RadioItem: control carries 2pt ring 2pt out; root leaves focusRingColor nil.
        let radio = RadioItem<S>(label: "Option", checked: false).state(.focus).build(k, key: "rd")
        let radioCtrl = try #require(findKey(radio, "rd-control"))
        #expect(radio.focusRingColor == nil)
        #expect(radioCtrl.focusRingWidth == 2.0 && radioCtrl.focusRingOffset == 2.0 && radioCtrl.focusRingColor == k.c.borderFocus)
        #expect(radioCtrl.elOutline == focusOutlineOut)

        // 5. Switch (compact, web, AND standard): control carries 2pt ring 2pt out; root leaves focusRingColor nil.
        for sw in [
            Switch<S>(checked: false).label("Compact").state(.focus).build(k, key: "sw"),
            Switch<S>(checked: false).label("Web").web().state(.focus).build(k, key: "sw"),
            Switch<S>(checked: true).label("Standard").standard().state(.focus).build(k, key: "sw"),
        ] {
            let swCtrl = try #require(findKey(sw, "sw-control"))
            #expect(sw.focusRingColor == nil)
            #expect(swCtrl.focusRingWidth == 2.0 && swCtrl.focusRingOffset == 2.0 && swCtrl.focusRingColor == k.c.borderFocus)
            #expect(swCtrl.elOutline == focusOutlineOut)
        }

        // 6. SegmentedControl: segments ring 2pt inside (-2.0).
        let seg = SegmentedControl<S>(labels: ["A", "B"], selected: 0).segmentState(1, .focus).build(k, key: "seg")
        let seg0 = try #require(findKey(seg, "seg-segment0"))
        let seg1 = try #require(findKey(seg, "seg-segment1"))
        #expect(seg0.focusRingWidth == 2.0 && seg0.focusRingOffset == -2.0 && seg0.focusRingColor == k.c.borderFocus)
        #expect(seg0.elOutline == nil)
        #expect(seg1.focusRingWidth == 2.0 && seg1.focusRingOffset == -2.0 && seg1.focusRingColor == k.c.borderFocus)
        #expect(seg1.elOutline == focusOutlineIn)

        // 7. TextInput copy and clear buttons: ring 2pt inside (-2.0).
        let tiCopy = TextInput<S>(key: "ti", \.edit).copyButton().build(k)
        let copyAction = try #require(findKey(tiCopy, "ti-action"))
        #expect(copyAction.focusRingWidth == 2.0 && copyAction.focusRingOffset == -2.0 && copyAction.focusRingColor == k.c.borderFocus)
        let tiClear = TextInput<S>(key: "tic", \.edit).clearButton().build(k)
        let clearAction = try #require(findKey(tiClear, "tic-action"))
        #expect(clearAction.focusRingWidth == 2.0 && clearAction.focusRingOffset == -2.0 && clearAction.focusRingColor == k.c.borderFocus)

        // 8. Select inline trigger: closed rings 2pt out, open suppresses focus ring.
        var layerClosed: [El<S>] = []
        let selClosed = Select<S>("sel", options: ["One"])
            .appearance(.inline)
            .state(.focus)
            .open(false)
            .build(kit: k, layer: &layerClosed)
        #expect(!selClosed.noFocusRing)
        #expect(selClosed.focusRingWidth == 2.0 && selClosed.focusRingOffset == 2.0 && selClosed.focusRingColor == k.c.borderFocus)
        #expect(selClosed.elOutline == focusOutlineOut)

        var layerOpen: [El<S>] = []
        let selOpen = Select<S>("sel", options: ["One"])
            .appearance(.inline)
            .state(.focus)
            .open(true)
            .build(kit: k, layer: &layerOpen)
        #expect(selOpen.noFocusRing)
        #expect(selOpen.elOutline == nil)

        // 9. TabStrip tab pill: rings 2pt inside (-2.0).
        let strip = TabStrip<S>(
            key: "tabs",
            tabs: [
                StripTabItem(id: "a", title: "Alpha"),
                StripTabItem(id: "b", title: "Beta"),
            ],
            selected: "a"
        ).build(S(), kit: k)
        let pillA = try #require(findKey(strip, "tabs-tab-a"))
        #expect(pillA.focusRingWidth == 2.0 && pillA.focusRingOffset == -2.0 && pillA.focusRingColor == k.c.borderFocus)
    }
}
