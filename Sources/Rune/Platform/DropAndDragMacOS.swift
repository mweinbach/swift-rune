import Foundation
import RuneMotion

#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - Cross-Platform Testable Drop Naming & Drag-Out Helpers

/// Pure path/extension helpers for macOS drop pasteboard temp extraction and hover stand-ins
/// (`platform/macos/drop.rs`).
public enum DropTempNaming {
    public static let imageTypeExtensions: [(uti: String, ext: String, needsPNGConversion: Bool)] = [
        ("public.png", "png", false),
        ("public.jpeg", "jpg", false),
        ("com.compuserve.gif", "gif", false),
        ("org.webmproject.webp", "webp", false),
        ("public.heic", "heic", false),
        ("public.tiff", "png", true),
    ]

    public static func imageExtension(forUTI uti: String) -> (ext: String, needsPNGConversion: Bool)? {
        let lower = uti.lowercased()
        for entry in imageTypeExtensions where entry.uti == lower {
            return (entry.ext, entry.needsPNGConversion)
        }
        return nil
    }

    /// Generates an unused file name (`stem.ext`, `stem-2.ext`, `stem-3.ext`, ...).
    public static func freeName(stem: String, ext: String, existing: Set<String>) -> String {
        let cleanStem = safeFileStem(stem, fallback: "Item")
        let cleanExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let base = cleanExt.isEmpty ? cleanStem : "\(cleanStem).\(cleanExt)"
        if !existing.contains(base) {
            return base
        }
        var n = 2
        while true {
            let candidate = cleanExt.isEmpty ? "\(cleanStem)-\(n)" : "\(cleanStem)-\(n).\(cleanExt)"
            if !existing.contains(candidate) {
                return candidate
            }
            n += 1
        }
    }

    public static func safeFileStem(_ raw: String, fallback: String = "Image") -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        let sanitized = trimmed.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if sanitized == "." || sanitized == ".." {
            return fallback
        }
        return sanitized
    }

    /// Stand-in URL used during drag hover when a pasteboard holds promises or image bytes
    /// without an on-disk file URL yet (`File.<ext>` / `Image.<ext>`).
    public static func hoverStandInURL(prefix: String = "File", extension ext: String) -> URL {
        let cleanExt = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let filename = cleanExt.isEmpty ? prefix : "\(prefix).\(cleanExt)"
        return URL(fileURLWithPath: filename)
    }
}

/// Pure `NSDragOperation` / `DragOutcome` / stack offset helpers matching `drag_out/macos.rs`.
public enum MacOSDragOutLogic {
    public static let nsCopyMask: UInt = 1
    public static let nsLinkMask: UInt = 2
    public static let nsGenericMask: UInt = 4
    public static let nsMoveMask: UInt = 16
    public static let nsDeleteMask: UInt = 32

    public static func dragOperationMask(for item: DragItem) -> UInt {
        var mask: UInt = 0
        if item.offers(.copy) { mask |= nsCopyMask }
        if item.offers(.link) { mask |= nsLinkMask }
        if item.offers(.move) { mask |= nsMoveMask }
        return mask == 0 ? nsCopyMask : mask
    }

    public static func operationMask(for mask: UInt, withinApplication: Bool, dropsWithinApp: Bool) -> UInt {
        if withinApplication && !dropsWithinApp {
            return 0
        }
        return mask
    }

    /// Prevents modifier keys from altering/cancelling single-operation drags (`drag_out/macos.rs`).
    public static func ignoreModifierKeys(for item: DragItem) -> Bool {
        var count = 0
        if item.offers(.copy) { count += 1 }
        if item.offers(.link) { count += 1 }
        if item.offers(.move) { count += 1 }
        return count <= 1
    }

