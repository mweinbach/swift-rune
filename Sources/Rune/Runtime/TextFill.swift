import Foundation
import RuneMotion

// A long paste's paragraphs that wait to be shaped (`LazyFill`): shaped a few a frame, those the
// field shows first, and all of those near what an input needs before it reads them
// (`runtime/text_fill.rs`).

/// How long a frame shapes waiting paragraphs, in seconds (`BUDGET`, 1.5 ms).
internal let textFillBudget: Double = 0.0015

extension Runtime {
    /// Shape the waiting paragraphs that this paint can see before it reads caret, selection,
    /// or glyph geometry. Other paragraphs keep their exact estimated height for the budgeted fill.
    internal func prepareVisibleParagraphs(in box: TextLayoutBox, field: NodeId, window: TextRasterWindow?) -> TextLayoutBox {
        guard let layout = box.paragraphs, layout.waiting else { return box }
        if let window, window.lowerY >= window.upperY { return box }
        let band = window?.expanded(for: box.style, spans: box.spans, scale: layout.scale)
        let rows = (max(0, (band?.lowerY ?? 0) * layout.scale),
                    min(layout.height, band.map { $0.upperY * layout.scale } ?? layout.height))
        guard rows.0 < rows.1,
              let (filled, moved) = textSystem.fillParagraphs(layout, budget: .infinity, rows: rows, reach: 0, field: field.rawValue)
        else { return box }
        let result = textSystem.paragraphBox(filled, text: box.authText, spans: box.spans, style: box.style, pixelScale: box.pixelScale)
        if nodeTextLayouts[field]?.box.paragraphs === layout {
            nodeTextLayouts[field] = RetainedLayoutCoordinator.TextLayoutRecord(box: result, isInput: true)
        }
        if moved { needsCommit = true }
        return result
    }

    /// Shapes waiting paragraphs of each field for up to `textFillBudget`, the rows it drew last
    /// first. True while some still wait, so another frame comes (`fill_text`).
    internal func fillText() -> Bool {
        fillTextWithin(budget: textFillBudget, reach: nil)
    }

    /// Before an input that reads a field's layout (a caret key, a press, a drag): every waiting
    /// paragraph within a window's height of the rows each field drew, shaped now (`fill_text_near`).
    internal func fillTextNear() {
        _ = fillTextWithin(budget: .infinity, reach: 1.0)
    }

    private func fillTextWithin(budget: Double, reach: Float?) -> Bool {
        var more = false
        for (id, rec) in nodeTextLayouts where rec.isInput {
            guard let p = rec.box.paragraphs, p.waiting else { continue }
            let rows = textRows[id] ?? (0, 0)
            let r = reach.map { max(rows.1 - rows.0, 0) * $0 + 1 } ?? Float.infinity
            guard let (built, moved) = textSystem.fillParagraphs(p, budget: budget, rows: rows, reach: r, field: id.rawValue) else {
                more = true
                continue
            }
            more = more || built.waiting
            let box = textSystem.paragraphBox(built, text: rec.box.authText, spans: rec.box.spans, style: rec.box.style, pixelScale: rec.box.pixelScale)
            nodeTextLayouts[id] = RetainedLayoutCoordinator.TextLayoutRecord(box: box, isInput: true)
            // A waiting height is exact; should one not be, the field lays out again.
            if moved {
                #if DEBUG
                FileHandle.standardError.write(Data("rune: text fill: a waiting paragraph wasn't the height it waited at\n".utf8))
                #endif
                needsCommit = true
            }
        }
        if !more { textRows.removeAll() }
        return more
    }

    /// Whether `ev` reads a text's layout away from its caret: caret movement or a shortcut.
    /// Text typed, deleted or composed at the caret doesn't (`reads_text_layout`).
    internal static func readsTextLayout(_ ev: KeyEvent) -> Bool {
        switch ev.key {
        case .text, .space, .backspace, .delete:
            return ev.mods.cmd || ev.mods.ctrl || ev.mods.alt
        case .modifier:
            return false
        default:
            return true
        }
    }

    /// The paragraph request for a field's layout (`TextSpec::by_paragraph` /
    /// `paragraphs_flow` / `plaintext_flow`, resolved into its style by
    /// `ElDisplayResolver.applyByParagraph`): nil when it lays out as one text. A field with
    /// layout-affecting spans, pills or blocks other than paragraphs keeps one text layout, whose paragraphs
    /// read the same ways (`TextStyle.byParagraphStart`), pills isolated.
    internal static func paragraphRequest(field: NodeId, el: El<State>, edit: TextEdit, resolved: ElResolvedInput) -> ParagraphRequest? {
        guard !resolved.showingPlaceholder, !resolved.isSecure, let start = resolved.style.byParagraphStart,
              resolved.pills.isEmpty, ParagraphRequest.supports(resolved.spans),
              // A rich field shows a block per line, `.paragraph` when it has none: plain while
              // every block is a paragraph (`paragraphs.rs` `plain`).
              resolved.blocks.allSatisfy({ $0 == .paragraph }) else { return nil }
        return ParagraphRequest(field: field.rawValue, forced: resolved.style.direction, startFlow: start, highlights: el.textHighlights ?? [])
    }

    /// Paragraph request for a static multi-line text marked with `El.byLine()` (`#1133`),
    /// such as Markdown fenced code blocks. Reuses unchanged line layouts across streaming commits.
    internal static func staticByLineParagraphRequest(
        nodeId: NodeId,
        el: El<State>,
        style: TextStyle,
        spans: [TextSpan]?,
        pills: [PillChip]
    ) -> ParagraphRequest? {
        guard el.isByLine, !el.isSecure, pills.isEmpty,
              style.maxLines == 0, style.wrap != .ellipsis,
              ParagraphRequest.supports(spans) else {
            return nil
        }
        let flow = style.direction ?? .ltr
        return ParagraphRequest(
            field: nodeId.rawValue,
            forced: flow,
            startFlow: flow,
            highlights: el.textHighlights ?? [],
            byLine: true
        )
    }
}
