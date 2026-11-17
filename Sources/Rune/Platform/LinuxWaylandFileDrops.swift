#if os(Linux)
import CRuneDesktopServices
import Foundation
import RuneMotion

enum LinuxWaylandFileDrops {
    static func take<State>(windowID: UInt32, runtime: Runtime<State>, at now: Double) {
        var x: Float = 0
        var y: Float = 0
        while let data = rune_wayland_take_drop(windowID, &x, &y) {
            var accepted = false
            defer {
                rune_wayland_finish_drop(windowID, accepted ? 1 : 0)
                rune_mime_free(data)
            }
            var length = 0
            guard let bytes = rune_mime_bytes(data, 0, &length),
                  let uris = String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8) else { continue }
            let paths = uris.split(whereSeparator: \.isNewline).compactMap { line -> URL? in
                guard line.first != "#", let url = URL(string: String(line)),
                      url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
                      url.host == nil || url.host == "" || url.host?.lowercased() == "localhost" else { return nil }
                return url
            }
            if !paths.isEmpty {
                let files = paths.map { DroppedFile(url: $0) }
                let point = runtime.inputPoint(fromWindow: Vec2(x, y))
                accepted = runtime.receiveFileDrop(.dropped(files, at: point), at: now)
            }
        }
    }

    static func mayUseSDL(windowID: UInt32) -> Bool {
        rune_wayland_owns_drop(windowID) == 0
    }
}
#endif
