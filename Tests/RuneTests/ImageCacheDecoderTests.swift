import Foundation
import Testing
@testable import Rune

/// Thread-safe stand-in for the `mpsc::channel` the upstream image tests wake through:
/// `send`, `try_recv` and `recv_timeout`.
final class ImageWakeChannel<T: Sendable>: @unchecked Sendable {
    private let condition = NSCondition()
    private var queue: [T] = []

    init() {}

    func send(_ value: T) {
        condition.lock()
        queue.append(value)
        condition.signal()
        condition.unlock()
    }

    /// `try_recv`: the next value, or nil when the channel is empty.
    func tryRecv() -> T? {
        condition.lock()
        defer { condition.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }

    /// `recv_timeout`: blocks for the next value, or nil after `timeout` seconds.
    func recv(timeout: TimeInterval) -> T? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty {
            if !condition.wait(until: deadline) { break }
        }
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}

/// Ports of `crates/rune/src/image.rs` decoder-pool tests (#971 inline wake, r440 queued decodes).
@Suite("Image cache decoder threads (image.rs #971/r440)")
struct ImageCacheDecoderTests {
    private static func currentThread() -> ObjectIdentifier { ObjectIdentifier(Thread.current) }

    @Test("upstream constants: INLINE_RGBA_PIXELS = 64 * 64, DECODERS = 4")
    func upstreamConstants() {
        #expect(INLINE_RGBA_PIXELS == 4096)
        #expect(IMAGE_DECODERS == 4)
        #expect(ImageDecoderPool.shared.threadCount == min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))
    }

    // image.rs a_small_image_queued_behind_a_large_one_decodes_without_waiting_for_it
    @Test("a_small_image_queued_behind_a_large_one_decodes_without_waiting_for_it")
    func aSmallImageQueuedBehindALargeOneDecodesWithoutWaitingForIt() {
        if ProcessInfo.processInfo.activeProcessorCount < 2 { return }
        let rx = ImageWakeChannel<ObjectIdentifier>()
        let caller = Self.currentThread()
        let cache = ImageCache(wake: { rx.send(ImageCacheDecoderTests.currentThread()) })
        let gate = ImageDecodeGate()
        var released = false
        defer { if !released { gate.release() } }
        let input = ImageDecodeInput.rgba(128, 128, Data(repeating: 128, count: 128 * 128 * 4))
        let large = cache.request(id: ImageId(bytes: [UInt8](repeating: 8, count: 32)), input: .gated(input, gate))
        let inline = cache.rgba(width: 64, height: 64, data: [UInt8](repeating: 255, count: 64 * 64 * 4))
        #expect(inline.size?.width == 64 && inline.size?.height == 64)
        #expect(rx.tryRecv() == caller)
        #expect(rx.tryRecv() == nil)
        // Just over the inline limit: a second worker must finish this one.
        let small = cache.rgba(width: 65, height: 64, data: [UInt8](repeating: 255, count: 65 * 64 * 4))
        let worker = rx.recv(timeout: 120)
        #expect(worker != nil)
        #expect(worker != caller)
        #expect(small.size?.width == 65 && small.size?.height == 64)
        #expect(!large.isReady)
        gate.release()
        released = true
        #expect(rx.recv(timeout: 120) != nil)
        #expect(large.size?.width == 128 && large.size?.height == 128)
    }

    // image.rs cache_deduplicates_and_wakes_after_async_completion
    @Test("cache_deduplicates_and_wakes_after_async_completion")
    func cacheDeduplicatesAndWakesAfterAsyncCompletion() {
        let rx = ImageWakeChannel<Void>()
        let cache = ImageCache(wake: { rx.send(()) })
        let pixel: [UInt8] = [20, 40, 60, 255]
        let bytes = Array([[UInt8]](repeating: pixel, count: 65 * 64).joined())
        let queued = { cache.rgba(width: 65, height: 64, data: bytes) }
        let first = queued()
        let second = queued()
        #expect(first === second)
        #expect(rx.recv(timeout: 5) != nil)
        #expect(first.size?.width == 65 && first.size?.height == 64)
        #expect(first.pixels.rgbaBytes() == bytes)
        let invalid = cache.load(Data([0, 1, 2]))
        #expect(rx.recv(timeout: 5) != nil)
        #expect(invalid.error != nil)
    }

    // image.rs a_decoder_panic_fails_its_image_and_the_worker_goes_on
    @Test("a_decoder_panic_fails_its_image_and_the_worker_goes_on")
    func aDecoderPanicFailsItsImageAndTheWorkerGoesOn() {
        let rx = ImageWakeChannel<Void>()
        let cache = ImageCache(wake: { rx.send(()) })
        let broken = cache.request(id: ImageId(bytes: [UInt8](repeating: 7, count: 32)), input: .panic)
        #expect(rx.recv(timeout: 5) != nil)
        #expect(broken.error == ImageLoadError("image decoder panicked: decoder bug"))
        let next = cache.rgba(width: 65, height: 64, data: [UInt8](repeating: 255, count: 65 * 64 * 4))
        #expect(rx.recv(timeout: 5) != nil)
        #expect(next.size?.width == 65 && next.size?.height == 64, "later queued images still load")
    }
}
