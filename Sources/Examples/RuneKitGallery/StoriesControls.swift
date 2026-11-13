import Foundation
import OpenCodeTheme
import Rune
import RuneKit

// MARK: - Buttons & Icon Buttons (Phase 2 @kitc/@kitw: warning/contrast/submit/ghostMuted/loading & forced WidgetState)

func buttonPlayground(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(k.button(key: "btn-play", "Button", variant: .neutral) { st, _ in st.flip("btn-play") })
}

func buttonVariants(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    galleryFlex(12)
        .child(k.button(key: "bv-neutral", "Neutral", variant: .neutral) { _, _ in })
        .child(k.button(key: "bv-danger", "Danger", variant: .danger) { _, _ in })
        .child(k.button(key: "bv-warning", "Warning", variant: .accent) { _, _ in })
        .child(k.button(key: "bv-contrast", "Contrast", variant: .primary) { _, _ in })
        .child(k.button(key: "bv-submit", "Submit", variant: .accent) { _, _ in })
        .child(k.button(key: "bv-ghost", "Ghost", variant: .ghost) { _, _ in })
}

func buttonSizes(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().gap(12).itemsCenter()
        .child(k.button(key: "bs-mini", "Mini", variant: .neutral, size: .sm) { _, _ in })
        .child(k.button(key: "bs-small", "Small", variant: .neutral, size: .sm) { _, _ in })
        .child(k.button(key: "bs-regular", "Regular", variant: .neutral, size: .md) { _, _ in })
        .child(k.button(key: "bs-large", "Large", variant: .neutral, size: .lg) { _, _ in })
        .child(k.button(key: "bs-xl", "Extra large", variant: .neutral, size: .lg) { _, _ in })
}

func buttonIcon(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(
        k.button(key: "btn-icon", "Add item", variant: .neutral, leadingIcon: KitIcons.plus) { _, _ in }
    )
}

func buttonAllStates(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let variants: [(String, ButtonVariant)] = [
        ("neutral", .neutral), ("danger", .danger), ("contrast", .primary), ("submit", .accent), ("ghost", .ghost),
    ]
    let states = ["default", "hover", "pressed", "focus", "disabled"]
    var gridCol: El<GalleryState> = col().gap(12)
    for (vName, variant) in variants {
        var r: El<GalleryState> = galleryFlex(12)
            .child(galleryCaption(k, vName).w(72))
        for stName in states {
            r = r.child(
                k.button(
                    key: "bas-\(vName)-\(stName)",
                    stName,
                    variant: variant,
                    disabled: stName == "disabled"
                ) { _, _ in }
            )
        }
        gridCol = gridCol.child(r)
    }
    return gridCol
}

func iconButtonPlayground(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(k.iconButton(key: "ib-play", svg: KitIcons.plus, label: "Add", variant: .neutral) { _, _ in })
}

func iconButtonVariants(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    galleryFlex(12)
        .child(k.iconButton(key: "ibv-neutral", svg: KitIcons.plus, label: "Neutral", variant: .neutral) { _, _ in })
        .child(k.iconButton(key: "ibv-danger", svg: KitIcons.plus, label: "Danger", variant: .danger) { _, _ in })
        .child(k.iconButton(key: "ibv-contrast", svg: KitIcons.plus, label: "Contrast", variant: .primary) { _, _ in })
        .child(k.iconButton(key: "ibv-submit", svg: KitIcons.plus, label: "Submit", variant: .accent) { _, _ in })
        .child(k.iconButton(key: "ibv-ghost", svg: KitIcons.plus, label: "Ghost", variant: .ghost) { _, _ in })
}

func iconButtonSizes(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().gap(12).itemsCenter()
        .child(k.iconButton(key: "ibs-sm", svg: KitIcons.plus, label: "Small", size: .sm, variant: .neutral) { _, _ in })
        .child(k.iconButton(key: "ibs-md", svg: KitIcons.plus, label: "Regular", size: .md, variant: .neutral) { _, _ in })
        .child(k.iconButton(key: "ibs-lg", svg: KitIcons.plus, label: "Large", size: .lg, variant: .neutral) { _, _ in })
}

