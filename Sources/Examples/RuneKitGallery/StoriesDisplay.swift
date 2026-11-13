import Foundation
import OpenCodeTheme
import Rune
import RuneKit

// MARK: - Cards, Lists, Accordion, Collapsible

private func galleryCard(
    _ k: Kit,
    key: String,
    accent: Color? = nil,
    iconGlyph: SVGIcon? = nil
) -> El<GalleryState> {
    var titleRow: El<GalleryState> = row().gap(8).itemsCenter()
    if let iconGlyph {
        titleRow = titleRow.child(icon(iconGlyph, size: 16).color(accent ?? k.c.iconBase))
    }
    titleRow = titleRow.child(text("Card title").font(k.ty.uiMedium).color(k.c.textBase))

    let content: El<GalleryState> = row().wFull().itemsCenter().justifyBetween().gap(16)
        .child(
            col().gap(2)
                .child(titleRow)
                .child(text("Small supporting text.").font(k.ty.small).color(k.c.textMuted))
        )
        .child(k.button(key: "\(key)-action", "Action", variant: .neutral, size: .sm) { _, _ in })

    var box = k.card(key: key, content)
    if let accent {
        box = box.border(1, accent.alpha(0.45))
    }
    return box
}

func cardNormal(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    galleryCard(k, key: "card-normal")
}

func cardError(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    galleryCard(k, key: "card-error", accent: k.c.danger.icon, iconGlyph: KitIcons.circleX)
}

func cardWarning(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    galleryCard(k, key: "card-warning", accent: k.c.warning.icon, iconGlyph: KitIcons.info)
}

func cardSuccess(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    galleryCard(k, key: "card-success", accent: k.c.success.icon, iconGlyph: KitIcons.check)
}

func cardInfo(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    galleryCard(k, key: "card-info", accent: k.c.info.icon, iconGlyph: KitIcons.info)
}

private func buildList(
    _ s: GalleryState,
    _ k: Kit,
    key: String,
    items: [String],
    search: Bool,
    divider: Bool = false,
    trailingIcon: SVGIcon? = nil,
    addRow: Bool = false
) -> El<GalleryState> {
    let q = search ? s.edits[3].text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
    let filtered = q.isEmpty ? items : items.filter { $0.lowercased().contains(q) }
    var rows: [El<GalleryState>] = []
    for (idx, item) in filtered.enumerated() {
        let sel = (s.pick[key] ?? items.first) == item
        let trail: El<GalleryState>? = (sel && trailingIcon != nil) ? icon(trailingIcon!, size: 14).color(k.c.iconMuted) : nil
        rows.append(
            k.listItem(key: "\(key)-\(idx)", title: item, trailing: trail, selected: sel) { st, _ in
                st.pick[key] = item
            }
        )
        if divider && idx + 1 < filtered.count {
            rows.append(k.divider())
        }
    }
    if filtered.isEmpty {
        rows.append(row().px(8).py(12).child(text("No items").font(k.ty.small).color(k.c.textFaint)))
    }
    if addRow {
        rows.append(
            row().px(8).py(6)
                .child(text("Add item").font(TextStyle(size: 14, weight: 500, lineHeight: 21)).color(k.c.textBase))
        )
    }

    var root: El<GalleryState> = col().w(280).gap(8)
    if search {
        root = root.child(k.searchField(key: "\(key)-search", \.edits[3], placeholder: "Search…"))
    }
    return root.child(k.list(key: key, items: rows))
}

func listBasic(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    buildList(s, k, key: "list-basic", items: ["One", "Two", "Three", "Four"], search: true)
}

