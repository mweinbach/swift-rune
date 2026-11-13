import Foundation
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

// MARK: - Host Input, Spell-Pause & Accessibility Announcements

extension Runtime {
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

    /// Posts a VoiceOver announcement on macOS via `NSAccessibility.post(..., .announcementRequested)`.
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