func iconButtonAllStates(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let variants: [(String, ButtonVariant)] = [("neutral", .neutral), ("ghost", .ghost), ("danger", .danger)]
    let states = ["default", "hover", "pressed", "focus", "disabled"]
    var c: El<GalleryState> = col().gap(12)
    for (vName, variant) in variants {
        var r: El<GalleryState> = galleryFlex(12).child(galleryCaption(k, vName).w(72))
        for stName in states {
            r = r.child(
                k.iconButton(
                    key: "ibas-\(vName)-\(stName)",
                    svg: KitIcons.plus,
                    label: stName,
                    variant: variant,
                    disabled: stName == "disabled"
                ) { _, _ in }
            )
        }
        c = c.child(r)
    }
    return c
}

// MARK: - Switches, Checkboxes, Radios

private func onByDefault(_ s: GalleryState, _ key: String) -> Bool {
    !s.is(key)
}

func switchBasic(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().gap(8).itemsCenter()
        .child(k.switchControl(key: "sw", isOn: onByDefault(s, "sw"), label: "Enable notifications") { st, _ in st.flip("sw") })
        .child(text("Enable notifications").font(k.ty.ui).color(k.c.textBase))
}

func switchAppearances(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    col().gap(12)
        .child(row().gap(8).itemsCenter().child(k.switchControl(key: "std", isOn: onByDefault(s, "std"), label: "Standard") { st, _ in st.flip("std") }).child(text("Standard").font(k.ty.ui).color(k.c.textBase)))
        .child(row().gap(8).itemsCenter().child(k.switchControl(key: "cmp", isOn: onByDefault(s, "cmp"), label: "Compact") { st, _ in st.flip("cmp") }).child(text("Compact").font(k.ty.ui).color(k.c.textBase)))
}

func switchStates(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    col().gap(12)
        .child(row().gap(8).itemsCenter().child(k.switchControl(key: "a", isOn: onByDefault(s, "a"), label: "Enabled") { st, _ in st.flip("a") }).child(text("Enabled").font(k.ty.ui).color(k.c.textBase)))
        .child(row().gap(8).itemsCenter().child(k.switchControl(key: "b", isOn: s.is("b"), label: "Disabled") { st, _ in st.flip("b") }).child(text("Disabled").font(k.ty.ui).color(k.c.textBase)))
        .child(row().gap(8).itemsCenter().child(k.switchControl(key: "c", isOn: false, label: "Disabled switch", disabled: true) { _, _ in }).child(text("Disabled switch").font(k.ty.ui).color(k.c.textMuted)))
}

func switchSizes(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let names = ["Mini", "Small", "Regular", "Large", "Extra large"]
    var c: El<GalleryState> = col().gap(12)
    for name in names {
        let key = "size-\(name)"
        c = c.child(
            row().gap(12).itemsCenter()
                .child(galleryCaption(k, name).w(80))
                .child(k.switchControl(key: key, isOn: s.is(key), label: name) { st, _ in st.flip(key) })
                .child(k.switchControl(key: "\(key)-on", isOn: true) { _, _ in })
                .child(k.switchControl(key: "\(key)-off", isOn: false) { _, _ in })
        )
    }
    return c
}

func switchWeb(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let states = ["Rest", "Hover", "Focus", "Disabled"]
    var c: El<GalleryState> = col().gap(12)
        .child(
            row().gap(12).itemsCenter()
                .child(galleryCaption(k, "Live").w(80))
                .child(k.switchControl(key: "web-live", isOn: s.is("web"), label: "Web") { st, _ in st.flip("web") })
        )
    for name in states {
        let dis = name == "Disabled"
        c = c.child(
            row().gap(16).itemsCenter()
                .child(galleryCaption(k, name).w(80))
                .child(k.switchControl(key: "web-\(name)-0", isOn: false, disabled: dis) { _, _ in })
                .child(k.switchControl(key: "web-\(name)-1", isOn: true, disabled: dis) { _, _ in })
        )
    }
    return c
}

