import Foundation
import Rune
import RuneKit
import RuneMotion

public func bentoColor(_ l: Lch) -> Color {
    oklcha(l.l, l.c, l.h, l.a)
}

public func bentoSpring(_ s: ChaosSpring) -> Spring {
    Spring(duration: s.duration, bounce: s.bounce)
}

public func bentoFont(_ size: Float, _ weight: Float) -> TextStyle {
    TextStyle(size: size, weight: weight, lineHeight: (size * 1.3).rounded())
}

/// Tabular figures styling helper (`bentoNums`).
public func bentoNums(_ size: Float, _ weight: Float) -> TextStyle {
    bentoFont(size, weight)
}

public func bentoTitle(_ s: String) -> El<MotionBentoState> {
    text(s).font(bentoFont(13.0, 560.0)).color(bentoColor(ChaosColor.text2))
}

public func bentoCaption(_ s: String) -> El<MotionBentoState> {
    text(s).font(bentoFont(12.0, 460.0)).color(bentoColor(ChaosColor.text3))
}

/// A tile: a rounded card with a title row (title on the left, `aside` on the right) over `body`.
public func bentoTile(
    key: String,
    name: String,
    aside: El<MotionBentoState>,
    body: El<MotionBentoState>
) -> El<MotionBentoState> {
    col()
        .key(key)
        .rounded(ChaosGrid.radius)
        .bg(bentoColor(ChaosColor.tile))
        .border(1.0, bentoColor(ChaosColor.edge))
        .p(ChaosGrid.tilePad)
        .gap(14.0)
        .child(
            row()
                .key("head")
                .h(20.0)
                .centerY()
                .gap(8.0)
                .child(bentoTitle(name))
                .child(spacer())
                .child(aside)
        )
        .child(body)
}

/// Column width in the 4-column grid.
public func bentoColW() -> Float {
    (ChaosGrid.width - 2.0 * ChaosGrid.pad - 3.0 * ChaosGrid.gap) / 4.0
}

/// A tile's inside width for a span of `cols` columns.
public func bentoInnerW(_ cols: Float) -> Float {
    bentoColW() * cols + ChaosGrid.gap * (cols - 1.0) - 2.0 * ChaosGrid.tilePad
}

/// A tile's body height for a row of height `h`.
public func bentoInnerH(_ h: Float) -> Float {
    h - 2.0 * ChaosGrid.tilePad - 20.0 - 14.0
}

/// A rounded button in the well colour.
public func bentoWellButton(
    key: String,
    label: String,
    w: Float,
    h: Float,
    onClick: @escaping (inout MotionBentoState) -> Void
) -> El<MotionBentoState> {
    row()
        .key(key)
        .size(w, h)
        .rounded(h * 0.32)
        .center()
        .bg(bentoColor(ChaosColor.well))
        .border(1.0, bentoColor(ChaosColor.edge))
        .hover(bentoColor(ChaosColor.wellHi))
        .press(bentoColor(ChaosColor.wellHi))
        .pressScale(0.94)
        .onClick(onClick)
        .child(text(label).font(bentoFont(15.0, 560.0)).color(bentoColor(ChaosColor.text)))
}
