import Foundation
import Rune
import RuneKit

// MARK: - TextInput, TextArea, Field, Select, Combobox

private func inputCol(_ gap: Float, _ width: Float) -> El<GalleryState> {
    col().gap(gap).w(width).itemsStretch()
}

func textInputPlayground(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().w(280).child(k.textInputField(key: "ti-play", \.edits[0], placeholder: "Placeholder"))
}

func textInputCopy(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().w(280).child(k.textInputField(key: "ti-copy", \.edits[6], placeholder: "api.example.com/v1"))
}

func textInputControlled(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let val = s.edits[1].text.isEmpty && !s.is("typed") ? "Controlled value" : s.edits[1].text
    return col().gap(12).w(280)
        .child(k.textInputField(key: "ti-ctrl", \.edits[1], placeholder: "Type here…") { st, _, _ in st.on.insert("typed") })
        .child(text("Value: \(val)").font(TextStyle(size: 12, weight: 440, lineHeight: 24)).color(k.c.textBase))
}

func textInputAppearances(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    inputCol(20, 280)
        .child(k.textInputField(key: "ti-base", \.edits[6], placeholder: "Base (28px)"))
        .child(k.textInputField(key: "ti-large", \.edits[6], placeholder: "Large (32px)"))
        .child(k.textInputField(key: "ti-large-copy", \.edits[6], placeholder: "Large with copy"))
}

private func fieldBlock(
    _ k: Kit,
    label: String,
    prefix: String? = nil,
    suffix: String? = nil,
    invalid: Bool = false,
    control: El<GalleryState>
) -> El<GalleryState> {
    var inner: El<GalleryState> = row().wFull().gap(6).itemsCenter()
    if let prefix {
        inner = inner.child(text(prefix).font(k.ty.small).color(k.c.textMuted))
    }
    inner = inner.child(control.grow(1).minW(0))
    if let suffix {
        inner = inner.child(text(suffix).font(k.ty.small).color(k.c.textMuted))
    }
    return col().wFull().gap(4)
        .child(text(label).font(k.ty.smallMedium).color(invalid ? k.c.danger.fg : k.c.textBase))
        .child(inner)
}

func textInputWithField(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    inputCol(24, 280)
        .child(fieldBlock(k, label: "Label", prefix: "Prefix", suffix: "Suffix", control: k.textInputField(key: "f1", \.edits[6], placeholder: "Text")))
        .child(fieldBlock(k, label: "Label", prefix: "Prefix", suffix: "Suffix", invalid: true, control: k.textInputField(key: "f2", \.edits[6], placeholder: "Text", invalid: true)))
}

func textInputStates(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    inputCol(20, 280)
        .child(k.textInputField(key: "tis-def", \.edits[6], placeholder: "Default"))
        .child(k.textInputField(key: "tis-val", \.edits[6], placeholder: "With value"))
        .child(k.textInputField(key: "tis-copy", \.edits[6], placeholder: "With copy"))
        .child(k.textInputField(key: "tis-inv", \.edits[6], placeholder: "Invalid", invalid: true))
        .child(k.textInputField(key: "tis-dis", \.edits[6], placeholder: "Disabled").opacity(0.45).inert(true))
        .child(k.textInputField(key: "tis-dis2", \.edits[6], placeholder: "Disabled with value").opacity(0.45).inert(true))
}

func textareaPlayground(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().w(280).child(k.textArea(key: "ta-play", \.edits[2], placeholder: "Placeholder"))
}

func textareaControlled(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    inputCol(12, 280)
        .child(k.textArea(key: "ta-ctrl", \.edits[6], placeholder: "Type here…"))
        .child(text("Value: Controlled value").font(TextStyle(size: 12, weight: 440, lineHeight: 24)).color(k.c.textBase))
}

