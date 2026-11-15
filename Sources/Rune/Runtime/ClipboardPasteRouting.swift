import Foundation

// MARK: - Paste Routing, Clipboard Reads & Paste Forms
// Ports `clipboard.rs` (`Forms`, `Purpose`, `flush_memory`), `clipboard/tx.rs` (`read_clipboard`),
// `runtime/input/keys.rs` (`accepts_paste`, `paste_target`, `paste_forms`, `paste_result`) and
// `runtime/input/action.rs` (`Action::Paste`, `Action::ClipboardRead`).

extension Clipboard {
    /// The forms a paste target takes, so a read fetches no more than it needs (`clipboard::Forms`).
    public enum Forms: Sendable, Equatable {
        /// A plain field or a plain `onPaste`.
        case text
        /// A rich `TextEdit` with no hook: text, HTML and RTF.
        case rich
        /// A hook (`onInputPaste`, `onPasteContent`): every form, images too.
        case all
    }
}

extension ClipboardImage {
    /// Wraps PNG bytes, reading the size from the `IHDR` header (`ClipboardImage::from_png`).
    /// Returns `nil` for anything that is not a PNG of a valid size.
    public static func fromPNG(_ png: Data) -> ClipboardImage? {
        let bytes = [UInt8](png)
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count <= maxImageBytes, bytes.count >= 24,
              Array(bytes[0..<8]) == signature,
              Array(bytes[12..<16]) == Array("IHDR".utf8) else {
            return nil
        }
        func be(_ at: Int) -> UInt32 {
            (UInt32(bytes[at]) << 24) | (UInt32(bytes[at + 1]) << 16) | (UInt32(bytes[at + 2]) << 8) | UInt32(bytes[at + 3])
        }
        let w = be(16)
        let h = be(20)
        guard validSize(width: w, height: h) else { return nil }
        return ClipboardImage(width: w, height: h, pngData: png)
    }

    /// `content::valid_image_size`.
    static func validSize(width: UInt32, height: UInt32) -> Bool {
        width > 0 && height > 0 && UInt64(width) * UInt64(height) <= maxImagePixels
    }

    /// Width and height in pixels, from the PNG header (`ClipboardImage::size`).
    public var size: (width: UInt32, height: UInt32) { (width, height) }
}

extension ClipboardContent {
    /// HTML, RTF, an image or files beside the text (`ClipboardContent::is_rich`).
    public var isRich: Bool { html != nil || rtf != nil || image != nil || !files.isEmpty }
    /// No text and no other form (`ClipboardContent::is_empty`).
    public var isEmpty: Bool { text.isEmpty && !isRich }
    /// Plain consumers (a field without `onInputPaste`, a text `onPaste`) take it (`has_plain`).
    public var hasPlain: Bool { !text.isEmpty || !isRich }
    /// Content from another app, its HTML sanitised (`ClipboardContent::untrusted`).
    public func untrusted() -> ClipboardContent {
        var c = self
        if let html = c.html { c.html = ClipboardHTMLSanitizer.sanitize(html) }
        return c
    }
}

extension RichClipboardPayload {
    fileprivate var anyImage: ClipboardImage? { content.image ?? image }
    fileprivate var anyFiles: [URL] { files.isEmpty ? content.files : files }
    fileprivate var pasteIsRich: Bool {
        content.html != nil || content.rtf != nil || anyImage != nil || !anyFiles.isEmpty
    }
    fileprivate var pasteIsEmpty: Bool { content.text.isEmpty && !pasteIsRich }

    /// What a read for `forms` fetches (`Purpose::answer`): `.text` only when the clipboard has
    /// plain text (`Backend::text`); `.rich` the text forms (`text_forms`, `nil` when an image or
    /// files were all it had); `.all` every form.
    fileprivate func answer(_ forms: Clipboard.Forms) -> ClipboardContent? {
        switch forms {
        case .text:
            guard !content.text.isEmpty || !pasteIsRich else { return nil }
            return ClipboardContent(content.text)
        case .rich:
            let had = !pasteIsEmpty
            let textForms = ClipboardContent(content.text, html: content.html, rtf: content.rtf)
            return (!had || !textForms.isEmpty) ? textForms : nil
        case .all:
            return ClipboardContent(content.text, html: content.html, rtf: content.rtf, image: anyImage, files: anyFiles)
        }
    }
}

