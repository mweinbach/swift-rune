import Foundation
import RuneMotion

// MARK: - Runtime + Platform Input State Machines
// Implements per-element file drops (`runtime/input/drop.rs`), popup menu queueing
// (`runtime/input/popup.rs`), async file dialogs (`runtime/input/file_dialog.rs`),
// and outbound drag-out arming (`runtime/input/pointer.rs`).

extension Runtime {

    // MARK: - State Mutation Bridge

    internal func withErasedState(_ body: (inout Any, inout Tx) -> Void, at now: Double) {
        var tx = Tx()
        var boxed: Any = state
        body(&boxed, &tx)
        if let updated = boxed as? State {
            state = updated
        }
        applyTx(tx, at: now)
        if !tx.liveOnlyRequested {
            dirtyCommit(at: now)
        }
    }

    // MARK: - Per-Frame Flush & Reconciliation

    internal func flushPlatformFrameWork(at now: Double) {
        // 1. Deliver queued file dialog results on frame (`file_dialog.rs`)
        if !pendingFileDialogAnswers.isEmpty {
            let answers = pendingFileDialogAnswers
            pendingFileDialogAnswers.removeAll()
            for (onAnswer, result) in answers {
                withErasedState({ anyState, tx in
                    onAnswer(&anyState, result, &tx)
                }, at: now)
            }
        }

        // 2. Coalesce `onDropMove` to at most once per frame (`drop.rs` / `drop_tests.rs`)
        if let movePt = pendingDropMovePoint {
            pendingDropMovePoint = nil
            if let hoverPath = dropHoverPath,
               dropHoverAccepted,
               let files = draggedFiles,
               !filesHeld,
               let hit = dropTarget(byPath: hoverPath),
               let onMove = hit.spec.onDropMove,
               movePt != lastEmittedDropMovePoint {
                lastEmittedDropMovePoint = movePt
                var tx = Tx()
                tx.dropPoint = makeDropPoint(windowPos: movePt, rect: hit.rect)
                onMove(&state, files, &tx)
                applyTx(tx, at: now)
                if !tx.liveOnlyRequested {
                    dirtyCommit(at: now)
                }
            }
        }
    }

    internal func reconcileDropHoverAfterCommit(at now: Double) {
        guard let path = dropHoverPath else { return }
        if !dropTargetStillActive(path: path) {
            endDropHover(at: now)
        }
    }

    // MARK: - Per-Element OS File Drop (`runtime/input/drop.rs`)

    public var isDraggingFiles: Bool {
        draggedFiles != nil
    }

    public var dropHovered: String? {
        dropHoverKey ?? dropHoverPath
    }

    public var dropHoveredAccepted: Bool {
        dropHoverPath != nil && dropHoverAccepted
    }

    public var dropRejectedHovered: Bool {
        dropHoverPath != nil && !dropHoverAccepted
    }

    private func makeDropPoint(windowPos: Vec2, rect: MotionRect) -> PointerPress {
        PointerPress(
            window: windowPos,
            local: Vec2(windowPos.x - rect.left, windowPos.y - rect.top),
            elementSize: Vec2(rect.width, rect.height),
            button: .primary,
            mods: .none,
            clicks: 0
        )
    }

    private func endDropHover(at now: Double) {
        guard dropHoverPath != nil else { return }
        let endFn = activeDropHoverEnd
        dropHoverPath = nil
        dropHoverKey = nil
        dropHoverAccepted = false
        activeDropHoverEnd = nil
        pendingDropMovePoint = nil
        lastEmittedDropMovePoint = nil
        guard let endFn else { return }
        var tx = Tx()
        endFn(&state, &tx)
        applyTx(tx, at: now)
        if !tx.liveOnlyRequested {
            dirtyCommit(at: now)
        }
    }

