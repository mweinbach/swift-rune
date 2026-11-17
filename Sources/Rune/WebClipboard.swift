import Foundation

#if os(WASI)
/// System clipboard access in a browser is event-scoped. Only a user paste supplies a
/// synchronous read. `Tx.readClipboard` is the asynchronous API outside that event.
final class WebSystemClipboard: @unchecked Sendable {
    static let shared = WebSystemClipboard()
    private let lock = NSLock()
    private var mounted = false
    private var writes: [RichClipboardPayload] = []
    private var pasted: RichClipboardPayload?

    func mount(_ enabled: Bool) {
        lock.withLock {
            mounted = enabled
            writes.removeAll()
            pasted = nil
        }
    }

    func enqueue(_ content: RichClipboardPayload) -> Int? {
        lock.withLock {
            guard mounted, !content.isConcealed else { return nil }
            writes.append(content)
            return 0 // The browser does not expose clipboard ownership or a change counter.
        }
    }

    func takeWrites() -> [RichClipboardPayload] {
        lock.withLock {
            defer { writes.removeAll(keepingCapacity: true) }
            return writes
        }
    }

    func duringPaste<T>(_ payload: RichClipboardPayload, _ body: () -> T) -> T {
        let previous = lock.withLock {
            let previous = pasted
            pasted = payload
            return previous
        }
        defer { lock.withLock { pasted = previous } }
        return body()
    }

    var currentPaste: RichClipboardPayload { lock.withLock { pasted ?? RichClipboardPayload() } }
}
#endif

/// Clipboard events carry the permitted text representations. Navigator.clipboard also supports PNG.
struct WebClipboardContent: Codable {
    var text: String
    var html: String?
    var rtf: String?
    var png: Data?

    init(_ source: ClipboardContent, image: ClipboardImage? = nil) {
        text = source.text
        html = source.html
        rtf = source.rtf
        png = (image ?? source.image)?.pngData
    }

    var untrusted: ClipboardContent {
        ClipboardContent(text, html: html, rtf: rtf, image: png.flatMap(ClipboardImage.fromPNG)).untrusted()
    }
}

@MainActor
final class WebClipboardSession<State> {
    private struct Request: Encodable {
        let operation: String
        var id: String?
        var content: WebClipboardContent?
        var forms: String?
    }
    private enum ReadPurpose {
        case paste(String?)
        case read(UInt64)
    }
    private struct CutSelection {
        let path: String
        let anchor, cursor: Int
        let text: String
    }

    private let host: WebAppHost<State>
    private var requests: [Request] = []
    private var reads: [String: ReadPurpose] = [:]
    private var nextID: UInt64 = 0
    private var pendingCut: CutSelection?

    init(_ host: WebAppHost<State>) {
        self.host = host
        host.runtime.clipboardRouting.hostAnswersRequests = true
        #if os(WASI)
        WebSystemClipboard.shared.mount(true)
        #endif
    }

    // A native cut first asks for the selection. The page commits the edit only after
    // the browser accepts the data, which leaves the selection intact on refusal.
    func copySelection(forCut: Bool) -> Bool {
        pendingCut = nil
        let rt = host.runtime
        let content: ClipboardContent
        if let path = rt.focusedPath, let el = rt.focusedInputElement(at: path), let lens = el.handlers.editLens {
            let edit = lens.get(rt.state)
            guard !el.isSecure, !edit.isSecure, let text = edit.copy(), !forCut || el.hasEditAccess else { return false }
            let html = edit.isRichEnabled ? edit.toHTML(range: edit.selectedUTF8Range) : nil
            content = ClipboardContent(text, html: html)
            if forCut { pendingCut = CutSelection(path: path, anchor: edit.anchor, cursor: edit.cursor, text: text) }
        } else {
            guard !forCut, let text = rt.copySelectionText() else { return false }
            content = ClipboardContent(text, html: rt.copySelectionHTML())
        }
        requests.append(Request(operation: "selection", content: WebClipboardContent(content)))
        return true
    }

    func finishCut(at now: Double) -> Bool {
        let rt = host.runtime
        guard let cut = pendingCut else { return false }
        pendingCut = nil
        guard let key = rt.focusedPath, key == cut.path, let el = rt.focusedInputElement(at: key),
              el.hasEditAccess, !el.isSecure, let lens = el.handlers.editLens else { return false }
        let edit = lens.get(rt.state)
        guard !edit.isSecure, edit.anchor == cut.anchor, edit.cursor == cut.cursor,
              edit.selectedText.utf8.elementsEqual(cut.text.utf8) else { return false }
        let mods = ChordBits.modsFromBits(ChordBits.primary, platform: .current)
        let handled = host.handleKeyDown(code: "KeyX", key: "x", mods: mods,
                                         fromField: true, at: now)
        _ = rt.takeCopyRequest() // This cut has already written the browser clipboard.
        return handled
    }