/// A `Tx.readClipboard` callback. Copies of a `Tx` share it; the runtime takes it once (`ClipboardRead`).
internal final class TxClipboardRead {
    typealias Fn = (_ state: inout Any, _ content: ClipboardContent, _ tx: inout Tx) -> Void
    private var fn: Fn?
    init(_ fn: @escaping Fn) { self.fn = fn }
    func take() -> Fn? {
        defer { fn = nil }
        return fn
    }
}

/// Queued clipboard replies, run in event order by the next frame (`Action::Paste`, `Action::ClipboardRead`).
internal enum ClipboardReply {
    /// A paste and, for a reply to a request, the target it was asked for (`Some(target)`).
    case paste(ClipboardContent, target: String??)
    case read(UInt64, ClipboardContent)
}

/// The runtime's paste and read bookkeeping (`Runtime::paste_request`, `read_requests`, `clipboard_reads`).
internal struct ClipboardRoutingState {
    var pasteRequest: String?? = nil
    var readRequests: [UInt64] = []
    var clipboardReads: [(id: UInt64, read: TxClipboardRead.Fn)] = []
    var nextClipboardRead: UInt64 = 0
    var replies: [ClipboardReply] = []
    var copies = ClipboardCopyState()
}

extension Tx {
    /// Reads the clipboard and hands what it holds to `body`, as an update, once it arrives: an
    /// empty `ClipboardContent` when it holds nothing readable. HTML is sanitised. Nothing is
    /// pasted anywhere (`Tx::read_clipboard`).
    public mutating func readClipboard<S>(_ body: @escaping (_ state: inout S, _ content: ClipboardContent, _ tx: inout Tx) -> Void) {
        clipboardReads.append(TxClipboardRead { stateBox, content, tx in
            guard var typed = stateBox as? S else { return }
            body(&typed, content, &tx)
            stateBox = typed
        })
    }
}

extension Runtime {
    // MARK: Targets

    private var appPasteRootIndex: Int? {
        activeModalPath.flatMap { nodeByPath[$0] } ?? (flatNodes.isEmpty ? nil : 0)
    }

    /// Whether the active modal or root has `onPaste`/`onPasteContent` (`app_paste_handler`).
    internal var hasAppPasteHandler: Bool {
        guard let idx = appPasteRootIndex else { return false }
        let h = flatNodes[idx].el.handlers
        return h.onPasteContent != nil || h.onPaste != nil
    }

    /// Whether a paste has anywhere to go: a focused editor or a window paste handler (`accepts_paste`).
    public var acceptsPaste: Bool {
        pasteTarget != nil || hasAppPasteHandler
    }

    /// The focused editable field's path, the target a paste is asked for (`paste_target`).
    public var pasteTarget: String? {
        guard let path = focusedPath,
              let el = focusedInputElement(at: path),
              el.handlers.editLens != nil else { return nil }
        return path
    }

    /// What the paste target hears (`paste_forms`): every form for a field with `onInputPaste`
    /// or a root `onPasteContent`; text, HTML and RTF for a rich `TextEdit`; only the text for
    /// anything else (a plain field, a plain `onPaste`).
    public func pasteForms(_ target: String?) -> Clipboard.Forms {
        if let path = target {
            guard let el = focusedInputElement(at: path) else { return .text }
            if el.handlers.onInputPaste != nil { return .all }
            if let lens = el.handlers.editLens {
                let edit = lens.get(state)
                if edit.isRichEnabled && !edit.isSecure && !el.isSecure { return .rich }
            }
            return .text
        }
        if let idx = appPasteRootIndex, flatNodes[idx].el.handlers.onPasteContent != nil { return .all }
        return .text
    }