    public static func outcome(from operationRawValue: UInt, ended: Bool = true) -> DragOutcome {
        guard ended else { return .cancelled }
        if operationRawValue == 0 {
            return .cancelled
        }
        if (operationRawValue & nsCopyMask) != 0 {
            return .copied
        }
        if (operationRawValue & (nsMoveMask | nsDeleteMask | nsGenericMask)) != 0 {
            return .moved
        }
        if (operationRawValue & nsLinkMask) != 0 {
            return .linked
        }
        return .cancelled
    }

    public static func stackOffset(index: Int) -> Vec2 {
        let step = Float(min(max(0, index), 4)) * 3.0
        return Vec2(step, step)
    }
}

#if os(macOS)

// MARK: - macOS Drag Pasteboard Reader (`platform/macos/drop.rs`)

@MainActor
public enum MacOSDropReader {
    private static let dropQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "rune.macos.filePromiseDrop"
        q.maxConcurrentOperationCount = 4
        return q
    }()
    private static var batchCounter: UInt64 = 0

    public static var draggedTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [
            .fileURL,
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
            NSPasteboard.PasteboardType("org.webmproject.webp"),
            NSPasteboard.PasteboardType("public.heic"),
        ]
        for uti in NSFilePromiseReceiver.readableDraggedTypes {
            let pt = NSPasteboard.PasteboardType(uti)
            if !types.contains(pt) {
                types.append(pt)
            }
        }
        return types
    }

    /// Reads hover URLs synchronously (real file URLs, or stand-in `File.<ext>` / `Image.<ext>`).
    public static func hoverURLs(from info: NSDraggingInfo) -> [URL] {
        let pb = info.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            return promises.map { receiver in
                let ext = receiver.fileTypes.compactMap { UTType($0)?.preferredFilenameExtension }.first ?? ""
                return DropTempNaming.hoverStandInURL(prefix: "File", extension: ext)
            }
        }
        if let imgInfo = firstPasteboardImageType(in: pb) {
            return [DropTempNaming.hoverStandInURL(prefix: "Image", extension: imgInfo.ext)]
        }
        return []
    }

    /// Extracts dropped file URLs, materialized `NSFilePromiseReceiver` files, or pasteboard image bytes.
    public static func dropURLs(from info: NSDraggingInfo, completion: @escaping @MainActor ([URL]) -> Void) {
        let pb = info.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            completion(urls)
            return
        }

        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            guard let destDir = makeTempDropDirectory() else {
                completion([])
                return
            }
            let group = DispatchGroup()
            let box = URLCollectorBox()
            for receiver in promises {
                group.enter()
                receiver.receivePromisedFiles(atDestination: destDir, options: [:], operationQueue: dropQueue) { url, error in
                    if error == nil {
                        box.append(url)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                completion(box.takeAll())
            }
            return
        }

        if let extracted = writePasteboardImageToTemp(from: pb) {
            completion([extracted])
            return
        }

        completion([])
    }

    private static func firstPasteboardImageType(in pb: NSPasteboard) -> (type: NSPasteboard.PasteboardType, ext: String, needsPNG: Bool)? {
        for entry in DropTempNaming.imageTypeExtensions {
            let pt = NSPasteboard.PasteboardType(entry.uti)
            if pb.availableType(from: [pt]) != nil {
                return (pt, entry.ext, entry.needsPNGConversion)
            }
        }
        return nil
    }

    private static func writePasteboardImageToTemp(from pb: NSPasteboard) -> URL? {
        guard let info = firstPasteboardImageType(in: pb),
              let rawData = pb.data(forType: info.type) else {
            return nil
        }
        let finalData: Data
        if info.needsPNG {
            guard let rep = NSBitmapImageRep(data: rawData),
                  let png = rep.representation(using: .png, properties: [:]) else {
                return nil
            }
            finalData = png
        } else {
            finalData = rawData
        }
        guard let destDir = makeTempDropDirectory() else { return nil }
        let stem = urlStemFromPasteboard(pb) ?? "Image"
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: destDir.path)) ?? [])
        let filename = DropTempNaming.freeName(stem: stem, ext: info.ext, existing: existing)
        let targetURL = destDir.appendingPathComponent(filename)
        do {
            try finalData.write(to: targetURL, options: .atomic)
            return targetURL
        } catch {
            return nil
        }
    }

    private static func urlStemFromPasteboard(_ pb: NSPasteboard) -> String? {
        guard let urlStr = pb.string(forType: .URL), let url = URL(string: urlStr) else {
            return nil
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? nil : DropTempNaming.safeFileStem(stem, fallback: "Image")
    }

    private static func makeTempDropDirectory() -> URL? {
        batchCounter &+= 1
        let pid = ProcessInfo.processInfo.processIdentifier
        let stamp = UInt64(Date().timeIntervalSinceReferenceDate * 1000.0)
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rune-drops", isDirectory: true)
            .appendingPathComponent("\(pid)-\(stamp)-\(batchCounter)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return root
        } catch {
            return nil
        }
    }
}

