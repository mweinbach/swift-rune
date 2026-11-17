#if os(Linux)
import CRuneDesktopServices
import Foundation

/// Per-window native drag session. The SDL host drives it on the same thread as the Runtime.
@MainActor
final class LinuxDragSource {
    private var driver: OpaquePointer?
    private(set) var active = false

    func open<State>(windowID: UInt32, runtime: Runtime<State>) {
        driver = rune_linux_drag_open(windowID)
        runtime.setOsDrag(driver != nil)
    }

    func poll<State>(runtime: Runtime<State>, at now: Double) {
        guard active else { return }
        let result = rune_linux_drag_poll(driver)
        guard result >= 0 else { return }
        active = false
        runtime.finishDragOut(Self.outcome(result), at: now)
    }

    func beginAfterDrawing<State>(runtime: Runtime<State>, at now: Double, scale: Float,
                                  pixelWidth: Int, pixelHeight: Int) {
        guard !active, let start = runtime.takeDragOutStart() else { return }
        guard let driver, let payload = Self.makePayload(start.item) else {
            runtime.finishDragOut(.cancelled, at: now)
            return
        }
        let allowed = start.item.operations.intersection([.copy, .move, .link])
        let operations = allowed.isEmpty ? DragOperation.copy : allowed
        active = LinuxDragPreview.begin(driver: driver, payload: payload, operations: UInt32(operations.rawValue),
                                        withinApp: start.item.dropsWithinApp, start: start,
                                        scale: scale, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        if !active { runtime.finishDragOut(.cancelled, at: now) }
    }

    func close<State>(runtime: Runtime<State>, at now: Double) {
        let result = active ? Self.outcome(rune_linux_drag_poll(driver)) : nil
        rune_linux_drag_close(driver)
        driver = nil
        active = false
        if let result { runtime.finishDragOut(result, at: now) }
    }

    private static func outcome(_ response: Int32) -> DragOutcome {
        switch response {
        case 1: .copied
        case 2: .moved
        case 4: .linked
        default: .cancelled
        }
    }

    private static func makePayload(_ item: DragItem) -> OpaquePointer? {
        guard let list = rune_mime_create() else { return nil }
        var transferred = false
        defer { if !transferred { rune_mime_free(list) } }

        func add(_ mime: String, _ data: Data) -> Bool {
            data.withUnsafeBytes {
                rune_mime_add(list, mime, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) != 0
            }
        }
        let files = item.paths.filter(\.isFileURL)
        if !files.isEmpty {
            let uris = files.map(\.absoluteString).joined(separator: "\r\n") + "\r\n"
            guard add("text/uri-list", Data(uris.utf8)) else { return nil }
        }
        if let text = item.plainText ?? files.first?.path {
            let data = Data(text.utf8)
            guard add("text/plain;charset=utf-8", data) && add("text/plain", data) else { return nil }
        }
        if let data = item.pngData, !add("image/png", data) { return nil }
        transferred = true
        return list
    }
}
#endif
