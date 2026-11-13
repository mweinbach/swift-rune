import Foundation
import Rune
import RuneKit

// MARK: - Popover, Menu, Tooltip, HoverCard, Toast

func popoverBasic(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let trigger: El<GalleryState> = row().onClick { st, _ in st.toggleOpen("popover") }
        .child(galleryBodyText(k, "Open popover"))
    return row().child(
        k.popover(key: "popover", isOpen: s.isOpen("popover"), placement: .bottom, trigger: trigger) {
            col().gap(4)
                .child(text("Popover").font(k.ty.uiMedium).color(k.c.textBase))
                .child(text("Optional description").font(k.ty.small).color(k.c.textMuted))
                .child(galleryOverlayText(k, "Popover content"))
        }
    )
}

func popoverControlled(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let trigger: El<GalleryState> = row().onClick { st, _ in st.toggleOpen("popover") }
        .child(galleryBodyText(k, "Toggle popover"))
    return row().child(
        k.popover(key: "popover-ctrl", isOpen: s.isOpen("popover"), placement: .bottom, trigger: trigger) {
            col().gap(4)
                .child(text("Controlled").font(k.ty.uiMedium).color(k.c.textBase))
                .child(text("Open state is controlled").font(k.ty.small).color(k.c.textMuted))
                .child(galleryOverlayText(k, "Controlled content"))
        }
    )
}

private func menuOverlay(
    _ k: Kit,
    key: String,
    label: String,
    openKey: String,
    isOpen: Bool,
    entries: [MenuEntry<GalleryState>],
    overlays: inout [El<GalleryState>]
) -> El<GalleryState> {
    if isOpen {
        overlays.append(
            el().absolute(x: 24, y: 64).z(70).child(k.menu(key: "\(key)-popup", entries: entries))
        )
    }
    return k.button(key: "\(key)-btn", label, variant: .neutral) { st, _ in
        st.toggleOpen(openKey)
    }.expanded(isOpen)
}

func menuBasic(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    menuOverlay(
        k, key: "menu-basic", label: "Open menu", openKey: "menu", isOpen: s.isOpen("menu"),
        entries: [
            .item(id: "new", label: "New file") { st, _ in st.open = nil },
            .item(id: "open", label: "Open file") { st, _ in st.open = nil },
            .item(id: "save", label: "Save") { st, _ in st.open = nil },
            .separator,
            .item(id: "print", label: "Print", disabled: true) { _, _ in },
        ],
        overlays: &overlays
    )
}

func menuAppearances(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    let open = s.isOpen("both")
    if open {
        overlays.append(
            row().gap(16).absolute(x: 24, y: 64).z(70)
                .child(k.menu(key: "standard-popup", entries: [
                    .item(id: "new", label: "New file") { _, _ in },
                    .item(id: "open", label: "Open file") { _, _ in },
                ]))
                .child(k.menu(key: "compact-popup", entries: [
                    .item(id: "new", label: "New file") { _, _ in },
                    .item(id: "open", label: "Open file") { _, _ in },
                ]))
        )
    }
    return row().gap(16)
        .child(k.button(key: "std-menu", "Standard", variant: .neutral) { st, _ in st.toggleOpen("both") }.expanded(open))
        .child(k.button(key: "cmp-menu", "Compact", variant: .neutral) { st, _ in st.toggleOpen("both") }.expanded(open))
}

func menuRich(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    menuOverlay(
        k, key: "menu-rich", label: "Open rich menu", openKey: "menu", isOpen: s.isOpen("menu"),
        entries: [
            .item(id: "text", label: "Text", shortcut: ["⇧", "D"], icon: KitIcons.plus) { st, _ in st.open = nil },
            .item(id: "win", label: "New window", shortcut: ["⌘", "N"], icon: KitIcons.plus) { st, _ in st.open = nil },
            .item(id: "save", label: "Save as…", shortcut: ["⌘", "S"], icon: KitIcons.plus) { st, _ in st.open = nil },
            .separator,
            .item(id: "print", label: "Print", shortcut: ["⌘", "P"], icon: KitIcons.plus, disabled: true) { _, _ in },
        ],
        overlays: &overlays
    )
}