func listGrouped(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let items: [El<GalleryState>] = [
        row().px(8).py(4).child(galleryCaption(k, "Group A")),
        k.listItem(key: "lg-1", title: "Alpha") { st, _ in st.pick["lg"] = "Alpha" },
        k.listItem(key: "lg-2", title: "Bravo") { st, _ in st.pick["lg"] = "Bravo" },
        row().px(8).py(4).child(galleryCaption(k, "Group B")),
        k.listItem(key: "lg-3", title: "Delta") { st, _ in st.pick["lg"] = "Delta" },
    ]
    return col().w(280).gap(8)
        .child(k.searchField(key: "lg-search", \.edits[3], placeholder: "Search…"))
        .child(k.list(key: "list-grouped", items: items))
}

func listEmpty(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    buildList(s, k, key: "list-empty", items: [], search: true)
}

func listWithAdd(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    buildList(s, k, key: "list-add", items: ["One", "Two"], search: true, addRow: true)
}

func listDivider(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    buildList(s, k, key: "list-div", items: ["One", "Two", "Three"], search: false, divider: true)
}

func listActiveIcon(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    buildList(s, k, key: "list-icon", items: ["Alpha", "Beta", "Gamma"], search: false, trailingIcon: KitIcons.chevronRight)
}

func listNoSearch(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    buildList(s, k, key: "list-nosearch", items: ["One", "Two", "Three"], search: false)
}

func accordionBasic(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let open = s.picked("acc", "")
    let expanded: Set<String> = open.isEmpty ? [] : [open]
    let items: [AccordionItem<GalleryState>] = [
        AccordionItem(id: "first", title: "First") {
            row().py(8).child(text("Accordion content.").font(TextStyle(size: 13, weight: 440, lineHeight: 24)).color(k.c.textMuted))
        },
        AccordionItem(id: "second", title: "Second") {
            row().py(8).child(text("More content.").font(TextStyle(size: 13, weight: 440, lineHeight: 24)).color(k.c.textMuted))
        },
    ]
    return col().w(420).child(
        k.accordion(key: "acc-basic", items: items, expanded: expanded) { st, id, isOpen in
            st.pick["acc"] = isOpen ? id : ""
        }
    )
}

func accordionMultiple(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    var expanded: Set<String> = []
    if !s.is("a1") { expanded.insert("a1") }
    if !s.is("a2") { expanded.insert("a2") }
    let items: [AccordionItem<GalleryState>] = [
        AccordionItem(id: "a1", title: "First") { text("Accordion content.").font(k.ty.small).color(k.c.textBase) },
        AccordionItem(id: "a2", title: "Second") { text("More content.").font(k.ty.small).color(k.c.textBase) },
    ]
    return col().w(420).child(
        k.accordion(key: "acc-mult", items: items, expanded: expanded) { st, id, _ in
            st.flip(id)
        }
    )
}

func accordionSingle(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let items: [AccordionItem<GalleryState>] = [
        AccordionItem(id: "s1", title: "First") { text("Accordion content.").font(k.ty.small).color(k.c.textBase) },
    ]
    return col().w(420).child(k.accordion(key: "acc-single", items: items, expanded: []) { _, _, _ in })
}

func collapsibleBasic(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    col().w(360).child(
        k.collapsible(key: "col-basic", title: "Details", isOpen: !s.is("c"), onToggle: { st, _ in st.flip("c") }) {
            row().pt(8).child(text("Optional details sit here.").font(TextStyle(size: 13, weight: 440, lineHeight: 24)).color(k.c.textMuted))
        }
    )
}

func collapsibleGhost(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    col().w(360).child(
        k.collapsible(key: "col-ghost", title: "Ghost trigger", isOpen: s.is("c"), onToggle: { st, _ in st.flip("c") }) {
            row().pt(8).child(text("Ghost content.").font(TextStyle(size: 13, weight: 440, lineHeight: 24)).color(k.c.textMuted))
        }
    )
}

// MARK: - Badges, Keybinds, Spinner, Loader, Progress, SegmentedControl, RollingText, ScrollView

func badgeBasic(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(k.badge("Label", tone: .neutral))
}