func switchHiddenLabel(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(k.switchControl(key: "sw-hidden", isOn: onByDefault(s, "sw"), label: "Hidden label") { st, _ in st.flip("sw") })
}

func checkboxBasic(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(k.checkbox(key: "cb", checked: onByDefault(s, "cb"), label: "Checkbox") { st, _ in st.flip("cb") })
}

func checkboxStates(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    col().gap(12)
        .child(k.checkbox(key: "cb-a", checked: onByDefault(s, "a"), label: "Checked") { st, _ in st.flip("a") })
        .child(k.checkbox(key: "cb-b", checked: s.is("b"), label: "Unchecked") { st, _ in st.flip("b") })
        .child(k.checkbox(key: "cb-dis", checked: false, label: "Disabled", disabled: true) { _, _ in })
        .child(
            col().gap(2)
                .child(k.checkbox(key: "cb-d", checked: s.is("d"), label: "With description") { st, _ in st.flip("d") })
                .child(text("Helper text").font(k.ty.small).color(k.c.textMuted).pl(26))
        )
}

func checkboxCustomIcon(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(k.checkbox(key: "cb-custom", checked: onByDefault(s, "cb"), label: "Custom icon") { st, _ in st.flip("cb") })
}

func checkboxHiddenLabel(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(k.checkbox(key: "cb-hidden", checked: s.is("cb"), label: nil) { st, _ in st.flip("cb") })
}

func radioBasic(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let cur = s.picked("freq", "daily")
    return col().gap(8)
        .child(text("Notification frequency").font(k.ty.uiMedium).color(k.c.textBase))
        .child(
            k.radioGroup(
                key: "freq",
                options: [(id: "daily", label: "Daily"), (id: "weekly", label: "Weekly"), (id: "never", label: "Never")],
                selected: cur
            ) { st, v in st.pick["freq"] = v }
        )
}

func radioControlled(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let cur = s.picked("ctl", "daily")
    return col().gap(12)
        .child(text("Controlled").font(k.ty.uiMedium).color(k.c.textBase))
        .child(
            k.radioGroup(
                key: "ctl",
                options: [(id: "daily", label: "Daily"), (id: "weekly", label: "Weekly"), (id: "never", label: "Never")],
                selected: cur
            ) { st, v in st.pick["ctl"] = v }
        )
        .child(text("Value: \(cur)").font(TextStyle(size: 12, weight: 440, lineHeight: 24)).color(k.c.textFaint))
}

func radioStates(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    col().gap(20)
        .child(
            col().gap(6)
                .child(text("Default").font(k.ty.uiMedium).color(k.c.textBase))
                .child(
                    k.radioGroup(
                        key: "def",
                        options: [(id: "a", label: "Option A"), (id: "b", label: "Option B")],
                        selected: s.picked("def", "a")
                    ) { st, v in st.pick["def"] = v }
                )
        )
        .child(
            col().gap(6).opacity(0.45).inert(true)
                .child(text("Disabled group").font(k.ty.uiMedium).color(k.c.textBase))
                .child(
                    k.radioGroup(
                        key: "dis-grp",
                        options: [(id: "a", label: "Option A"), (id: "b", label: "Option B")],
                        selected: "a"
                    ) { _, _ in }
                )
        )
        .child(
            col().gap(6)
                .child(text("Invalid").font(k.ty.uiMedium).color(k.c.danger.fg))
                .child(
                    k.radioGroup(
                        key: "inv",
                        options: [(id: "a", label: "Option A"), (id: "b", label: "Option B")],
                        selected: s.picked("inv", "a")
                    ) { st, v in st.pick["inv"] = v }
                )
                .child(text("Pick one option.").font(k.ty.small).color(k.c.danger.fg))
        )
}