private final class URLCollectorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    func takeAll() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }
}

// MARK: - macOS Native Popup Menu Presenter (`popup_menu/macos.rs`)

@MainActor
public final class MacOSPopupMenuPresenter: NSObject {
    private var activeMenu: NSMenu?
    private var activeSession: PopupSession?
    private var pendingPickedId: String?
    private var tagToId: [Int: String] = [:]

    public var isPresenting: Bool {
        activeSession != nil || activeMenu != nil
    }

    public func present(
        _ show: PopupShow,
        in view: NSView,
        onResolve: @escaping @MainActor (String?) -> Void
    ) {
        guard activeSession == nil else { return }

        var nextTag = 1
        var map: [Int: String] = [:]
        let placement = show.placement(isRTL: view.userInterfaceLayoutDirection == .rightToLeft)
        var positioningItem: NSMenuItem?

        func build(_ popupMenu: PopupMenu) -> NSMenu {
            let nsMenu = NSMenu()
            nsMenu.autoenablesItems = false
            for entry in popupMenu.entries {
                switch entry {
                case .separator:
                    nsMenu.addItem(.separator())
                case .item(let item):
                    let tag = nextTag
                    nextTag += 1
                    map[tag] = item.id
                    let (keyChar, keyMask) = Self.parseKeyEquivalent(item.keyEquivalent)
                    let nsItem = NSMenuItem(
                        title: item.title,
                        action: #selector(handleMenuPick(_:)),
                        keyEquivalent: keyChar
                    )
                    if !keyChar.isEmpty {
                        nsItem.keyEquivalentModifierMask = keyMask
                    }
                    nsItem.tag = tag
                    nsItem.target = self
                    nsItem.isEnabled = item.enabled
                    nsItem.state = (item.checked || popupMenu.selectedId == item.id) ? .on : .off
                    if let sym = item.symbolName {
                        nsItem.image = NSImage(systemSymbolName: sym, accessibilityDescription: item.title)
                    }
                    if placement.positionedId == item.id && positioningItem == nil {
                        positioningItem = nsItem
                    }
                    nsMenu.addItem(nsItem)
                case .submenu(let title, let sub, let enabled):
                    let nsItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    nsItem.isEnabled = enabled
                    nsItem.submenu = build(sub)
                    nsMenu.addItem(nsItem)
                }
            }
            return nsMenu
        }

        let nsMenu = build(show.menu)
        nsMenu.minimumWidth = CGFloat(max(0, placement.minWidth))
        self.tagToId = map
        self.pendingPickedId = nil
        self.activeMenu = nsMenu

        let session = PopupSession { picked in
            Task { @MainActor in
                onResolve(picked)
            }
        }
        self.activeSession = session

        // Defer onto the next run-loop turn so the current render frame finishes before NSMenu tracks.
        let runLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view, !session.isResolved, self.activeSession === session else {
                    return
                }
                let pt = NSPoint(x: CGFloat(placement.at.x), y: CGFloat(placement.at.y))
                nsMenu.popUp(positioning: positioningItem, at: pt, in: view)
                let chosen = self.pendingPickedId
                self.pendingPickedId = nil
                self.activeMenu = nil
                self.tagToId = [:]
                if self.activeSession === session {
                    self.activeSession = nil
                }
                session.resolve(chosen)
            }
        }
        CFRunLoopWakeUp(runLoop)
    }

    public func cancel() {
        activeMenu?.cancelTrackingWithoutAnimation()
        activeMenu = nil
        pendingPickedId = nil
        tagToId = [:]
        let session = activeSession
        activeSession = nil
        session?.cancel()
    }

    @objc private func handleMenuPick(_ sender: NSMenuItem) {
        pendingPickedId = tagToId[sender.tag]
    }

    private static func parseKeyEquivalent(_ raw: String?) -> (String, NSEvent.ModifierFlags) {
        guard let raw, !raw.isEmpty else { return ("", []) }
        let parts = raw.split(separator: "+").map { String($0).lowercased() }
        guard let last = parts.last else { return ("", []) }
        var mask: NSEvent.ModifierFlags = []
        for mod in parts.dropLast() {
            switch mod {
            case "cmd", "super", "command": mask.insert(.command)
            case "shift": mask.insert(.shift)
            case "alt", "opt", "option": mask.insert(.option)
            case "ctrl", "control": mask.insert(.control)
            default: break
            }
        }
        if parts.count == 1 && !mask.contains(.command) {
            mask.insert(.command)
        }
        return (last, mask)
    }
}