func badgeAppearances(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().gap(8).itemsCenter()
        .child(k.badge("Standard", tone: .neutral))
        .child(k.badge("Compact", tone: .neutral))
}

func badgeSubtle(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().gap(8).itemsCenter()
        .child(k.badge("1", tone: .neutral))
        .child(k.badge("12", tone: .neutral))
}

func badgeHighContrast(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().gap(8).itemsCenter()
        .child(k.badge("Label", tone: .neutral))
        .child(k.badge("Label", tone: .info))
}

func badgeAccent(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(k.badge("New", tone: .accent))
}

func keybindPlayground(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(k.keybind(["⌘"]))
}

func keybindVariants(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().gap(24).itemsCenter()
        .child(k.keybind(["⌘"], variant: .subtle))
        .child(k.keybind(["⌘"], variant: .outline))
}

func keybindMultiple(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().gap(24).itemsCenter()
        .child(k.keybind(["⌘", "K"], variant: .subtle))
        .child(k.keybind(["⌘", "K"], variant: .outline))
        .child(k.keybind(["Ctrl", "B"], variant: .subtle))
        .child(k.keybind(["Ctrl", "B"], variant: .outline))
}

func keybindAll(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    func line(_ name: String, _ v: KeybindVariant) -> El<GalleryState> {
        row().gap(24).itemsCenter()
            .child(text(name).w(50).font(TextStyle(size: 11, weight: 440, lineHeight: 24)).color(Color.hex("#808080") ?? k.c.textMuted))
            .child(k.keybind(["⌘"], variant: v))
            .child(k.keybind(["⌘", "K"], variant: v))
            .child(k.keybind(["⌘", "⇧", "P"], variant: v))
            .child(k.keybind(["Ctrl", "Shift", "B"], variant: v))
    }
    return col().gap(16)
        .child(line("Neutral", .subtle))
        .child(line("Ghost", .outline))
}

func keybindSymbols(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let sample = "⌘K ⇧P ⏎ ⌫ ⎋ ⌥⌃ ←↑ HP"
    var c: El<GalleryState> = col().gap(10)
    for mono in [false, true] {
        for size: Float in [13, 15] {
            var style = TextStyle(size: size, weight: 500, lineHeight: size * 1.5)
            if mono { style = style.mono() }
            let label = "\(mono ? "Plex Mono" : "Inter") \(Int(size))"
            c = c.child(
                row().gap(16).itemsCenter()
                    .child(text(label).w(96).font(TextStyle(size: 11, weight: 440, lineHeight: 16)).color(k.c.textFaint))
                    .child(text(sample).font(style).color(k.c.textBase))
            )
        }
        var kk = k
        if mono { kk.ty.smallMedium = kk.ty.smallMedium.mono() }
        var caps: El<GalleryState> = row().gap(12).itemsCenter()
            .child(text(mono ? "Plex Mono caps" : "Inter caps").w(96).font(TextStyle(size: 11, weight: 440, lineHeight: 16)).color(k.c.textFaint))
        for keys in [["⌘", "⇧", "P"], ["⇧", "⏎"], ["⌫"], ["⎋"], ["⌥", "⌃", "K"], ["←", "↑"]] {
            caps = caps.child(kk.keybind(keys))
        }
        c = c.child(caps)
    }
    return c
}

func spinnerBasic(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(k.spinner())
}

func spinnerSizes(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().gap(16).itemsCenter()
        .child(k.spinner(key: "sp-12", size: 12))
        .child(k.spinner(key: "sp-20", size: 20))
        .child(k.spinner(key: "sp-28", size: 28))
}

func loaderBasic(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(k.loader())
}

func loaderSizes(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().gap(16).itemsCenter()
        .child(k.loader(key: "ld-12", size: 12))
        .child(k.loader(key: "ld-16", size: 16))
        .child(k.loader(key: "ld-24", size: 24))
}

