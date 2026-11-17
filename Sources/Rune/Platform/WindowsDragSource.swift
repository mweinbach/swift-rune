#if os(Windows)
import CRuneWin32
import Foundation

@MainActor
private final class Win32DragCompletion {
    let deliver: (DragOutcome) -> Void
    init(_ deliver: @escaping (DragOutcome) -> Void) { self.deliver = deliver }
}

private func completeWin32Drag(_ pointer: UnsafeMutableRawPointer?, _ effect: UInt32) {
    guard let pointer else { return }
    let completion = Unmanaged<Win32DragCompletion>.fromOpaque(pointer).takeRetainedValue()
    // OLE and the HWND subclass execute on the main thread which posted the drag.
    MainActor.assumeIsolated {
        let outcome: DragOutcome = switch effect {
        case 1: .copied
        case 2: .moved
        case 4: .linked
        default: .cancelled
        }
        completion.deliver(outcome)
    }
}

@MainActor
final class Win32DragSource {
    private(set) var pending = false

    func begin(window: OpaquePointer, start: DragOutStart, picture: DragImage?, scale: Float,
               done: @escaping (DragOutcome) -> Void) {
        let item = start.item
        var fileList: [UInt16] = []
        for url in item.files {
            guard url.isFileURL, !url.path(percentEncoded: false).utf8.contains(0),
                  let path = url.withUnsafeFileSystemRepresentation({ $0.map(String.init(cString:)) }),
                  !path.isEmpty else { done(.cancelled); return }
            fileList.append(contentsOf: path.replacingOccurrences(of: "/", with: "\\").utf16)
            fileList.append(0)
        }
        if !fileList.isEmpty { fileList.append(0) }

        guard !pending, item.text?.utf8.contains(0) != true else { done(.cancelled); return }
        let text = item.text.map { Array($0.utf16) + [0] } ?? []
        let png = item.pngData ?? Data()
        let pixels = picture?.rgba ?? Data()
        var payload = RuneWinDragPayload()
        payload.within_app = item.withinApp ? 1 : 0
        let allowed = item.operations.intersection([.copy, .move, .link])
        payload.operations = UInt32((allowed.isEmpty ? DragOperation.copy : allowed).rawValue)
        if let picture, let width = Int32(exactly: picture.width), let height = Int32(exactly: picture.height),
           width > 0, height > 0 {
            payload.width = width
            payload.height = height
            let rect = picture.frame(bounds: start.bounds, press: start.press,
                                     natural: Vec2(Float(width) / scale, Float(height) / scale))
            func hotspot(_ value: Float, extent: Int32) -> Int32 {
                guard value.isFinite else { return 0 }
                return Int32(clamping: Int64(max(0, min(Double(extent - 1), Double(value.rounded())))))
            }
            payload.hotspot_x = hotspot((start.press.x - rect.left) * Float(width) / max(rect.width, 1), extent: width)
            payload.hotspot_y = hotspot((start.press.y - rect.top) * Float(height) / max(rect.height, 1), extent: height)
        }
        let completion = Unmanaged.passRetained(Win32DragCompletion { [self] outcome in
            pending = false
            done(outcome)
        }).toOpaque()
        pending = true
        let posted = text.withUnsafeBufferPointer { text in
            fileList.withUnsafeBufferPointer { files in
                pixels.withUnsafeBytes { rgba in
                    png.withUnsafeBytes { png in
                        payload.text = text.isEmpty ? nil : text.baseAddress
                        payload.files = files.baseAddress
                        payload.file_units = files.count
                        payload.png = png.bindMemory(to: UInt8.self).baseAddress
                        payload.png_size = png.count
                        payload.rgba = rgba.bindMemory(to: UInt8.self).baseAddress
                        payload.rgba_size = rgba.count
                        return rune_win_drag_begin(rune_win_hwnd(window), &payload, completeWin32Drag, completion)
                    }
                }
            }
        }
        if posted == 0 { completeWin32Drag(completion, 0) }
    }
}
#endif