func menuCheckbox(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    menuOverlay(
        k, key: "menu-cb", label: "View", openKey: "menu", isOpen: s.isOpen("menu"),
        entries: [
            .item(id: "wrap", label: "Word wrap", shortcut: ["⌥", "Z"], icon: !s.is("wrap") ? KitIcons.check : nil) { st, _ in st.flip("wrap") },
            .item(id: "minimap", label: "Minimap", icon: s.is("minimap") ? KitIcons.check : nil) { st, _ in st.flip("minimap") },
            .item(id: "ruler", label: "Ruler", disabled: true) { _, _ in },
        ],
        overlays: &overlays
    )
}

func menuRadio(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    let theme = s.picked("theme", "system")
    return menuOverlay(
        k, key: "menu-radio", label: "Theme", openKey: "menu", isOpen: s.isOpen("menu"),
        entries: [
            .section("Appearance"),
            .item(id: "light", label: "Light", icon: theme == "light" ? KitIcons.check : nil) { st, _ in st.pick["theme"] = "light" },
            .item(id: "dark", label: "Dark", icon: theme == "dark" ? KitIcons.check : nil) { st, _ in st.pick["theme"] = "dark" },
            .item(id: "system", label: "System", icon: theme == "system" ? KitIcons.check : nil) { st, _ in st.pick["theme"] = "system" },
        ],
        overlays: &overlays
    )
}

func menuSubmenu(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    menuOverlay(
        k, key: "menu-sub", label: "File", openKey: "menu", isOpen: s.isOpen("menu"),
        entries: [
            .item(id: "new", label: "New file", shortcut: ["⌘", "N"]) { st, _ in st.open = nil },
            .item(id: "open", label: "Open file", shortcut: ["⌘", "O"]) { st, _ in st.open = nil },
            .item(id: "recent", label: "Open recent", shortcut: ["▸"]) { st, _ in st.flip("recent") },
            .separator,
            .item(id: "save", label: "Save", shortcut: ["⌘", "S"]) { st, _ in st.open = nil },
            .item(id: "saveas", label: "Save as…", shortcut: ["⇧", "⌘", "S"]) { st, _ in st.open = nil },
        ],
        overlays: &overlays
    )
}

private func tipFrame(_ e: El<GalleryState>) -> El<GalleryState> {
    row().wFull().p(80).center().child(e)
}

func tooltipSimple(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    tipFrame(k.tooltip(key: "tip", text: "Tooltip Text", isVisible: s.isOpen("tip"), trigger: galleryBodyText(k, "Hover me")))
}

func tooltipKeybind(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    tipFrame(k.tooltip(key: "tip-kb", text: "Tooltip Text  ⌘⌘", isVisible: s.isOpen("tip"), trigger: galleryBodyText(k, "Hover me")))
}

func tooltipPath(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    tipFrame(k.tooltip(key: "tip-path", text: "Components / Tooltip", isVisible: s.isOpen("tip"), trigger: galleryBodyText(k, "Hover me")))
}

func tooltipTitleDescription(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    tipFrame(k.tooltip(key: "tip-td", text: "Title · Description", isVisible: s.isOpen("tip"), trigger: galleryBodyText(k, "Hover me")))
}

func hoverCardBasic(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(
        k.hoverCard(key: "card", isOpen: s.isOpen("card"), placement: .bottom, trigger: galleryBodyText(k, "Hover me")) {
            col().gap(6)
                .child(text("Preview").font(TextStyle(size: 13, weight: 600, lineHeight: 24)).color(k.c.textBase))
                .child(text("Short supporting text.").font(TextStyle(size: 12, weight: 440, lineHeight: 24)).color(k.c.textMuted))
        }
    )
}

func toastAll(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    if s.isOpen("toast") {
        overlays.append(
            k.toastStack(
                key: "toast-stack",
                toasts: [ToastEntry(id: "download", message: "Download started... · 23% · 2 min left", tone: .accent)],
                placement: .bottomTrailing
            ) { st, _ in
                st.open = nil
            }
        )
    }
    return col().gap(12).itemsStart()
        .child(k.button(key: "t-dl", "Show download toast", variant: .neutral) { st, _ in st.open = "toast" })
        .child(k.button(key: "t-saved", "Show saved toast", variant: .neutral) { _, _ in })
        .child(k.button(key: "t-saving", "Show saving toast", variant: .neutral) { _, _ in })
        .child(k.button(key: "t-unsaved", "Show unsaved changes toast", variant: .neutral) { _, _ in })
}