func textareaWithField(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    inputCol(24, 280)
        .child(fieldBlock(k, label: "Label", prefix: "Prefix", suffix: "Suffix", control: k.textArea(key: "taf1", \.edits[6], placeholder: "Text")))
        .child(fieldBlock(k, label: "Label", prefix: "Prefix", suffix: "Suffix", invalid: true, control: k.textArea(key: "taf2", \.edits[6], placeholder: "Text", invalid: true)))
}

func textareaStates(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    inputCol(20, 280)
        .child(k.textArea(key: "tas-def", \.edits[6], placeholder: "Default"))
        .child(k.textArea(key: "tas-inv", \.edits[6], placeholder: "Invalid", invalid: true))
        .child(k.textArea(key: "tas-dis", \.edits[6], placeholder: "Disabled").opacity(0.45).inert(true))
}

func fieldTextInput(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().w(280).child(
        fieldBlock(k, label: "Username", control: k.textInputField(key: "fu", \.edits[4], placeholder: "Enter username"))
    )
}

func fieldDirectChild(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().w(280).child(
        fieldBlock(k, label: "Email", control: k.textInputField(key: "fe", \.edits[5], placeholder: "name@example.com"))
    )
}

func fieldTextarea(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().w(280).child(
        fieldBlock(k, label: "Notes", control: k.textArea(key: "fn", \.edits[2], placeholder: "Optional notes"))
    )
}

func fieldInvalid(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().w(280).child(
        col().wFull().gap(4)
            .child(fieldBlock(k, label: "API Key", invalid: true, control: k.textInputField(key: "fi", \.edits[6], placeholder: "sk-...", invalid: true)))
            .child(text("Required field").font(k.ty.small).color(k.c.danger.fg))
    )
}

// MARK: - Select & Combobox

private let selectOptions: [(id: String, label: String)] = [
    ("apple", "Apple"),
    ("banana", "Banana"),
    ("cherry", "Cherry"),
]

func selectPlayground(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().w(240).child(
        k.select(
            key: "select",
            options: selectOptions,
            selected: s.picked("sel", "apple"),
            isOpen: s.isOpen("select"),
            onToggleOpen: { st, open in st.open = open ? "select" : nil },
            onSelect: { st, val in st.pick["sel"] = val }
        )
    )
}

func selectGrouped(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let opts: [(id: String, label: String)] = [
        ("ts", "TypeScript"), ("rs", "Rust"), ("swift", "Swift"), ("py", "Python"),
    ]
    return row().w(240).child(
        k.select(
            key: "select-grp",
            options: opts,
            selected: s.picked("sel-grp", "rs"),
            isOpen: s.isOpen("select"),
            onToggleOpen: { st, open in st.open = open ? "select" : nil },
            onSelect: { st, val in st.pick["sel-grp"] = val }
        )
    )
}

func selectInvalid(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    col().w(240).gap(4)
        .child(
            k.select(
                key: "select-inv",
                options: selectOptions,
                selected: s.picked("sel-inv", "apple"),
                isOpen: false,
                onToggleOpen: { _, _ in },
                onSelect: { st, val in st.pick["sel-inv"] = val }
            ).border(1, k.c.danger.border).rounded(k.radius.md)
        )
        .child(text("Selection is required").font(k.ty.small).color(k.c.danger.fg))
}

func selectDisabled(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().w(240).opacity(0.45).inert(true).child(
        k.select(
            key: "select-dis",
            options: selectOptions,
            selected: "apple",
            isOpen: false,
            onToggleOpen: { _, _ in },
            onSelect: { _, _ in }
        )
    )
}

func selectWithField(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().w(240).child(
        fieldBlock(
            k,
            label: "Fruit",
            control: k.select(
                key: "select-field",
                options: selectOptions,
                selected: s.picked("sel-field", "banana"),
                isOpen: false,
                onToggleOpen: { _, _ in },
                onSelect: { st, val in st.pick["sel-field"] = val }
            )
        )
    )
}

