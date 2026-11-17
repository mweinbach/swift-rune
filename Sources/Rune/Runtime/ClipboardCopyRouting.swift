import Foundation

// MARK: - Concealed copies (`clipboard/tx.rs` `Tx::copy_secret`) and own pill copies (`Core::own_pills`)

internal let txSecretCopyKey = "secretClipboardWrite"

/// A pending `Tx.copySecret` write. Its description shows only its size (`ClipboardWrite`'s Debug).
internal struct TxSecretCopy: CustomStringConvertible, CustomDebugStringConvertible {
    let text: String
    let clearAfter: Double
    let slot: SecretSlot
    var description: String { "ClipboardWrite(concealed, \(text.utf8.count) bytes, clears after \(clearAfter)s)" }
    var debugDescription: String { description }
}

/// Routes a hold's early clear to the handle the bound `Clipboard` returned for the write.
internal final class SecretCopyRoute: SecretClipboardRoute, @unchecked Sendable {
    let handle: SecretClipboardHandle
    init(handle: SecretClipboardHandle) { self.handle = handle }
    func requestClear(slot: SecretSlot) {
        let cleared = handle.clearNow()
        slot.markReleased(cleared ? .cleared : handle.state)
    }
}

/// The pill copy written last, while the clipboard still holds that exact write (`OwnPills`).
internal struct OwnPillCopy {
    var revision: Int?
    var textPrint: Int
    var pills: [(range: Range<Int>, id: String)]
}

/// Concealed-copy and pill-copy bookkeeping kept beside `ClipboardRoutingState`.
internal struct ClipboardCopyState {
    /// A concealed copy asked for while no `Clipboard` is bound, left for the host (`copy_request`).
    var pendingConcealed: TxSecretCopy? = nil
    /// The concealed copy written last and its clear route.
    var held: (slot: SecretSlot, route: SecretCopyRoute)? = nil
    var ownPills: OwnPillCopy? = nil
}

extension Tx {
    /// Copies `text` as a concealed clipboard item that is cleared after `clearAfter` if the
    /// clipboard still holds it. The returned hold reports whether it still holds the clipboard
    /// and can clear it early. It replaces any other copy this handler asked for (`Tx::copy_secret`).
    @discardableResult
    public mutating func copySecret(_ text: String, clearAfter: Duration) -> SecretClipboardHold {
        let parts = clearAfter.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        let slot = SecretSlot()
        clipboardWrite = nil
        runtimeActions["richClipboardWrite"] = nil
        runtimeActions[txSecretCopyKey] = TxSecretCopy(text: text, clearAfter: seconds, slot: slot)
        return SecretClipboardHold(slot: slot)
    }
}

extension Runtime {
    /// The concealed copy waiting for a host when no `Clipboard` is bound (`copy_request`).
    internal var pendingConcealedCopy: TxSecretCopy? { clipboardRouting.copies.pendingConcealed }

    /// Writes a concealed copy to the bound clipboard, or leaves it for the host (`flush_memory`).
    internal func applySecretCopy(_ copy: TxSecretCopy) {
        copyRequest = nil
        clipboardRouting.copies.ownPills = nil
        guard let board = boundClipboard else {
            clipboardRouting.copies.pendingConcealed = copy
            return
        }
        clipboardRouting.copies.pendingConcealed = nil
        let handle = board.writeSecret(copy.text, ttlSeconds: copy.clearAfter)
        let route = SecretCopyRoute(handle: handle)
        copy.slot.route = route
        copy.slot.markHeld()
        clipboardRouting.copies.held = (copy.slot, route)
    }

    /// Reports a held concealed copy that was replaced or cleared to its hold (the worker's watch).
    internal func pollSecretCopy() {
        guard let held = clipboardRouting.copies.held else { return }
        let now = held.route.handle.state
        if now != .holding {
            held.slot.markReleased(now)
            clipboardRouting.copies.held = nil
        }
    }

    /// Remembers a pill copy so a paste of that exact write keeps its pills (`Core::write`).
    internal func recordOwnPills(_ content: ClipboardContent) {
        clipboardRouting.copies.ownPills = nil
        guard let html = content.html, html.contains("<span data-pill=") else { return }
        let pills = TextEdit.fromHTML(html).pills.map { (range: $0.range, id: $0.id) }
        guard !pills.isEmpty else { return }
        clipboardRouting.copies.ownPills = OwnPillCopy(
            revision: boundClipboard?.changeCount,
            textPrint: content.text.hashValue,
            pills: pills
        )
    }

    /// Marks a reply that still matches the pill copy written last (`Core::answer`).
    internal func markOwnPills(_ content: ClipboardContent) -> ClipboardContent {
        guard let own = clipboardRouting.copies.ownPills else { return content }
        if let rev = own.revision, rev != boundClipboard?.changeCount { return content }
        guard content.text.hashValue == own.textPrint, let html = content.html else { return content }
        let frag = TextEdit.fromHTML(html).pills
        guard frag.count == own.pills.count,
              zip(frag, own.pills).allSatisfy({ $0.range == $1.range && $0.id == $1.id }) else { return content }
        var marked = content
        marked.ownPills = true
        return marked
    }
}