    func cancelCut() { pendingCut = nil }

    func paste(_ value: WebClipboardContent, at now: Double) -> Bool {
        let rt = host.runtime
        guard rt.acceptsPaste else { return false }
        if let target = rt.pasteTarget, rt.focusedInputElement(at: target)?.hasEditAccess != true { return false }
        let incoming = RichClipboardPayload(content: value.untrusted)
        guard !incoming.pasteIsEmpty, let content = incoming.answer(rt.pasteForms(rt.pasteTarget)) else { return false }
        defer { host.syncField(activate: false) }
        #if os(WASI)
        return WebSystemClipboard.shared.duringPaste(incoming) {
            rt.hostInput(.keyPress) { rt.deliverPaste(content, at: now) }
        }
        #else
        return rt.hostInput(.keyPress) { rt.deliverPaste(content, at: now) }
        #endif
    }

    func prepareImagePaste() -> Bool {
        let rt = host.runtime
        guard rt.acceptsPaste, rt.pasteForms(rt.pasteTarget) == .all else { return false }
        if let target = rt.pasteTarget, rt.focusedInputElement(at: target)?.hasEditAccess != true { return false }
        enqueueRead(.paste(rt.pasteTarget), fromEvent: true)
        return true
    }

    func finishRead(_ id: String, value: WebClipboardContent?) -> Bool {
        guard let purpose = reads.removeValue(forKey: id) else { return false }
        let rt = host.runtime
        let content = value?.untrusted ?? ClipboardContent()
        switch purpose {
        case .read(let readID):
            rt.readResult(id: readID, content)
        case .paste(let target):
            let incoming = RichClipboardPayload(content: content)
            if !incoming.pasteIsEmpty, let answer = incoming.answer(rt.pasteForms(target)) {
                rt.pasteResult(target: target, answer)
            }
        }
        return true
    }

    private func enqueueRead(_ purpose: ReadPurpose, fromEvent: Bool = false) {
        nextID &+= 1
        let id = String(nextID)
        reads[id] = purpose
        let forms: Clipboard.Forms
        switch purpose {
        case .paste(let target): forms = host.runtime.pasteForms(target)
        case .read: forms = .all
        }
        let formName: String
        switch forms {
        case .text: formName = "text"
        case .rich: formName = "rich"
        case .all: formName = "all"
        }
        requests.append(Request(operation: fromEvent ? "eventRead" : "read", id: id, forms: formName))
    }

    private func enqueueWrite(_ payload: RichClipboardPayload) {
        if payload.isConcealed {
            requests.append(Request(operation: "concealed"))
            return
        }
        let content = WebClipboardContent(payload.content, image: payload.image)
        if content.text.isEmpty, content.html == nil, content.rtf == nil, content.png == nil,
           !payload.files.isEmpty || !payload.customPayloads.isEmpty {
            requests.append(Request(operation: "unsupported"))
            return
        }
        requests.append(Request(operation: "write", content: content))
    }

    func takeRequests() -> Data? {
        let rt = host.runtime
        #if os(WASI)
        for payload in WebSystemClipboard.shared.takeWrites() {
            enqueueWrite(payload)
        }
        #endif
        if let secret = rt.clipboardRouting.copies.pendingConcealed {
            secret.slot.markReleased(.failed("Browsers cannot own and expire a concealed clipboard item"))
            rt.clipboardRouting.copies.pendingConcealed = nil
            requests.append(Request(operation: "concealed"))
        }
        if rt.takeCopyRequest() != nil {
            enqueueWrite(rt.richClipboard)
        }
        if let target = rt.clipboardRouting.pasteRequest {
            rt.clipboardRouting.pasteRequest = nil
            enqueueRead(.paste(target))
        }
        for id in rt.clipboardRouting.readRequests { enqueueRead(.read(id)) }
        rt.clipboardRouting.readRequests.removeAll(keepingCapacity: true)
        guard !requests.isEmpty else { return nil }
        defer { requests.removeAll(keepingCapacity: true) }
        return try? JSONEncoder().encode(requests)
    }
}
