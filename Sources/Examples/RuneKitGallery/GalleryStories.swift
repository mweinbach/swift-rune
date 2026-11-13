import Foundation
import OpenCodeTheme
import Rune
import RuneKit

func galleryCaption(_ k: Kit, _ label: String) -> El<GalleryState> {
    text(label).font(TextStyle(size: 12, weight: 440, lineHeight: 24)).color(k.c.textMuted)
}

func galleryBodyText(_ k: Kit, _ s: String) -> El<GalleryState> {
    text(s).font(TextStyle(size: 14, weight: 440, lineHeight: 24)).color(k.c.textBase)
}

func galleryOverlayText(_ k: Kit, _ s: String) -> El<GalleryState> {
    text(s).font(TextStyle(size: 13, weight: 440, lineHeight: 24)).color(k.c.textBase)
}

func galleryFlex(_ gap: Float) -> El<GalleryState> {
    row().gap(gap).itemsCenter().flexWrap(true)
}

private let serveCommand = "opencode serve --port 4096 --hostname 0.0.0.0"
private let longPathText = "~/Projects/rune/crates/rune-kit/src/components/settings/appearance_panel.rs"

func dialogBasic(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    if s.isOpen("dialog") {
        overlays.append(
            k.dialog(
                key: "dialog",
                title: "Dialog",
                description: "Description",
                onDismiss: { $0.open = nil },
                body: galleryBodyText(k, "Dialog body content.")
            )
        )
    }
    return k.button(key: "opener", "Open dialog", variant: .neutral) { st, _ in
        st.toggleOpen("dialog")
    }
}

func dialogFit(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    if s.isOpen("dialog-fit") {
        let actions: El<GalleryState> = row().wFull().p(16).gap(8).justifyEnd()
            .child(k.button(key: "dialog-fit-cancel", "Cancel", variant: .ghost) { st, _ in st.open = nil })
            .child(k.button(key: "dialog-fit-delete", "Delete", variant: .danger) { st, _ in st.open = nil })
        overlays.append(
            k.dialog(
                key: "dialog-fit",
                title: "Delete item?",
                description: "This cannot be undone.",
                maxWidth: 400,
                onDismiss: { $0.open = nil },
                body: actions
            )
        )
    }
    return k.button(key: "opener", "Open confirmation", variant: .neutral) { st, _ in
        st.toggleOpen("dialog-fit")
    }
}

func motionFocusModal(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    if s.isOpen("dialog") {
        let body: El<GalleryState> = col().gap(16)
            .child(
                row().gap(16).itemsCenter()
                    .child(k.spinner(key: "spinner"))
                    .child(k.loader(key: "loader"))
            )
            .child(
                k.button(key: "done", "Done", variant: .primary) { st, _ in
                    st.open = nil
                }
            )
        overlays.append(
            k.dialog(
                key: "dialog",
                title: "Loading",
                onDismiss: { $0.open = nil },
                body: body
            )
        )
    }
    return col().gap(16)
        .child(k.button(key: "opener", "Open dialog", variant: .neutral) { st, _ in st.toggleOpen("dialog") })
        .child(k.switchControl(key: "switch", isOn: s.is("switch"), label: "Sync") { st, _ in st.flip("switch") })
        .child(k.checkbox(key: "check", checked: s.is("check"), label: "Remember") { st, _ in st.flip("check") })
        .child(
            k.segmentedControl(
                key: "focus-seg",
                options: [(id: "First", label: "First"), (id: "Second", label: "Second")],
                selected: s.is("second") ? "Second" : "First"
            ) { st, picked in
                if picked == "Second" {
                    st.on.insert("second")
                } else {
                    st.on.remove("second")
                }
            }
        )
}

func motionStaggerList(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let labels = ["Inbox", "Drafts", "Sent", "Archive", "Trash"]
    var listCol: El<GalleryState> = col().key("rows").gap(4)
    if s.is("rows") {
        for label in labels {
            let r: El<GalleryState> = row()
                .key(label)
                .w(240)
                .h(36)
                .px(12)
                .itemsCenter()
                .bg(k.c.surfaceBase)
                .rounded(k.radius.md)
                .transition(Transition.push(from: .bottom).combined(with: .opacity))
                .child(text(label).font(k.ty.ui).color(k.c.textBase))
            listCol = listCol.child(r)
        }
    }
    return col().gap(8)
        .child(k.button(key: "opener", "Show rows", variant: .neutral) { st, _ in st.flip("rows") })
        .child(listCol)
}

