import Foundation
import RuneMotion

/// Snapshot transfer is pull-based. An idle or unchanged animation frame keeps the browser's DOM intact.
final class WebAccessibilityProjection {
    private var previous: AccessibilityNode?
    private var viewport: Vec2?
    private var announcement: AccessibilityAnnouncement?

    func update<State>(_ runtime: Runtime<State>) -> Data? {
        let node = runtime.accessibilitySnapshot()
        let size = runtime.viewport
        let spoken = runtime.a11yAnnouncement
        guard previous != node || viewport != size || announcement != spoken else { return nil }
        var packet: [String: Any] = [
            "width": size.x, "height": size.y,
            "root": AccessibilityDump.dictionary(from: node, isRoot: true, forBrowser: true)
        ]
        if spoken.count != announcement?.count, let words = spoken.words {
            packet["announcement"] = ["text": words.text, "live": words.politeness.rawValue]
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: packet) else { return nil }
        previous = node
        viewport = size
        announcement = spoken
        return bytes
    }
}

#if os(WASI)
@MainActor @_cdecl("rune_web_accessibility")
func runeWebAccessibility() -> Int {
    guard let data = RuneWebReactor.session?.takeAccessibility(),
          let bytes = RuneWebReactor.reserve(data.count) else { return 0 }
    data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
    return data.count
}
#endif