    // MARK: Entry points

    /// Pastes `text` as the next frame's first input, wherever paste goes now (`Runtime::paste`).
    public func paste(_ text: String) {
        clipboardRouting.replies.append(.paste(ClipboardContent(text), target: nil))
    }

    /// `paste(_:)` with several forms, as from another app: its HTML is sanitised (`paste_content`).
    public func pasteContent(_ content: ClipboardContent) {
        clipboardRouting.replies.append(.paste(content.untrusted(), target: nil))
    }

    /// A clipboard reply for a paste asked for `target`. The next frame drops it if the paste
    /// target changed meanwhile (`paste_result`).
    public func pasteResult(target: String?, _ content: ClipboardContent) {
        clipboardRouting.replies.append(.paste(content, target: .some(target)))
    }

    /// A clipboard reply for `Tx.readClipboard` read `id` (`read_result`).
    internal func readResult(id: UInt64, _ content: ClipboardContent) {
        clipboardRouting.replies.append(.read(id, content))
    }

    /// Reads waiting for the clipboard (`Runtime::read_requests`).
    internal var readRequests: [UInt64] { clipboardRouting.readRequests }
    /// Read callbacks waiting for their reply (`Runtime::clipboard_reads`).
    internal var pendingClipboardReadIds: [UInt64] { clipboardRouting.clipboardReads.map(\.id) }

    // MARK: Latching and answering

    /// Latches a `Tx`'s paste and read requests and answers them from the clipboard at once
    /// (`latch_requests` + `flush_memory`).
    internal func latchClipboardRequests(_ tx: Tx) {
        if let copy = tx.runtimeActions[txSecretCopyKey] as? TxSecretCopy {
            applySecretCopy(copy)
        }
        if tx.pasteRequested {
            clipboardRouting.pasteRequest = .some(pasteTarget)
        }
        for read in tx.clipboardReads {
            guard let fn = read.take() else { continue }
            clipboardRouting.nextClipboardRead += 1
            let id = clipboardRouting.nextClipboardRead
            clipboardRouting.clipboardReads.append((id, fn))
            clipboardRouting.readRequests.append(id)
        }
        answerClipboardRequests()
    }

    /// What the clipboard holds now, or `nil` when it holds nothing: never written, cleared
    /// (`Board::clear` leaves no content) or an empty system clipboard. Without a bound
    /// `Clipboard`, the runtime's own last copy stands in for it.
    private func currentClipboardPayload() -> RichClipboardPayload? {
        if let board = boundClipboard {
            let payload = board.readRich(sanitizeUntrustedHTML: false)
            return payload.pasteIsEmpty ? nil : payload
        }
        let local = richClipboard.content == clipboard ? richClipboard : RichClipboardPayload(content: clipboard)
        return local.pasteIsEmpty ? nil : local
    }

    /// Answers the latched paste and reads (`flush_memory`): a paste skips an empty clipboard;
    /// a read always hears back.
    private func answerClipboardRequests() {
        guard clipboardRouting.pasteRequest != nil || !clipboardRouting.readRequests.isEmpty else { return }
        let payload = currentClipboardPayload()
        if let target = clipboardRouting.pasteRequest {
            clipboardRouting.pasteRequest = nil
            if let content = payload?.answer(pasteForms(target)) {
                pasteResult(target: target, markOwnPills(content.untrusted()))
            }
        }
        let reads = clipboardRouting.readRequests
        clipboardRouting.readRequests.removeAll()
        for id in reads {
            readResult(id: id, markOwnPills((payload?.answer(.all) ?? ClipboardContent()).untrusted()))
        }
    }