func popupListComposer(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    let entries: [PopupListItem] = [
        PopupListItem(id: "review", label: "/review", description: "Review branch changes", shortcut: "⏎"),
        PopupListItem(id: "compact", label: "/compact", description: "Summarize the conversation", shortcut: "⌘K"),
        PopupListItem(id: "search", label: "/search", description: "Search workspace files", shortcut: "⌘P"),
        PopupListItem(id: "share", label: "/share", description: "Create a read-only link", shortcut: nil, disabled: true),
    ]
    let raw = s.edits[7].text
    let q = (raw.hasPrefix("/") ? String(raw.dropFirst()) : raw).lowercased()
    let filtered = entries.filter { item in
        q.isEmpty || item.label.lowercased().contains(q) || (item.description?.lowercased().contains(q) ?? false)
    }
    let active = min(Int(s.picked("popup-list", "0")) ?? 0, max(0, filtered.count - 1))

    if s.isOpen("popup-list") {
        overlays.append(
            el()
                .absolute(x: 24, y: 66)
                .z(60)
                .child(
                    k.popupList(
                        key: "popup-list",
                        items: filtered,
                        activeIndex: filtered.isEmpty ? nil : active,
                        emptyText: "No commands",
                        width: 320,
                        maxHeight: 240
                    ) { st, chosen in
                        st.edits[7] = TextEdit("/\(chosen.id) ")
                        st.open = nil
                    }
                )
        )
    }

    return row().key("composer").w(320).child(
        k.textInputField(
            key: "composer-input",
            \.edits[7],
            placeholder: "Type / for commands or @ to mention…",
            onChange: { st, _, _ in
                st.open = "popup-list"
                st.pick["popup-list"] = "0"
            }
        )
    )
}

func textSelectableHelp(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let copyBtn: El<GalleryState> = k.iconButton(
        key: "copy",
        svg: OpenCodeIcons.copy,
        label: "Copy command",
        size: .sm,
        variant: .ghost
    ) { _, tx in
        tx.copyText(serveCommand)
    }
    .help("Copy command")
    .onHover { st, inside, _ in
        st.hoverCopy = inside
    }

    let copyWithTip: El<GalleryState> = k.tooltip(
        key: "copy-tip",
        text: "Copy command",
        placement: .top,
        isVisible: s.hoverCopy,
        trigger: copyBtn
    )

    let cmdRow: El<GalleryState> = row()
        .key("command-row")
        .wFull()
        .h(36)
        .pl(12)
        .pr(4)
        .gap(8)
        .itemsCenter()
        .bg(k.c.surfaceBase)
        .rounded(k.radius.md)
        .border(1, k.c.borderBase)
        .child(
            text(serveCommand)
                .key("command")
                .font(k.ty.mono)
                .color(k.c.textBase)
                .selectable(true)
                .selectionStyle(SelectionStyle(highlight: k.selection()))
                .grow(1)
                .minW(0)
        )
        .child(copyWithTip)

    return col().w(480).gap(8)
        .child(galleryCaption(k, "Run the server from a terminal"))
        .child(cmdRow)
        .child(
            row().w(280).child(
                k.textInputField(key: "field", \.edits[7], placeholder: "Selected like a field")
            )
        )
}

func textTruncateMiddle(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    // Phase 2 (@el/@text): wire El.truncateMiddle / El.truncateHead + El.selectable(true)
    func pathRow(_ w: Float, _ how: String) -> El<GalleryState> {
        col().w(w)
            .child(text(longPathText).font(k.ty.ui).color(k.c.textBase).ellipsis())
            .child(text("\(how), \(Int(w)) pt").font(k.ty.small).color(k.c.textMuted))
    }
    return col().gap(12)
        .child(pathRow(360, "Middle"))
        .child(pathRow(240, "Middle"))
        .child(pathRow(160, "Middle"))
        .child(pathRow(240, "End"))
        .child(pathRow(240, "Head"))
}

func scrollBarBasic(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    scrollFeed(k, rows: 24, tail: nil)
}

func scrollBarGrow(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    col().gap(8)
        .child(k.button(key: "more", "Change rows", variant: .neutral) { st, _ in st.flip("more") })
        .child(scrollFeed(k, rows: 12, tail: s.is("more") ? 600 : 0))
}

func scrollFeed(_ k: Kit, rows: Int, tail: Float?) -> El<GalleryState> {
    var feedCol: El<GalleryState> = col()
        .key("feed")
        .wFull()
        .grow(1)
        .minH(0)
        .p(8)
        .gap(4)
        .scroll()

    for i in 0..<rows {
        let itemRow: El<GalleryState> = row()
            .key("item-\(i)")
            .wFull()
            .h(32)
            .px(10)
            .itemsCenter()
            .justifyBetween()
            .rounded(k.radius.sm)
            .child(text(String(format: "Build step %02d", i + 1)).font(k.ty.uiCompact).color(k.c.textBase))
            .child(text("\(12 + i * 7) ms").font(k.ty.small).color(k.c.textMuted))
        feedCol = feedCol.child(itemRow)
    }
    if let tail {
        feedCol = feedCol.child(el().key("tail").wFull().h(tail))
    }

    return col()
        .key("panel")
        .w(360)
        .h(260)
        .rounded(k.radius.md)
        .bg(k.c.layer01)
        .border(1, k.c.borderBase)
        .clip(true)
        .child(feedCol)
}
