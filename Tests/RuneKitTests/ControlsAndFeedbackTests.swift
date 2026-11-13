import Foundation
import Testing
@testable import RuneKit
@testable import Rune
import RuneMotion

@Suite("RuneKit Controls & Feedback Upstream Parity Tests")
struct ControlsAndFeedbackTests {
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
}
