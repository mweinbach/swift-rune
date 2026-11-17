#if canImport(CRuneGL)
import CRuneGL
import Foundation

/// Binds a renderer's retained textures to one runtime at a time. An inactive
/// runtime never omits geometry on the strength of another window's textures.
final class PortableGLLayerCache {
    private weak var tracker: ResidentLayerTracker?
    private var hasRuntime = false
    private var publishedGeneration: UInt64?

    func bind(_ next: ResidentLayerTracker?, handle: OpaquePointer) {
        if tracker !== next || hasRuntime != (next != nil) {
            tracker?.release(self)
            rune_gl_layer_cache_clear(handle)
            tracker = next
            hasRuntime = next != nil
        }
        if next?.acquire(for: self) == true {
            publishedGeneration = nil
            synchronize(handle)
        }
    }

    func synchronize(_ handle: OpaquePointer) {
        guard let tracker else { return }
        let stats = rune_gl_layer_cache_stats(handle)
        guard stats.generation != publishedGeneration else { return }
        let count = Int(stats.count)
        var items = [RuneGLCachedLayer](repeating: RuneGLCachedLayer(), count: count)
        _ = items.withUnsafeMutableBufferPointer {
            rune_gl_layer_cache_entries(handle, $0.baseAddress, $0.count)
        }
        var resident = [UInt64: UInt64](minimumCapacity: count)
        for item in items { resident[item.key] = item.signature }
        tracker.publish(resident, from: self)
        publishedGeneration = stats.generation
    }

    func unbind() {
        tracker?.release(self)
        tracker = nil
        hasRuntime = false
        publishedGeneration = nil
    }
}
#endif