func selectStates(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    var unused: [El<GalleryState>] = []
    return col().w(240).gap(16)
        .child(selectPlayground(s, k, &unused))
        .child(selectDisabled(s, k, &unused))
        .child(selectInvalid(s, k, &unused))
}

// MARK: - Combobox (searchable + animated-filter)

let galleryComboModels: [(id: String, label: String)] = (0..<200).map { i in
    (String(format: "model-%d", i), String(format: "Model %03d", i))
}

func filteredGalleryModels(query: String) -> [(id: String, label: String)] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if q.isEmpty { return galleryComboModels }
    return galleryComboModels.filter { $0.label.lowercased().contains(q) || $0.id.lowercased().contains(q) }
}

func comboboxSearchable(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    comboboxStory(s, k, animate: false, overlays: &overlays)
}

func comboboxAnimatedFilter(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    comboboxStory(s, k, animate: true, overlays: &overlays)
}

private func comboboxStory(
    _ s: GalleryState,
    _ k: Kit,
    animate: Bool,
    overlays: inout [El<GalleryState>]
) -> El<GalleryState> {
    let selectedId = s.pick["model"]
    let selectedLabel = selectedId.flatMap { id in
        galleryComboModels.first(where: { $0.id == id })?.label
    } ?? "Choose model"

    let trigger: El<GalleryState> = row()
        .key("model-trigger")
        .role(.button)
        .expanded(s.comboOpen)
        .wFull()
        .h(32)
        .px(10)
        .itemsCenter()
        .justifyBetween()
        .rounded(k.radius.md)
        .bg(k.c.bgButtonNeutral)
        .border(1, s.comboOpen ? k.c.borderFocus : k.c.borderBase)
        .hover(k.c.hover)
        .focusRing(k.c.borderFocus)
        .onClick { st, _ in st.comboOpen.toggle() }
        .child(text(selectedLabel).font(k.ty.ui).color(selectedId == nil ? k.c.textFaint : k.c.textBase).ellipsis())
        .child(icon(KitIcons.chevronDown, size: 14).color(k.c.iconMuted))

    if s.comboOpen {
        let filtered = filteredGalleryModels(query: s.edits[5].text)
        let activeIdx = filtered.isEmpty ? 0 : min(max(s.comboActive, 0), filtered.count - 1)
        var listCol: El<GalleryState> = col()
            .key("model-content")
            .wFull()
            .maxH(200)
            .gap(2)
            .scroll()

        if animate {
            listCol = listCol.animateLayout(k.motion.disclosure)
        }

        if filtered.isEmpty {
            listCol = listCol.child(
                row().px(8).py(8).child(text("No models match").font(k.ty.small).color(k.c.textFaint))
            )
        } else {
            for (idx, opt) in filtered.prefix(24).enumerated() {
                let isSel = (opt.id == selectedId) || (idx == activeIdx)
                let optId = opt.id
                let itemRow: El<GalleryState> = k.listItem(
                    key: "model-opt-\(optId)",
                    title: opt.label,
                    trailing: (opt.id == selectedId) ? icon(KitIcons.check, size: 13).color(k.c.textAccent) : nil,
                    selected: isSel
                ) { st, _ in
                    st.pick["model"] = optId
                    st.comboOpen = false
                }
                listCol = listCol.child(itemRow)
            }
        }

        let popup: El<GalleryState> = col()
            .key("model-popup")
            .absolute(x: 24, y: 80)
            .w(280)
            .p(6)
            .gap(6)
            .rounded(k.radius.lg)
            .bg(k.c.surfaceRaised)
            .shadows(k.shadowLayers(k.elevation.floating))
            .z(60)
            .child(
                k.searchField(key: "model-search", \.edits[5], placeholder: "Search models…") { st, _, _ in
                    st.comboActive = 0
                }
            )
            .child(listCol)

        overlays.append(popup)
    }

    return col().key("model").w(280).gap(4)
        .child(text("Model").font(k.ty.smallMedium).color(k.c.textMuted))
        .child(trigger)
}