// MARK: - macOS File Dialog Presenter (`file_dialog.rs`)

@MainActor
public final class MacOSFileDialogPresenter {
    private var activeId: UInt64?
    private weak var activePanel: NSSavePanel?
    private weak var hostWindow: NSWindow?

    public var isPresenting: Bool {
        activeId != nil
    }

    public func present(
        _ pending: FileDialogPending,
        in window: NSWindow?,
        onAnswer: @escaping @MainActor (UInt64, FileDialogResult) -> Void
    ) {
        guard activeId == nil else { return }
        guard let window else {
            onAnswer(pending.id, .failure(FileDialogError("no window available for file dialog")))
            return
        }

        let panel: NSSavePanel
        switch pending.kind {
        case .open, .folder:
            let openPanel = NSOpenPanel()
            openPanel.canChooseFiles = (pending.kind == .open)
            openPanel.canChooseDirectories = (pending.kind == .folder)
            openPanel.allowsMultipleSelection = (pending.kind == .open) && pending.options.allowsMultipleSelection
            panel = openPanel
        case .save:
            let savePanel = NSSavePanel()
            if let fileName = pending.options.fileName, !fileName.isEmpty {
                savePanel.nameFieldStringValue = fileName
            }
            panel = savePanel
        }

        if !pending.options.title.isEmpty {
            panel.title = pending.options.title
            panel.message = pending.options.title
        }
        panel.directoryURL = pending.options.directory
        if pending.kind != .folder && !pending.options.filters.isEmpty {
            let exts = pending.options.filters.flatMap(\.extensions)
            let types = exts.compactMap { ext -> UTType? in
                let trimmed = ext.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return trimmed.isEmpty ? nil : UTType(filenameExtension: trimmed)
            }
            if !types.isEmpty {
                panel.allowedContentTypes = types
            }
        }

        activeId = pending.id
        activePanel = panel
        hostWindow = window

        let dialogId = pending.id
        panel.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                let matchesActive = (self.activeId == dialogId)
                if matchesActive {
                    self.activeId = nil
                    self.activePanel = nil
                    self.hostWindow = nil
                }
                guard matchesActive else { return }
                if response == .OK {
                    let chosen: URL? = (panel as? NSOpenPanel)?.urls.first ?? panel.url
                    onAnswer(dialogId, .success(chosen))
                } else {
                    onAnswer(dialogId, .success(nil))
                }
            }
        }
    }

    public func cancel() {
        guard let panel = activePanel else {
            activeId = nil
            hostWindow = nil
            return
        }
        let win = hostWindow
        activeId = nil
        activePanel = nil
        hostWindow = nil
        win?.endSheet(panel, returnCode: .cancel)
    }
}

