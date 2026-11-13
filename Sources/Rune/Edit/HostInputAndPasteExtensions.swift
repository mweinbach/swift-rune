import Foundation
import RuneMotion
#if canImport(AppKit)
import AppKit
#endif

// MARK: - PointerButton AppKit Mapping

extension PointerButton {
    /// Maps an `NSEvent.buttonNumber` (`0` = primary, `1` = secondary, `2` = middle, `3` = back, `4` = forward)
    /// into Rune's `PointerButton` (`input/canvas_input.rs`).
    public static func fromAppKit(buttonNumber: Int) -> PointerButton {
        switch buttonNumber {
        case 0: return .primary
        case 1: return .secondary
        case 2: return .middle
        case 3: return .back
        case 4: return .forward
        default: return .middle
        }
    }
}

// MARK: - Async Paste Request Extensions (crates/rune/src/clipboard/tx.rs)

private enum PasteExtensionKey {
    static let requestPaste = "host.tx.requestPaste"
    static let pasteCallback = "host.tx.pasteCallback"
}

private final class RuntimeHostExtensionBox {
    var pasteRequested: Bool = false
    var secureClaim: SecureInputClaim?
    var spellWatch: SpellPauseWatch?
}

private final class RuntimeHostExtensionStore: @unchecked Sendable {
    static let shared = RuntimeHostExtensionStore()
    private let lock = NSLock()
    private var boxes: [ObjectIdentifier: RuntimeHostExtensionBox] = [:]

    func box(for runtime: AnyObject) -> RuntimeHostExtensionBox {
        let id = ObjectIdentifier(runtime)
        lock.lock()
        defer { lock.unlock() }
        if let existing = boxes[id] { return existing }
        let created = RuntimeHostExtensionBox()
        boxes[id] = created
        return created
    }

    func remove(for runtime: AnyObject) {
        let id = ObjectIdentifier(runtime)
        lock.lock()
        boxes.removeValue(forKey: id)
        lock.unlock()
    }
}

extension Tx {
    /// Requests the host shell to read the system clipboard asynchronously and deliver a `paste(_:at:)`
    /// back into the runtime (used by custom Edit -> Paste controls and deferred clipboard flows).
    public mutating func requestPaste() {
        runtimeActions[PasteExtensionKey.requestPaste] = true
    }

    /// Whether `requestPaste()` was called during this transaction.
    public var hasPasteRequest: Bool {
        (runtimeActions[PasteExtensionKey.requestPaste] as? Bool) == true
    }
}

extension Runtime {
    /// Marks that an async host paste read has been requested for this runtime (`Tx.requestPaste()`).
    public func requestPaste() {
        RuntimeHostExtensionStore.shared.box(for: self).pasteRequested = true
    }

    /// Consumes and clears a pending async paste request.
    public func takePasteRequest() -> Bool {
        let box = RuntimeHostExtensionStore.shared.box(for: self)
        let pending = box.pasteRequested
        box.pasteRequested = false
        return pending
    }

    /// Inspects `tx` for host-bridge extension flags (such as `tx.requestPaste()`).
    public func recordHostExtensionRequests(from tx: Tx) {
        if tx.hasPasteRequest {
            requestPaste()
        }
    }

    /// Delivers a paste payload fetched asynchronously by the host (e.g. `NSPasteboard.general`)
    /// whenever a paste request is pending, returning `true` if a payload was applied.
    @discardableResult
    public func performAsyncPaste(
        using readClipboard: () -> ClipboardContent?,
        at now: Double
    ) -> Bool {
        guard takePasteRequest(), let content = readClipboard() else {
            return false
        }
        clipboard = content
        paste(content, at: now)
        return true
    }

    /// Synchronizes `SecureInputClaim` with the runtime's focused element security state and window focus (`input/secure_input.rs`).
    @discardableResult
    public func syncSecureInput(
        _ claim: SecureInputClaim,
        windowFocused: Bool
    ) -> Bool {
        let shouldEnable = hasSecureFocus && windowFocused
        claim.set(shouldEnable)
        return claim.isActive
    }

    /// Updates a `SpellPauseWatch` for the currently focused `TextEdit` and runs spellchecking only once settled
    /// past `SpellPause.delaySeconds` (`edit/spell.rs` + `edit/spell_pause.rs`).
    public func spellCheckWhenSettled(
        watch: inout SpellPauseWatch,
        checker: SpellChecker = .shared,
        at now: Double
    ) -> [Range<Int>]? {
        guard let fp = focusedPath,
              let idx = flatNodes.firstIndex(where: { $0.path == fp }),
              let editLens = flatNodes[idx].el.handlers.editLens else {
            return nil
        }
        if hasSecureFocus {
            return nil
        }
        let edit = editLens.get(state)
        let suppressedCaret: Int?
        if watch.path != fp || watch.lastText != edit.text {
            suppressedCaret = watch.observe(path: fp, text: edit.text, caret: edit.cursor, now: now)
        } else {
            _ = watch.tick(now: now)
            suppressedCaret = SpellPause.waitingCaret(in: watch.state)
        }
        guard watch.state == .settled, suppressedCaret == nil, flatNodes[idx].el.spellcheck else {
            return nil
        }
        return checker.misspelledUTF8Ranges(in: edit.text)
    }