    /// Updates active drop hover/move state for `urls` dragged at `point` in window coordinates.
    public func dragFiles(_ urls: [URL], at point: Vec2?, at now: Double = 0.0) {
        currentTime = now
        draggedFiles = urls
        draggedFilesPoint = point
        guard !filesHeld else { return }
        guard let pt = point, let hit = dropTargetHitTest(at: pt) else {
            endDropHover(at: now)
            return
        }

        let (accepted, _) = hit.spec.split(urls)
        let acceptsSome = !accepted.isEmpty

        if hit.path != dropHoverPath || acceptsSome != dropHoverAccepted {
            endDropHover(at: now)
            dropHoverPath = hit.path
            dropHoverKey = hit.key
            dropHoverAccepted = acceptsSome
            let spec = hit.spec
            if acceptsSome {
                activeDropHoverEnd = spec.onDropHover.map { cb in
                    { state, tx in cb(&state, false, &tx) }
                }
                if let cb = spec.onDropHover {
                    var tx = Tx()
                    tx.dropPoint = makeDropPoint(windowPos: pt, rect: hit.rect)
                    cb(&state, true, &tx)
                    applyTx(tx, at: now)
                    if !tx.liveOnlyRequested { dirtyCommit(at: now) }
                }
            } else {
                activeDropHoverEnd = spec.onDropRejectedHover.map { cb in
                    { state, tx in cb(&state, false, &tx) }
                }
                if let cb = spec.onDropRejectedHover {
                    var tx = Tx()
                    tx.dropPoint = makeDropPoint(windowPos: pt, rect: hit.rect)
                    cb(&state, true, &tx)
                    applyTx(tx, at: now)
                    if !tx.liveOnlyRequested { dirtyCommit(at: now) }
                }
            }
            if acceptsSome && spec.onDropMove != nil {
                pendingDropMovePoint = pt
            }
        } else if acceptsSome && hit.spec.onDropMove != nil {
            pendingDropMovePoint = pt
        }
    }

    /// Updates cursor position while dragging files previously supplied to `dragFiles`.
    public func dragFilesTo(_ point: Vec2, at now: Double = 0.0) {
        draggedFilesPoint = point
        guard let urls = draggedFiles else { return }
        dragFiles(urls, at: point, at: now)
    }

    /// Clears active file drag hover state when the drag exits the window or is cancelled.
    public func dragFilesLeave(at now: Double = 0.0) {
        currentTime = now
        draggedFiles = nil
        draggedFilesPoint = nil
        pendingDropMovePoint = nil
        lastEmittedDropMovePoint = nil
        endDropHover(at: now)
    }

    /// Pauses live drop hover while another window covers this view (`platform/macos/drop.rs`).
    public func holdFiles(at now: Double = 0.0) {
        guard !filesHeld else { return }
        filesHeld = true
        endDropHover(at: now)
    }

    /// Resumes drop hover if files are still being dragged across the view.
    public func releaseFiles(at now: Double = 0.0) {
        guard filesHeld else { return }
        filesHeld = false
        if let urls = draggedFiles {
            dragFiles(urls, at: draggedFilesPoint, at: now)
        }
    }

    /// Drops `urls` at `point` (or last known drag point), routing to the innermost drop zone
    /// and falling back to `onAppFileDrop` if no drop zone handled accepted files.
    @discardableResult
    public func dropFiles(_ urls: [URL], at point: Vec2? = nil, at now: Double = 0.0) -> Bool {
        currentTime = now
        let targetPt = point ?? draggedFilesPoint
        draggedFiles = nil
        draggedFilesPoint = nil
        pendingDropMovePoint = nil
        lastEmittedDropMovePoint = nil
        endDropHover(at: now)

        var handledByElement = false
        if let pt = targetPt, let hit = dropTargetHitTest(at: pt) {
            let (accepted, rejected) = hit.spec.split(urls)
            if !accepted.isEmpty, let onFiles = hit.spec.onDropFiles {
                var tx = Tx()
                tx.dropPoint = makeDropPoint(windowPos: pt, rect: hit.rect)
                onFiles(&state, accepted, &tx)
                applyTx(tx, at: now)
                if !tx.liveOnlyRequested { dirtyCommit(at: now) }
                handledByElement = true
            }
            if !rejected.isEmpty, let onRejected = hit.spec.onDropRejected {
                var tx = Tx()
                tx.dropPoint = makeDropPoint(windowPos: pt, rect: hit.rect)
                onRejected(&state, rejected, &tx)
                applyTx(tx, at: now)
                if !tx.liveOnlyRequested { dirtyCommit(at: now) }
            }
        }

        if !handledByElement, let appDrop = onAppFileDrop, !urls.isEmpty {
            var tx = Tx()
            if let pt = targetPt {
                tx.dropPoint = PointerPress(window: pt, local: pt, elementSize: viewport)
            }
            appDrop(&state, urls, &tx)
            applyTx(tx, at: now)
            if !tx.liveOnlyRequested { dirtyCommit(at: now) }
            handledByElement = true
        }
        return handledByElement
    }