// MARK: - macOS Outbound Drag-Out Host (`drag_out/macos.rs`)

@MainActor
public final class MacOSDragOutCoordinator {
    private var activeSession: Session?

    public func start(
        _ start: DragOutStart,
        in view: NSView,
        onComplete: @escaping @MainActor (DragOutcome) -> Void
    ) {
        // Finalize any prior unended session synchronously first so its muted types are restored
        // before muting for the replacement session (`drag_out/macos.rs`).
        if let previous = activeSession {
            activeSession = nil
            previous.cancelAndUnmute()
        }

        let draggingItems = buildDraggingItems(start: start, in: view)
        guard !draggingItems.isEmpty else {
            onComplete(.cancelled)
            return
        }

        guard let dragEvent = makeDragEvent(in: view, press: start.press) else {
            onComplete(.cancelled)
            return
        }

        var mutedWindows: [(NSWindow, [NSPasteboard.PasteboardType])] = []
        var mutedViews: [(NSView, [NSPasteboard.PasteboardType])] = []
        if !start.item.dropsWithinApp {
            let regSelector = NSSelectorFromString("registeredDraggedTypes")
            let dragEnterSelector = NSSelectorFromString("draggingEntered:")
            for win in NSApp.windows {
                let winTypes: [NSPasteboard.PasteboardType]
                if win.responds(to: regSelector),
                   let rawTypes = win.perform(regSelector)?.takeUnretainedValue() as? [NSPasteboard.PasteboardType] {
                    winTypes = rawTypes
                } else if let del = win.delegate, del.responds(to: dragEnterSelector) {
                    winTypes = MacOSDropReader.draggedTypes
                } else {
                    winTypes = []
                }
                if !winTypes.isEmpty {
                    mutedWindows.append((win, winTypes))
                    win.unregisterDraggedTypes()
                }
                if let contentView = win.contentView {
                    collectAndMuteRegisteredTypes(in: contentView, excluding: nil, out: &mutedViews)
                }
            }
        }

        let session = Session(
            operationMask: NSDragOperation(rawValue: MacOSDragOutLogic.dragOperationMask(for: start.item)),
            dropsWithinApp: start.item.dropsWithinApp,
            ignoreModifiers: MacOSDragOutLogic.ignoreModifierKeys(for: start.item),
            mutedWindows: mutedWindows,
            mutedViews: mutedViews
        ) { [weak self] outcome in
            self?.activeSession = nil
            onComplete(outcome)
        }
        self.activeSession = session
        _ = view.beginDraggingSession(with: draggingItems, event: dragEvent, source: session)
    }

    public func cancelActive() {
        guard let session = activeSession else { return }
        activeSession = nil
        session.cancelAndUnmute()
    }

    private func collectAndMuteRegisteredTypes(
        in view: NSView,
        excluding excluded: NSView?,
        out: inout [(NSView, [NSPasteboard.PasteboardType])]
    ) {
        if view !== excluded && !view.registeredDraggedTypes.isEmpty {
            out.append((view, view.registeredDraggedTypes))
            view.unregisterDraggedTypes()
        }
        for sub in view.subviews {
            collectAndMuteRegisteredTypes(in: sub, excluding: excluded, out: &out)
        }
    }

