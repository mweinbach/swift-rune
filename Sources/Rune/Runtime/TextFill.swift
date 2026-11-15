import Foundation
import RuneMotion

// A long paste's paragraphs that wait to be shaped (`LazyFill`): shaped a few a frame, those the
// field shows first, and all of those near what an input needs before it reads them
// (`runtime/text_fill.rs`).

/// How long a frame shapes waiting paragraphs, in seconds (`BUDGET`, 1.5 ms).
internal let textFillBudget: Double = 0.0015

extension Runtime {
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
        #if canImport(CoreText) && canImport(CoreGraphics)
        var more = false
        for (id, rec) in nodeTextLayouts where rec.isInput {
            guard let p = rec.box.paragraphs, p.waiting else { continue }
            let rows = textRows[id] ?? (0, 0)
            let r = reach.map { max(rows.1 - rows.0, 0) * $0 + 1 } ?? Float.infinity
            guard let (built, moved) = textSystem.fillParagraphs(p, budget: budget, rows: rows, reach: r, field: id.rawValue) else { continue }
            more = more || built.waiting
            let box = textSystem.paragraphBox(built, text: rec.box.authText, style: rec.box.style, pixelScale: rec.box.pixelScale)
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
        #else
        return false
        #endif
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
    /// `paragraphs_flow` / `plaintext_flow`): nil when it lays out as one text.
    internal static func paragraphRequest(field: NodeId, el: El<State>, edit: TextEdit, resolved: ElResolvedInput) -> ParagraphRequest? {
        guard !resolved.showingPlaceholder, !resolved.isSingleLine, !resolved.isSecure, edit.multiline,
              resolved.style.wrap == .wrap, resolved.style.maxLines == 0,
              resolved.spans?.isEmpty ?? true, resolved.pills.isEmpty,
              // A rich field shows a block per line, `.paragraph` when it has none: plain while
              // every block is a paragraph (`paragraphs.rs` `plain`).
              resolved.blocks.allSatisfy({ $0 == .paragraph }) else { return nil }
        let plaintext = el.textDirByParagraph && edit.forcedDir == nil
        guard plaintext || resolved.renderedString.utf8.contains(0x0a) else { return nil }
        let forced: TextFlow?
        if plaintext {
            forced = nil
        } else if let d = resolved.style.direction {
            forced = d
        } else {
            forced = Direction.of(resolved.renderedString) == .rtl ? .rtl : .ltr
        }
        return ParagraphRequest(field: field.rawValue, forced: forced, startFlow: resolved.style.direction ?? .ltr)
    }
}