    /// Returns whether `point` accepts any dragged `urls` (for `NSDraggingDestination` cursor feedback).
    public func acceptsDrop(_ urls: [URL], at point: Vec2) -> Bool {
        if let hit = dropTargetHitTest(at: point) {
            return !hit.spec.split(urls).accepted.isEmpty
        }
        return onAppFileDrop != nil || onFileDrop != nil
    }

    internal func routeFileDropPhase(_ phase: FileDropPhase, at now: Double) {
        switch phase {
        case .entered(let files, let pt):
            dragFiles(files.map(\.url), at: pt, at: now)
        case .hovered(let pt):
            dragFilesTo(pt, at: now)
        case .exited:
            dragFilesLeave(at: now)
        case .dropped(let files, let pt):
            _ = dropFiles(files.map(\.url), at: pt, at: now)
        }
    }

    // MARK: - Popup Menu Queue (`runtime/input/popup.rs`)

    public var popupMenu: PopupMenu? {
        popupQueue.front?.menu
    }

    public var popupIsOpen: Bool {
        popupQueue.isShowing
    }

    public var hasPopup: Bool {
        !popupQueue.isEmpty
    }

    public var popupWaitsForLayout: Bool {
        !popupQueue.isEmpty && popupNeedsLayout
    }

    internal func enqueuePopupRequest(_ req: ErasedPopupRequest) {
        switch popupQueue {
        case .closed:
            popupQueue = .queued([req])
        case .queued(var list):
            list.append(req)
            popupQueue = .queued(list)
        case .showing(let head, var rest):
            rest.append(req)
            popupQueue = .showing(head: head, rest: rest)
        }
        waker.wake()
    }

    /// Takes the next queued popup menu for native presentation (`nil` if none or waiting on layout).
    /// Returns `.failure` when the front request failed validation or its anchor key is missing
    /// (after answering its callback with `nil`), mirroring `open_popup_headless` / host loop.
    public func takePopup() -> Result<PopupShow, PopupMenuError>? {
        guard !popupWaitsForLayout else { return nil }
        guard case .queued(var list) = popupQueue, !list.isEmpty else {
            return nil
        }

        let head = list[0]
        do {
            try head.menu.validate()
        } catch let err as PopupMenuError {
            _ = popFrontAndAnswerNil(from: &list)
            return .failure(err)
        } catch {
            _ = popFrontAndAnswerNil(from: &list)
            return .failure(.unsupported)
        }

        let showAnchor: PopupShowAnchor
        switch head.anchor {
        case .point(let x, let y):
            showAnchor = .point(x, y)
        case .key(let key):
            guard let rect = anchorRect(forKey: key) else {
                _ = popFrontAndAnswerNil(from: &list)
                return .failure(.unsupported)
            }
            showAnchor = .rect(rect)
        }

        let rest = Array(list.dropFirst())
        popupQueue = .showing(head: head, rest: rest)
        releasePointerForPopup(at: currentTime)
        return .success(PopupShow(menu: head.menu, anchor: showAnchor))
    }

    /// Headless stand-in for host opening: opens next valid popup menu while automatically
    /// dismissing any invalid or missing-anchor head requests with `nil`.
    @discardableResult
    public func openPopupHeadless() -> PopupShow? {
        while let res = takePopup() {
            switch res {
            case .success(let show):
                return show
            case .failure:
                continue
            }
        }
        return nil
    }