    private func makeDragEvent(in view: NSView, press: Vec2) -> NSEvent? {
        if let cur = NSApp.currentEvent,
           cur.type == .leftMouseDragged || cur.type == .leftMouseDown {
            return cur
        }
        guard let window = view.window else { return nil }
        let inWindow = view.convert(NSPoint(x: CGFloat(press.x), y: CGFloat(press.y)), to: nil)
        return NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: inWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )
    }

    private func buildDraggingItems(start: DragOutStart, in view: NSView) -> [NSDraggingItem] {
        var out: [NSDraggingItem] = []
        let item = start.item

        let previewImage: NSImage?
        let naturalSize: Vec2
        if var img = item.dragImage {
            if let backing = item.backingColor, let composited = img.over(backing) {
                img = composited
            }
            if let png = img.resolvedPNGData(), let nsImg = NSImage(data: png) {
                previewImage = nsImg
                let nsSz = nsImg.size
                naturalSize = Vec2(Float(max(1, nsSz.width)), Float(max(1, nsSz.height)))
            } else {
                previewImage = nil
                naturalSize = Vec2(max(24, start.bounds.width), max(24, start.bounds.height))
            }
            let baseFrame = img.frame(bounds: start.bounds, press: start.press, natural: naturalSize)
            if !item.files.isEmpty {
                for (i, url) in item.files.enumerated() {
                    let dragging = NSDraggingItem(pasteboardWriter: url as NSURL)
                    let off = MacOSDragOutLogic.stackOffset(index: i)
                    let rect = NSRect(
                        x: CGFloat(baseFrame.left + off.x),
                        y: CGFloat(baseFrame.top + off.y),
                        width: CGFloat(max(1, baseFrame.width)),
                        height: CGFloat(max(1, baseFrame.height))
                    )
                    dragging.setDraggingFrame(rect, contents: previewImage ?? fallbackIconImage(for: url))
                    out.append(dragging)
                }
                return out
            }
            if let pbItem = makeNonFilePasteboardItem(item) {
                let dragging = NSDraggingItem(pasteboardWriter: pbItem)
                let rect = NSRect(
                    x: CGFloat(baseFrame.left),
                    y: CGFloat(baseFrame.top),
                    width: CGFloat(max(1, baseFrame.width)),
                    height: CGFloat(max(1, baseFrame.height))
                )
                dragging.setDraggingFrame(rect, contents: previewImage ?? fallbackBoxImage(size: rect.size))
                out.append(dragging)
            }
            return out
        }

        // No explicit DragImage: file icons or translucent bounds box
        if !item.files.isEmpty {
            for (i, url) in item.files.enumerated() {
                let dragging = NSDraggingItem(pasteboardWriter: url as NSURL)
                let off = MacOSDragOutLogic.stackOffset(index: i)
                let sz: CGFloat = 48
                let rect = NSRect(
                    x: CGFloat(start.press.x - 24 + off.x),
                    y: CGFloat(start.press.y - 24 + off.y),
                    width: sz,
                    height: sz
                )
                dragging.setDraggingFrame(rect, contents: fallbackIconImage(for: url))
                out.append(dragging)
            }
            return out
        }

        if let pbItem = makeNonFilePasteboardItem(item) {
            let dragging = NSDraggingItem(pasteboardWriter: pbItem)
            let rect = NSRect(
                x: CGFloat(start.bounds.left),
                y: CGFloat(start.bounds.top),
                width: CGFloat(max(16, start.bounds.width)),
                height: CGFloat(max(16, start.bounds.height))
            )
            dragging.setDraggingFrame(rect, contents: fallbackBoxImage(size: rect.size))
            out.append(dragging)
        }
        return out
    }

    private func makeNonFilePasteboardItem(_ item: DragItem) -> NSPasteboardItem? {
        guard item.pngData != nil || item.text != nil else { return nil }
        let pb = NSPasteboardItem()
        if let png = item.pngData {
            pb.setData(png, forType: .png)
        }
        if let text = item.text {
            pb.setString(text, forType: .string)
        }
        return pb
    }

    private func fallbackIconImage(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    private func fallbackBoxImage(size: CGSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        path.fill()
        path.lineWidth = 1.5
        path.stroke()
        img.unlockFocus()
        return img
    }

    private final class Session: NSObject, NSDraggingSource {
        private let operationMask: NSDragOperation
        private let dropsWithinApp: Bool
        private let ignoreModifiers: Bool
        private var mutedWindows: [(NSWindow, [NSPasteboard.PasteboardType])]
        private var mutedViews: [(NSView, [NSPasteboard.PasteboardType])]
        private var completion: (@MainActor (DragOutcome) -> Void)?

        init(
            operationMask: NSDragOperation,
            dropsWithinApp: Bool,
            ignoreModifiers: Bool,
            mutedWindows: [(NSWindow, [NSPasteboard.PasteboardType])],
            mutedViews: [(NSView, [NSPasteboard.PasteboardType])],
            completion: @escaping @MainActor (DragOutcome) -> Void
        ) {
            self.operationMask = operationMask
            self.dropsWithinApp = dropsWithinApp
            self.ignoreModifiers = ignoreModifiers
            self.mutedWindows = mutedWindows
            self.mutedViews = mutedViews
            self.completion = completion
            super.init()
        }

        deinit {
            let windows = mutedWindows
            let views = mutedViews
            let cb = completion
            mutedWindows = []
            mutedViews = []
            completion = nil
            if !windows.isEmpty || !views.isEmpty || cb != nil {
                MainActor.assumeIsolated {
                    for (w, types) in windows { w.registerForDraggedTypes(types) }
                    for (v, types) in views { v.registerForDraggedTypes(types) }
                    cb?(.cancelled)
                }
            }
        }

        @MainActor
        func cancelAndUnmute() {
            finish(with: .cancelled)
        }

        @MainActor
        private func unmuteAll() {
            for (w, types) in mutedWindows { w.registerForDraggedTypes(types) }
            for (v, types) in mutedViews { v.registerForDraggedTypes(types) }
            mutedWindows.removeAll()
            mutedViews.removeAll()
        }

        @MainActor
        private func finish(with outcome: DragOutcome) {
            unmuteAll()
            let cb = completion
            completion = nil
            cb?(outcome)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            let masked = MacOSDragOutLogic.operationMask(
                for: operationMask.rawValue,
                withinApplication: context == .withinApplication,
                dropsWithinApp: dropsWithinApp
            )
            return NSDragOperation(rawValue: masked)
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
            ignoreModifiers
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            let resolved = MacOSDragOutLogic.outcome(from: operation.rawValue, ended: true)
            MainActor.assumeIsolated {
                finish(with: resolved)
            }
        }
    }
}