    /// Reads the clipboard for the current paste target and pastes now (a paste key or menu).
    /// Whenever something accepts a paste the command is consumed, even when the clipboard is
    /// empty or holds only an image (`physical.rs` edit command `v`).
    @discardableResult
    internal func pasteClipboardNow(at now: Double) -> Bool {
        guard acceptsPaste else { return false }
        let target = pasteTarget
        if let content = currentClipboardPayload()?.answer(pasteForms(target)) {
            runPasteReply(markOwnPills(content.untrusted()), target: .some(target), at: now)
        }
        return true
    }

    // MARK: Delivery

    /// Runs the queued clipboard replies in order (`Action::Paste`, `Action::ClipboardRead`).
    internal func flushPendingPasteRequests(at now: Double) {
        pollSecretCopy()
        guard !clipboardRouting.replies.isEmpty else { return }
        let replies = clipboardRouting.replies
        clipboardRouting.replies.removeAll()
        for reply in replies {
            switch reply {
            case .paste(let content, let target):
                runPasteReply(content, target: target, at: now)
            case .read(let id, let content):
                runClipboardRead(id: id, content, at: now)
            }
        }
    }

    @discardableResult
    internal func deliverPaste(_ content: ClipboardContent, at now: Double) -> Bool {
        runPasteReply(content, target: nil, at: now)
    }

    private func runClipboardRead(id: UInt64, _ content: ClipboardContent, at now: Double) {
        guard let i = clipboardRouting.clipboardReads.firstIndex(where: { $0.id == id }) else { return }
        let fn = clipboardRouting.clipboardReads.remove(at: i).read
        var tx = makeTx(at: now)
        var box: Any = state
        fn(&box, content, &tx)
        if let updated = box as? State { state = updated }
        applyTx(tx, at: now)
    }

    /// A paste into the focused field, else the window's paste handler. A reply asked for one
    /// target is dropped once the target changed (`Action::Paste`).
    @discardableResult
    private func runPasteReply(_ content: ClipboardContent, target: String??, at now: Double) -> Bool {
        if case .some(let asked) = target, asked != pasteTarget { return false }
        clipboard = content
        richClipboard = RichClipboardPayload(content: content)

        if let fPath = focusedPath, let fEl = focusedInputElement(at: fPath), let editLens = fEl.handlers.editLens {
            let before = editLens.get(state)
            var consumed = false
            if let hook = fEl.handlers.onInputPaste {
                var tx = makeTx(at: now)
                consumed = hook(&state, content, &tx)
                applyTx(tx, at: now)
            }
            if consumed {
                let after = editLens.get(state)
                if after.text != before.text {
                    deliverInputEdit(el: fEl, previousEdit: before, newEdit: after, editLens: editLens, at: now)
                } else {
                    dirtyCommit(at: now, why: CommitWhy.input)
                }
            } else {
                var edit = before
                let stateRevealed = edit.isRevealed
                if fEl.isSecure {
                    edit.isSecure = true
                    if fEl.isRevealed { edit.isRevealed = true }
                }
                if let html = content.html, edit.isRichEnabled && !edit.isSecure {
                    if content.ownPills {
                        edit.pasteHTMLWithPills(html, plain: content.text)
                    } else {
                        edit.pasteHTML(html, plain: content.text)
                    }
                } else if content.hasPlain {
                    edit.paste(content.text)
                }
                edit.isRevealed = stateRevealed
                if edit != before {
                    deliverInputEdit(el: fEl, previousEdit: before, newEdit: edit, editLens: editLens, at: now)
                }
            }
            logInputEvent("paste field")
            return true
        }

        guard let rIdx = appPasteRootIndex else { return false }
        let rootEl = flatNodes[rIdx].el
        if let onRich = rootEl.handlers.onPasteContent {
            var tx = makeTx(at: now)
            onRich(&state, content, &tx)
            applyTx(tx, at: now)
            logInputEvent("paste window")
            return true
        }
        if content.hasPlain, let onText = rootEl.handlers.onPaste {
            var tx = makeTx(at: now)
            onText(&state, content.text, &tx)
            applyTx(tx, at: now)
            logInputEvent("paste window")
            return true
        }
        return false
    }
}