    /// Answers the front popup menu (showing or queued) with `pickedId` or `nil` (dismissed).
    public func resolvePopup(_ pickedId: String?) throws {
        guard let front = popupQueue.front else {
            throw PopupMenuError.notOpen
        }
        if let id = pickedId {
            try front.menu.checkSelectable(id: id)
        }
        let popped: ErasedPopupRequest
        switch popupQueue {
        case .closed:
            throw PopupMenuError.notOpen
        case .queued(var list):
            popped = list.removeFirst()
            popupQueue = list.isEmpty ? .closed : .queued(list)
        case .showing(let head, let rest):
            popped = head
            popupQueue = rest.isEmpty ? .closed : .queued(rest)
        }

        withErasedState({ anyState, tx in
            popped.onPick(&anyState, pickedId, &tx)
        }, at: currentTime)
    }

    /// Dismisses open & queued popup menus with `nil` up to 64 iterations when a window goes away.
    public func cancelPopups() {
        for _ in 0..<64 {
            if (try? resolvePopup(nil)) == nil {
                return
            }
        }
        popupQueue = .closed
    }

    internal func popupJSONObject() -> [String: Any]? {
        guard let req = popupQueue.front else { return nil }
        var obj = req.menu.toJSONObject()
        obj["open"] = popupQueue.isShowing
        switch req.anchor {
        case .key(let k):
            obj["anchor"] = ["key": k]
        case .point(let x, let y):
            obj["anchor"] = ["x": x, "y": y]
        }
        obj["queued"] = max(0, popupQueue.count - 1)
        return obj
    }

    // MARK: - Async File Dialog State Machine (`runtime/input/file_dialog.rs`)

    public var fileDialog: FileDialogPending? {
        runtimeFileDialogState.entry?.pending
    }

    public var fileDialogIsShowing: Bool {
        runtimeFileDialogState.isShowing
    }

    internal func requestFileDialog(_ req: ErasedFileDialogRequest, at now: Double) {
        if nativeOverlay {
            pendingFileDialogAnswers.append((req.onAnswer, .failure(FileDialogError("overlays cannot open file dialogs"))))
            waker.wake()
            return
        }
        if runtimeFileDialogState.isOpen {
            pendingFileDialogAnswers.append((req.onAnswer, .failure(FileDialogError("a file dialog is already open"))))
            waker.wake()
            return
        }
        let id = nextFileDialogId
        nextFileDialogId += 1
        let pending = FileDialogPending(id: id, kind: req.kind, options: req.options)
        runtimeFileDialogState = .requested(ErasedFileDialogPendingEntry(pending: pending, onAnswer: req.onAnswer))
        waker.wake()
        _ = now
    }

    /// Takes a newly requested file dialog for the native host to present (transitions `.requested` -> `.showing`).
    public func takeFileDialog() -> FileDialogPending? {
        guard case .requested(let entry) = runtimeFileDialogState else {
            return nil
        }
        runtimeFileDialogState = .showing(entry)
        return entry.pending
    }

    /// Answers a taken (or requested) file dialog by ID; stale IDs are ignored.
    public func answerFileDialog(_ id: UInt64, _ result: FileDialogResult) {
        guard let entry = runtimeFileDialogState.entry, entry.pending.id == id else {
            return
        }
        runtimeFileDialogState = .closed
        pendingFileDialogAnswers.append((entry.onAnswer, result))
        waker.wake()
    }

    /// Headless convenience resolving whichever dialog is currently requested or showing.
    public func resolveFileDialog(_ url: URL?) throws {
        guard let entry = runtimeFileDialogState.entry else {
            throw FileDialogError("no file dialog is open")
        }
        answerFileDialog(entry.pending.id, .success(url))
    }

    /// Cancels any open file dialog on window hide/close, bounded to 64 chained re-requests.
    public func cancelFileDialogs(at now: Double = 0.0) {
        for _ in 0..<64 {
            if let entry = runtimeFileDialogState.entry {
                answerFileDialog(entry.pending.id, .success(nil))
            }
            guard !pendingFileDialogAnswers.isEmpty else { return }
            let batch = pendingFileDialogAnswers
            pendingFileDialogAnswers.removeAll()
            for (onAnswer, res) in batch {
                withErasedState({ anyState, tx in
                    onAnswer(&anyState, res, &tx)
                }, at: now)
            }
        }
        runtimeFileDialogState = .closed
        pendingFileDialogAnswers.removeAll()
    }