/// Shared macOS NSPasteboard <-> Runtime clipboard sync helper supporting `public.html`, RTF, PNG, and plain text (#832).
@MainActor
public enum MacOSClipboardSync {
    @discardableResult
    public static func dispatchKeyWithSync<State>(
        _ event: KeyEvent,
        runtime: Runtime<State>,
        at now: Double
    ) -> Bool {
        if event.mods.cmd, (event.key == .command("v") || event.key == .text("v") || event.key == .text("V")) {
            let rich = Clipboard.shared.readRich()
            if !rich.content.text.isEmpty || rich.content.html != nil || rich.content.rtf != nil || rich.image != nil {
                runtime.richClipboard = rich
                runtime.clipboard = rich.content
            }
        }
        let prevClip = runtime.clipboard
        let prevRich = runtime.richClipboard
        let handled = runtime.keyDown(event, at: now)
        if runtime.richClipboard != prevRich {
            Clipboard.shared.writeRich(runtime.richClipboard)
        } else if runtime.clipboard != prevClip,
                  !runtime.clipboard.text.isEmpty || runtime.clipboard.html != nil || runtime.clipboard.rtf != nil {
            Clipboard.shared.writeRich(RichClipboardPayload(content: runtime.clipboard))
        }
        return handled
    }
}
#endif