    /// Posts a VoiceOver announcement on macOS via `MacOSAccessibilityHost` / `NSAccessibility.post(..., .announcementRequested)`.
    public static func postAccessibilityAnnouncement(
        _ message: String,
        politeness: LiveRegionPoliteness = .polite,
        in view: AnyObject?
    ) {
        #if canImport(AppKit)
        guard !message.isEmpty, let nsView = view as? NSView else { return }
        let priority: NSAccessibilityPriorityLevel = politeness == .assertive ? .high : .medium
        NSAccessibility.post(
            element: nsView,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ]
        )
        #else
        _ = (message, politeness, view)
        #endif
    }
}

// MARK: - Justified Multi-Line & Inline-Code Chip Quality Helpers (text/quality_tests.rs)

/// Line justification and inline-code background chip geometry helpers (`crates/rune/src/text/quality_tests.rs`).
public enum TextQualityLayout {
    /// A single justified line containing word slices positioned between left margin `0` and `maxWidth`.
    public struct JustifiedWord: Sendable, Equatable {
        public var text: String
        public var x: Float
        public var width: Float
    }

    /// Computes horizontal positions of words on wrapped lines so non-final lines justify flush to `0...maxWidth`
    /// while preserving RTL right-edge origin when `isRTL == true`.
    public static func justifyLines(
        _ text: String,
        style: TextStyle,
        maxWidth: Float,
        isRTL: Bool = false,
        pixelScale: Float = 2.0,
        textSystem: TextSystem = TextSystem()
    ) -> [[JustifiedWord]] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return [] }
        let spaceW = max(style.size * 0.25, textSystem.shape(text: " ", style: style, maxWidth: nil, pixelScale: pixelScale).size.x)
        let measured = words.map { w -> (String, Float) in
            let sw = textSystem.shape(text: w, style: style, maxWidth: nil, pixelScale: pixelScale).size.x
            return (w, sw)
        }

        var rawLines: [[(String, Float)]] = []
        var cur: [(String, Float)] = []
        var curW: Float = 0
        for (w, ww) in measured {
            let extra = cur.isEmpty ? ww : spaceW + ww
            if !cur.isEmpty && curW + extra > maxWidth {
                rawLines.append(cur)
                cur = [(w, ww)]
                curW = ww
            } else {
                cur.append((w, ww))
                curW += extra
            }
        }
        if !cur.isEmpty { rawLines.append(cur) }

        var out: [[JustifiedWord]] = []
        for (lineIdx, line) in rawLines.enumerated() {
            let isLast = lineIdx == rawLines.count - 1
            let wordSum = line.reduce(Float(0)) { $0 + $1.1 }
            let gaps = max(1, line.count - 1)
            let gapW: Float
            if !isLast && line.count > 1 && wordSum < maxWidth {
                gapW = (maxWidth - wordSum) / Float(gaps)
            } else {
                gapW = spaceW
            }

            var lineOut: [JustifiedWord] = []
            if isRTL {
                // In RTL paragraphs, first logical word aligns from the right edge (`maxWidth`), moving leftward.
                var xRight = maxWidth
                if isLast {
                    // Right-aligned last line stays flush with `maxWidth` on the right edge.
                    for (w, ww) in line {
                        xRight -= ww
                        lineOut.append(JustifiedWord(text: w, x: xRight, width: ww))
                        xRight -= gapW
                    }
                } else {
                    for (w, ww) in line {
                        xRight -= ww
                        lineOut.append(JustifiedWord(text: w, x: max(0, xRight), width: ww))
                        xRight -= gapW
                    }
                }
            } else {
                var x: Float = 0
                for (w, ww) in line {
                    lineOut.append(JustifiedWord(text: w, x: x, width: ww))
                    x += ww + gapW
                }
            }
            out.append(lineOut)
        }
        return out
    }

    /// Computes padded decoration rectangles for inline-code spans inside shaped text (`paddingChip`).
    public static func inlineCodeChipRect(
        glyphMinX: Float,
        glyphMaxX: Float,
        lineY: Float,
        lineHeight: Float,
        padX: Float = 4.0,
        padY: Float = 1.0
    ) -> MotionRect {
        let w = max(0, (glyphMaxX - glyphMinX) + padX * 2.0)
        let h = max(0, lineHeight - padY * 2.0)
        return MotionRect.fromXYWH(glyphMinX - padX, lineY + padY, w, h)
    }
}