    internal func fileDialogJSONObject() -> [String: Any]? {
        runtimeFileDialogState.entry?.pending.toJSONObject()
    }

    // MARK: - Outbound Drag-Out (`runtime/input/pointer.rs`)

    public var isDraggingOut: Bool {
        activeDragOut != nil
    }

    public func takeDragOutStart() -> DragOutStart? {
        defer { pendingDragOutStart = nil }
        return pendingDragOutStart
    }

    internal func checkArmedDragOutMove(to pos: Vec2, at now: Double) -> Bool {
        guard let armed = armedDragOut else { return false }
        guard DragItem.pastThreshold(from: armed.startWindow, to: pos, threshold: armed.threshold) else {
            return false
        }
        armedDragOut = nil
        return startDragOut(path: armed.path, at: pos, fallbackBounds: armed.bounds, fallbackKey: armed.key, now: now)
    }

    @discardableResult
    internal func startDragOut(
        path: String,
        at pos: Vec2,
        fallbackBounds: MotionRect? = nil,
        fallbackKey: String? = nil,
        now: Double
    ) -> Bool {
        guard activeDragOut == nil else { return false }
        guard let nodeInfo = dragSourceNode(byPath: path) else { return false }
        let item = nodeInfo.dragOut?(state) ?? nodeInfo.attachedItem
        guard let item, !item.isEmpty else { return false }

        let bounds = nodeInfo.rect ?? fallbackBounds ?? .zero
        let key = nodeInfo.key ?? fallbackKey
        activeDragOut = (path: path, key: key, onEnd: nodeInfo.onEnd)
        pendingDragOutStart = DragOutStart(item: item, bounds: bounds, press: pos, key: key)
        fileDropState.recordOutboundDrag(item)
        releasePointerForDragOut(at: now)
        if let onStart = nodeInfo.onStart {
            var tx = Tx()
            onStart(&state, &tx)
            applyTx(tx, at: now)
            if !tx.liveOnlyRequested { dirtyCommit(at: now) }
        }
        return true
    }

    /// Completes an active outbound drag session and guarantees 1:1 `onDragOutEnd` pairing.
    public func finishDragOut(_ outcome: DragOutcome, at now: Double = 0.0) {
        currentTime = now
        guard let active = activeDragOut else { return }
        activeDragOut = nil
        let handler = dragOutEndHandler(byPath: active.path) ?? active.onEnd
        guard let handler else { return }
        var tx = Tx()
        handler(&state, outcome, &tx)
        applyTx(tx, at: now)
        if !tx.liveOnlyRequested { dirtyCommit(at: now) }
    }

    // MARK: - Private Helpers

    private func popFrontAndAnswerNil(from list: inout [ErasedPopupRequest]) -> ErasedPopupRequest {
        let head = list.removeFirst()
        let prevCount = list.count
        popupQueue = list.isEmpty ? .closed : .queued(list)
        let prevNeedsLayout = popupNeedsLayout
        withErasedState({ anyState, tx in
            head.onPick(&anyState, nil, &tx)
        }, at: currentTime)
        if popupQueue.count == prevCount {
            popupNeedsLayout = prevNeedsLayout
        }
        return head
    }
}

extension PopupShow {
    /// Window-space origin (`at`) and minimum width computed like `popup_menu/mod.rs`.
    public func placement(isRTL: Bool = false) -> (at: Vec2, positionedId: String?, minWidth: Float) {
        switch anchor {
        case .point(let x, let y):
            return (Vec2(x, y), menu.selectedId, 0)
        case .rect(let r):
            let posId = menu.selectedId
            let x = isRTL ? r.right : r.left
            let y = (posId != nil) ? r.top : r.bottom
            return (Vec2(x, y), posId, r.width)
        }
    }
}