func progressBasic(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    col().w(320).gap(6)
        .child(row().wFull().justifyBetween().child(text("Progress").font(k.ty.smallMedium).color(k.c.textBase)).child(text("60%").font(k.ty.small).color(k.c.textMuted)))
        .child(k.progress(key: "p-basic", fraction: 0.6))
}

func progressNoLabel(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    col().w(320).child(k.progress(key: "p-nolabel", fraction: 0.3))
}

func progressIndeterminate(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    col().w(320).gap(6)
        .child(text("Loading").font(k.ty.smallMedium).color(k.c.textBase))
        .child(k.progress(key: "p-indet", fraction: 0.45))
}

func segmentedBasic(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let sel = s.picked("seg", "0")
    return row().child(
        k.segmentedControl(
            key: "seg-basic",
            options: [(id: "0", label: "Label"), (id: "1", label: "Label"), (id: "2", label: "Label"), (id: "3", label: "Label")],
            selected: sel
        ) { st, val in st.pick["seg"] = val }
    )
}

func segmentedControlled(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let sel = s.picked("seg-ctrl", "1")
    let vals = ["0": "a", "1": "b", "2": "c"]
    return col().gap(12).itemsStart()
        .child(text("View").font(k.ty.smallMedium).color(k.c.textBase))
        .child(
            k.segmentedControl(
                key: "seg-controlled",
                options: [(id: "0", label: "List"), (id: "1", label: "Grid"), (id: "2", label: "Board")],
                selected: sel
            ) { st, val in st.pick["seg-ctrl"] = val }
        )
        .child(text("Value: \(vals[sel] ?? "a")").font(TextStyle(size: 12, weight: 440, lineHeight: 24)).color(Color.hex("#808080") ?? k.c.textMuted))
}

func rollingTextBasic(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let step = UInt32(s.picked("roll", "0")) ?? 0
    let label = step == 0 ? "Copy password" : String(format: "Copied, clears in 0:%02d", 31 - min(step, 31))
    let count = String(format: "0:%02d", 30 - min(step, 30))
    let big = TextStyle(size: 28, weight: 600)
    func line(_ name: String, _ e: El<GalleryState>) -> El<GalleryState> {
        row().gap(12).itemsCenter()
            .child(text(name).font(k.ty.small).color(k.c.textFaint).w(56))
            .child(e)
    }
    return col().gap(14)
        .child(
            row().gap(8)
                .child(k.button(key: "roll", "Roll", variant: .neutral) { st, _ in
                    let n = (UInt32(st.picked("roll", "0")) ?? 0) + 1
                    st.pick["roll"] = "\(n)"
                })
                .child(k.button(key: "rolling-button", label, variant: .neutral) { _, _ in })
                .child(k.button(key: "cancel", "Cancel", variant: .neutral) { _, _ in })
        )
        .child(line("Sans", k.rollingText(key: "roll-sans", label, font: k.ty.body, color: k.c.textBase)))
        .child(line("Mono", k.rollingText(key: "roll-mono", label, font: k.ty.mono, color: k.c.textBase)))
        .child(line("Centred", row().w(260).center().child(k.rollingText(key: "roll-centre", label, font: k.ty.body, color: k.c.textBase))))
        .child(line("Count", k.rollingText(key: "count-sans", count, font: big, color: k.c.textBase)))
        .child(line("", k.rollingText(key: "count-mono", count, font: big.mono(), color: k.c.textBase)))
}

func scrollViewThumb(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    var inner: El<GalleryState> = col()
    for i in 1...24 {
        inner = inner.child(
            row().key("row\(i)").h(28).px(12).itemsCenter()
                .child(text("Row \(i)").font(k.ty.uiCompact).color(k.c.textBase))
        )
    }
    return col().key("list").w(240).h(180).rounded(k.radius.md).bg(k.c.bgBase).border(1, k.c.borderBase)
        .scroll()
        .child(inner)
}
