import Foundation
import Rune
import RuneKit

/// Port of `examples/overlay-lab`: floating capture pill with expandable chips,
/// hover readout, full-stage area-selection picker with live pointer dot, underlay,
/// and hit-region modes.
private let labBlue = Color(r: 0.25, g: 0.55, b: 1.0, a: 1.0)
private let labDark = Color(r: 0.055, g: 0.065, b: 0.085, a: 0.97)

struct SelectionRect: Equatable {
    var x: Float
    var y: Float
    var w: Float
    var h: Float
}

struct OverlayLabState {
    var underlay: Bool = false
    var hitOnly: Bool = false
    var clicks: Int = 0
    var picker: Bool = false
    var expanded: Bool = false
    var hidden: Bool = false
    var hovered: String = ""
    var selection: SelectionRect? = nil
    var selectionAtPress: SelectionRect? = nil
    var pointer = Live<Vec2>(Vec2(160, 100))
}

private func chipEl(
    _ labelText: String,
    action: @escaping (inout OverlayLabState) -> Void
) -> El<OverlayLabState> {
    row()
        .key(labelText)
        .role(.button)
        .label(labelText)
        .p(10)
        .rounded(16)
        .bg(labBlue.alpha(0.16))
        .pressScale(0.95)
        .onHover { state, isHovered, _ in
            if isHovered {
                state.hovered = labelText
            } else if state.hovered == labelText {
                state.hovered = ""
            }
        }
        .onClick { state in
            action(&state)
        }
        .child(text(labelText).font(Tok.Typography.label).color(.white))
}

func overlayLabView(_ s: OverlayLabState, _ cx: inout Cx<OverlayLabState>) -> El<OverlayLabState> {
    if s.underlay {
        return col()
            .sizeFull()
            .bg(labDark)
            .p(40)
            .onClick { state in state.clicks += 1 }
            .child(
                text("Underlay clicks: \(s.clicks)")
                    .font(Tok.Typography.body)
                    .color(.white)
            )
    }

    if s.picker {
        var root: El<OverlayLabState> = el()
            .sizeFull()
            .bg(labBlue.alpha(0.06))
            .onPointerDown { state, press, tx in
                state.selectionAtPress = state.selection
                state.pointer.set(press.window)
                tx.settle()
            }
            .onDrag { state, drag, tx in
                state.pointer.set(drag.window)
                let x = min(drag.local.x, drag.startLocal.x)
                let y = min(drag.local.y, drag.startLocal.y)
                let w = abs(drag.local.x - drag.startLocal.x)
                let h = abs(drag.local.y - drag.startLocal.y)
                state.selection = SelectionRect(x: x, y: y, w: w, h: h)
                tx.settle()
            }
            .onDragEnd { state, cancelled, _ in
                if cancelled {
                    state.selection = state.selectionAtPress
                }
                state.selectionAtPress = nil
            }
            .child(
                text("Drag an area · Escape to close")
                    .font(Tok.Typography.body)
                    .color(.white)
                    .absolute(x: 24, y: 24)
            )
            .child(
                el()
                    .square(8)
                    .rounded(4)
                    .bg(labBlue)
                    .absolute(x: 0, y: 0)
                    .liveOffset(s.pointer.binding)
            )

        if let sel = s.selection {
            root = root.child(
                el()
                    .key("selection")
                    .size(sel.w, sel.h)
                    .border(2, labBlue)
                    .bg(labBlue.alpha(0.12))
                    .absolute(x: sel.x, y: sel.y)
            )
        }
        return root
    }

    if s.hitOnly {
        return col()
            .sizeFull()
            .center()
            .bg(Color(r: 0.03, g: 0.04, b: 0.05, a: 1.0))
            .child(
                row()
                    .key("hit-only")
                    .size(300, 48)
                    .center()
                    .rounded(10)
                    .bg(labDark)
                    .child(text("Native hit region").font(Tok.Typography.body).color(.white))
            )
    }

    if s.hidden {
        return col()
            .sizeFull()
            .center()
            .bg(Color(r: 0.03, g: 0.04, b: 0.05, a: 1.0))
            .child(
                chipEl("Show pill") { state in state.hidden = false }
            )
    }

    var chips = row()
        .key("pill")
        .p(8)
        .gap(4)
        .rounded(28)
        .bg(labDark)
        .border(1, Color.white.alpha(0.08))
        .child(chipEl("Area") { state in state.picker = true })
        .child(chipEl("Window") { state in state.picker = true })
        .child(chipEl("Screen") { state in state.picker = true })
        .child(chipEl("iPhone") { state in state.expanded.toggle() })

    if s.expanded {
        chips = chips.child(chipEl("Route") { state in state.expanded = false })
    }

    chips = chips
        .child(chipEl("Paste") { state in state.expanded.toggle() })
        .child(chipEl("×") { state in state.hidden = true })

    return col()
        .sizeFull()
        .center()
        .gap(8)
        .bg(Color(r: 0.03, g: 0.04, b: 0.05, a: 1.0))
        .child(chips)
        .child(
            text(s.hovered)
                .font(TextStyle(size: 11.5, weight: 400))
                .color(labBlue)
        )
}

let spec = AppSpec<OverlayLabState>(
    title: "Overlay lab",
    size: Vec2(680, 160),
    state: OverlayLabState(),
    onKey: { state, event, _ in
        if event.key == .escape && state.picker {
            state.picker = false
            return true
        }
        return false
    },
    view: overlayLabView
)
.scene("pill") { _ in }
.scene("expanded") { $0.expanded = true }
.scene("picker") {
    $0.picker = true
    $0.selection = SelectionRect(x: 140, y: 100, w: 560, h: 320)
}
.scene("underlay") {
    $0.underlay = true
    $0.clicks = 3
}
.scene("hit-only") {
    $0.hitOnly = true
}

try RuneApp.run(spec)
