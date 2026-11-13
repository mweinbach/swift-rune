import Foundation
import RuneMotion

// MARK: - Runtime + Platform Input State Machines
// Implements per-element file drops (`runtime/input/drop.rs`), popup menu queueing
// (`runtime/input/popup.rs`), async file dialogs (`runtime/input/file_dialog.rs`),
// and outbound drag-out arming (`runtime/input/pointer.rs`).

extension Runtime {

    // MARK: - State Mutation Bridge

    internal func withErasedState(_ body: (inout Any, inout Tx) -> Void, at now: Double) {
        if playgroundWithErasedState(body, at: now) {
            return
        }
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
        pendingDropHoverChanged = false

        // 0. If no commit is pending, replay any hidden drop steps on the current tree
        if !needsCommit {
            flushHiddenDropSteps(at: now)
        }

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

    internal func flushHiddenDropSteps(at now: Double) {
        guard !pendingHiddenDrops.isEmpty else { return }
        let steps = pendingHiddenDrops
        pendingHiddenDrops.removeAll()
        for step in steps {
            switch step {
            case .drag(let urls, let pt, let t):
                performDragFiles(urls, at: pt, at: t)
            case .dragTo(let pt, let t):
                _ = performDragFilesTo(pt, at: t)
            case .leave(let t):
                performDragFilesLeave(at: t)
            case .drop(let urls, let pt, let t):
                _ = performDropFiles(urls, at: pt, at: t)
            }
        }
    }

    /// Updates active drop hover/move state for `urls` dragged at `point` in window coordinates.
    public func dragFiles(_ urls: [URL], at point: Vec2?, at now: Double = 0.0) {
        if !liveVisible {
            pendingHiddenDrops.append(.drag(urls: urls, point: point, at: now))
            return
        }
        performDragFiles(urls, at: point, at: now)
    }

    private func performDragFiles(_ urls: [URL], at point: Vec2?, at now: Double) {
        currentTime = now
        let oldPath = dropHoverPath
        let oldAccepted = dropHoverAccepted
        draggedFiles = urls
        draggedFilesPoint = point
        guard !filesHeld else { return }
        guard let pt = point, let hit = dropTargetHitTest(at: pt, for: urls) else {
            endDropHover(at: now)
            if dropHoverPath != oldPath || dropHoverAccepted != oldAccepted {
                pendingDropHoverChanged = true
            }
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
        } else if acceptsSome && hit.spec.onDropMove != nil && pt != lastEmittedDropMovePoint {
            pendingDropMovePoint = pt
        }
        if dropHoverPath != oldPath || dropHoverAccepted != oldAccepted {
            pendingDropHoverChanged = true
        }
    }

    /// Updates cursor position while dragging files previously supplied to `dragFiles`.
    /// Returns `true` only when hover state changed or a new per-frame `onDropMove` wake is needed.
    @discardableResult
    public func dragFilesTo(_ point: Vec2, at now: Double = 0.0) -> Bool {
        if !liveVisible {
            pendingHiddenDrops.append(.dragTo(point: point, at: now))
            return true
        }
        return performDragFilesTo(point, at: now)
    }

    private func performDragFilesTo(_ point: Vec2, at now: Double) -> Bool {
        let oldPath = dropHoverPath
        let oldAccepted = dropHoverAccepted
        let hadMove = pendingDropMovePoint != nil
        draggedFilesPoint = point
        guard let urls = draggedFiles else { return false }
        performDragFiles(urls, at: point, at: now)
        let hoverChanged = (dropHoverPath != oldPath) || (dropHoverAccepted != oldAccepted)
        let scheduledMove = !hadMove && pendingDropMovePoint != nil
        return hoverChanged || scheduledMove
    }

    /// Clears active file drag hover state when the drag exits the window or is cancelled.
    public func dragFilesLeave(at now: Double = 0.0) {
        if !liveVisible {
            pendingHiddenDrops.append(.leave(at: now))
            return
        }
        performDragFilesLeave(at: now)
    }

    private func performDragFilesLeave(at now: Double) {
        currentTime = now
        draggedFiles = nil
        draggedFilesPoint = nil
        pendingDropMovePoint = nil
        lastEmittedDropMovePoint = nil
        pendingDropHoverChanged = false
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
        if !liveVisible {
            pendingHiddenDrops.append(.drop(urls: urls, point: point, at: now))
            return false
        }
        return performDropFiles(urls, at: point, at: now)
    }

    private func performDropFiles(_ urls: [URL], at point: Vec2?, at now: Double) -> Bool {
        currentTime = now
        let targetPt = point ?? draggedFilesPoint
        if let movePt = pendingDropMovePoint,
           let hoverPath = dropHoverPath,
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
        draggedFiles = nil
        draggedFilesPoint = nil
        pendingDropMovePoint = nil
        lastEmittedDropMovePoint = nil
        pendingDropHoverChanged = false
        endDropHover(at: now)

        var handledByElement = false
        let resolvedHit: (path: String, key: String?, rect: MotionRect, spec: DropSpec<State>)? =
            targetPt.flatMap { dropTargetHitTest(at: $0, for: urls) } ?? (targetPt == nil ? rootDropTarget(for: urls) : nil)
        if let hit = resolvedHit {
            let (accepted, rejected) = hit.spec.split(urls)
            if !accepted.isEmpty, let onFiles = hit.spec.onDropFiles {
                var tx = Tx()
                if let pt = targetPt {
                    tx.dropPoint = makeDropPoint(windowPos: pt, rect: hit.rect)
                }
                onFiles(&state, accepted, &tx)
                applyTx(tx, at: now)
                if !tx.liveOnlyRequested { dirtyCommit(at: now) }
                handledByElement = true
            }
            if !rejected.isEmpty, let onRejected = hit.spec.onDropRejected {
                var tx = Tx()
                if let pt = targetPt {
                    tx.dropPoint = makeDropPoint(windowPos: pt, rect: hit.rect)
                }
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
        if let hit = dropTargetHitTest(at: point, for: urls) {
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

// MARK: - Rich HTML Selection Copy (`runtime/selection/copy_html.rs`, #832)

/// Rich text selection slice passed to `ClipboardHTMLBuilder.render`.
public struct SelectionHTMLSlice: Sendable, Equatable {
    public var role: ElementRole
    public var blockTag: String?
    public var headingLevel: Int?
    public var isHidden: Bool
    public var isOrderedListItem: Bool
    public var groupId: String
    public var rowId: String
    public var isHeaderCell: Bool
    public var isMonospaceBlock: Bool
    public var text: String
    public var baseWeight: Float
    public var baseItalic: Bool
    public var spans: [TextSpan]
    public var links: [(utf8Range: Range<Int>, url: String)]
    public var strikes: [Range<Int>]
    public var utf8Range: Range<Int>
    public var besidePrevious: Bool

    public init(
        role: ElementRole = .text,
        blockTag: String? = nil,
        headingLevel: Int? = nil,
        isHidden: Bool = false,
        isOrderedListItem: Bool = false,
        groupId: String = "",
        rowId: String = "",
        isHeaderCell: Bool = false,
        isMonospaceBlock: Bool = false,
        text: String,
        baseWeight: Float = 400,
        baseItalic: Bool = false,
        spans: [TextSpan] = [],
        links: [(utf8Range: Range<Int>, url: String)] = [],
        strikes: [Range<Int>] = [],
        utf8Range: Range<Int>? = nil,
        besidePrevious: Bool = false
    ) {
        self.role = role
        self.blockTag = blockTag
        self.headingLevel = headingLevel
        self.isHidden = isHidden
        self.isOrderedListItem = isOrderedListItem
        self.groupId = groupId
        self.rowId = rowId
        self.isHeaderCell = isHeaderCell
        self.isMonospaceBlock = isMonospaceBlock
        self.text = text
        self.baseWeight = baseWeight
        self.baseItalic = baseItalic
        self.spans = spans
        self.links = links
        self.strikes = strikes
        self.utf8Range = utf8Range ?? (0..<text.utf8.count)
        self.besidePrevious = besidePrevious
    }

    public static func == (lhs: SelectionHTMLSlice, rhs: SelectionHTMLSlice) -> Bool {
        lhs.role == rhs.role &&
            lhs.blockTag == rhs.blockTag &&
            lhs.headingLevel == rhs.headingLevel &&
            lhs.isHidden == rhs.isHidden &&
            lhs.isOrderedListItem == rhs.isOrderedListItem &&
            lhs.groupId == rhs.groupId &&
            lhs.rowId == rhs.rowId &&
            lhs.isHeaderCell == rhs.isHeaderCell &&
            lhs.isMonospaceBlock == rhs.isMonospaceBlock &&
            lhs.text == rhs.text &&
            lhs.baseWeight == rhs.baseWeight &&
            lhs.baseItalic == rhs.baseItalic &&
            lhs.spans == rhs.spans &&
            lhs.strikes == rhs.strikes &&
            lhs.utf8Range == rhs.utf8Range &&
            lhs.besidePrevious == rhs.besidePrevious &&
            lhs.links.count == rhs.links.count &&
            zip(lhs.links, rhs.links).allSatisfy { $0.utf8Range == $1.utf8Range && $0.url == $1.url }
    }
}

/// Converts selected styled text blocks into HTML (`<h1>..<h6>`, `<ul>`/`<ol>`, `<table>`, `<pre><code>`, `<p>`, inline formatting & links) matching upstream `copy_html.rs` (#832).
public enum ClipboardHTMLBuilder {
    private enum Block: Equatable {
        case heading(id: String, level: Int)
        case item(listId: String, itemId: String, ordered: Bool)
        case cell(tableId: String, rowId: String, cellId: String, head: Bool)
        case code(id: String)
        case paragraph(id: String)
    }

    public static func render(_ slices: [SelectionHTMLSlice]) -> String? {
        guard !slices.isEmpty else { return nil }
        var out = ""
        var prev: Block? = nil
        var openLists: [(listId: String, itemId: String, ordered: Bool)] = []

        func closeLists(keep: Int) {
            while openLists.count > keep {
                let top = openLists.removeLast()
                out += top.ordered ? "</li></ol>" : "</li></ul>"
            }
        }

        for (index, slice) in slices.enumerated() {
            let block = classify(slice, index: index)
            if slice.isHidden, case .item = block {
                continue
            }
            let inline = renderInline(slice)
            if inline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            if let prevBlock = prev, prevBlock == block {
                if slice.besidePrevious && !out.hasSuffix(" ") && !inline.hasPrefix(" ") {
                    out += " "
                } else if !slice.besidePrevious {
                    out += "<br>"
                }
            } else {
                if let prevBlock = prev {
                    if case .item = prevBlock {} else {
                        close(prevBlock, next: block, into: &out)
                    }
                }
                switch block {
                case let .item(listId, itemId, ordered):
                    let keep = openLists.lastIndex(where: { $0.listId == listId }).map { $0 + 1 } ?? 0
                    closeLists(keep: keep)
                    if let last = openLists.last, last.listId == listId {
                        out += "</li><li>"
                        openLists[openLists.count - 1].itemId = itemId
                    } else {
                        out += ordered ? "<ol><li>" : "<ul><li>"
                        openLists.append((listId: listId, itemId: itemId, ordered: ordered))
                    }
                default:
                    closeLists(keep: 0)
                    open(block, prev: prev, into: &out)
                }
            }

            out += inline
            prev = block
        }

        guard let finalPrev = prev else { return nil }
        if case .item = finalPrev {} else {
            close(finalPrev, next: nil, into: &out)
        }
        closeLists(keep: 0)
        return out
    }

    private static func classify(_ s: SelectionHTMLSlice, index: Int) -> Block {
        let tag = s.blockTag?.lowercased()
        if s.role == .heading || tag == "heading" || s.headingLevel != nil {
            let level = min(6, max(1, s.headingLevel ?? 2))
            return .heading(id: s.groupId.isEmpty ? "h-\(index)" : s.groupId, level: level)
        }
        if s.role == .listItem || tag == "listitem" {
            let listId = s.groupId.isEmpty ? "list-0" : s.groupId
            let itemId = s.rowId.isEmpty ? "item-\(index)" : s.rowId
            return .item(listId: listId, itemId: itemId, ordered: s.isOrderedListItem)
        }
        if tag == "cell" || tag == "columnheader" || tag == "rowheader" || tag == "td" || tag == "th" || s.isHeaderCell {
            let tableId = s.groupId.isEmpty ? "table-0" : s.groupId
            let rowId = s.rowId.isEmpty ? "row-0" : s.rowId
            return .cell(tableId: tableId, rowId: rowId, cellId: "cell-\(index)", head: s.isHeaderCell || (tag != "cell" && tag != "td"))
        }
        if s.isMonospaceBlock || tag == "code" {
            return .code(id: s.groupId.isEmpty ? "code-0" : s.groupId)
        }
        return .paragraph(id: s.groupId.isEmpty ? "p-\(index)" : s.groupId)
    }

    private static func open(_ block: Block, prev: Block?, into out: inout String) {
        switch block {
        case let .heading(_, level):
            out += "<h\(level)>"
        case .item:
            break
        case let .cell(tableId, rowId, _, head):
            let sameTable: Bool
            let sameRow: Bool
            if case let .cell(pt, pr, _, _) = prev {
                sameTable = (pt == tableId)
                sameRow = (pt == tableId && pr == rowId)
            } else {
                sameTable = false
                sameRow = false
            }
            if !sameTable { out += "<table>" }
            if !sameRow { out += "<tr>" }
            out += head ? "<th>" : "<td>"
        case .code:
            out += "<pre><code>"
        case .paragraph:
            out += "<p>"
        }
    }

    private static func close(_ block: Block, next: Block?, into out: inout String) {
        switch block {
        case let .heading(_, level):
            out += "</h\(level)>"
        case .item:
            break
        case let .cell(tableId, rowId, _, head):
            out += head ? "</th>" : "</td>"
            let sameTable: Bool
            let sameRow: Bool
            if case let .cell(nt, nr, _, _) = next {
                sameTable = (nt == tableId)
                sameRow = (nt == tableId && nr == rowId)
            } else {
                sameTable = false
                sameRow = false
            }
            if !sameRow { out += "</tr>" }
            if !sameTable { out += "</table>" }
        case .code:
            out += "</code></pre>"
        case .paragraph:
            out += "</p>"
        }
    }

    private static func renderInline(_ slice: SelectionHTMLSlice) -> String {
        let utf8 = Array(slice.text.utf8)
        let len = utf8.count
        let start = min(max(0, slice.utf8Range.lowerBound), len)
        let end = min(max(start, slice.utf8Range.upperBound), len)
        guard start < end else { return "" }

        var spanRanges: [(range: Range<Int>, span: TextSpan)] = []
        if !slice.spans.isEmpty {
            var cursor = 0
            for sp in slice.spans {
                let spLen = sp.text.utf8.count
                let spRange = cursor..<(cursor + spLen)
                spanRanges.append((spRange, sp))
                cursor += spLen
            }
        }

        var cuts: Set<Int> = [start, end]
        for (r, _) in spanRanges {
            if r.lowerBound >= start && r.lowerBound <= end { cuts.insert(r.lowerBound) }
            if r.upperBound >= start && r.upperBound <= end { cuts.insert(r.upperBound) }
        }
        for (r, _) in slice.links {
            if r.lowerBound >= start && r.lowerBound <= end { cuts.insert(r.lowerBound) }
            if r.upperBound >= start && r.upperBound <= end { cuts.insert(r.upperBound) }
        }
        for r in slice.strikes {
            if r.lowerBound >= start && r.lowerBound <= end { cuts.insert(r.lowerBound) }
            if r.upperBound >= start && r.upperBound <= end { cuts.insert(r.upperBound) }
        }
        let sortedCuts = cuts.sorted()
        var out = ""
        var activeHref: String? = nil

        for idx in 0..<(sortedCuts.count - 1) {
            let s = sortedCuts[idx]
            let e = sortedCuts[idx + 1]
            guard s < e else { continue }
            guard let textPiece = String(bytes: utf8[s..<e], encoding: .utf8), !textPiece.isEmpty else { continue }

            let spanMatches = spanRanges.filter { $0.range.lowerBound <= s && e <= $0.range.upperBound }.map(\.span)
            let isBold = (spanMatches.contains { ($0.weight ?? 0) >= 600 } || slice.baseWeight >= 600)
            let isItalic = (spanMatches.contains { $0.italic }) && !slice.baseItalic
            let isCode = spanMatches.contains { $0.monospace }
            let isStruck = spanMatches.contains { $0.strikethrough } || slice.strikes.contains { $0.lowerBound <= s && e <= $0.upperBound }
            let href = slice.links.first {
                $0.utf8Range.lowerBound <= s && e <= $0.utf8Range.upperBound &&
                    ($0.url.contains("://") || $0.url.hasPrefix("mailto:"))
            }?.url

            if activeHref != href {
                if activeHref != nil { out += "</a>" }
                if let h = href { out += "<a href=\"\(escapeHTML(h))\">" }
                activeHref = href
            }

            var piece = escapeHTML(textPiece).replacingOccurrences(of: "\n", with: "<br>")
            if isCode { piece = "<code>\(piece)</code>" }
            if isStruck { piece = "<s>\(piece)</s>" }
            if isItalic { piece = "<em>\(piece)</em>" }
            if isBold && slice.baseWeight < 600 { piece = "<strong>\(piece)</strong>" }
            out += piece
        }
        if activeHref != nil { out += "</a>" }
        return out
    }

    public static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
