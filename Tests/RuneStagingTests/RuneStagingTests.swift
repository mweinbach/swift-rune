import Foundation
import Testing
@testable import RuneStaging
#if canImport(Metal)
import Metal
#endif

@Suite("RuneStaging Tests")
struct RuneStagingTests {
    @Test("Buffer writes stage, submit, and reuse 128 KiB chunk without reallocating")
    func bufferStagingAndChunkReuse() {
        let backend = InMemoryStagingBackend()
        let staging = Staging(backend: backend)
        let dst = InMemoryStagingBuffer(size: 1024)

        #expect(!staging.busy)
        #expect(!staging.isPending)

        staging.writeBuffer(dst, offset: 16, data: [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(staging.busy)
        #expect(staging.isPending)
        #expect(dst.readBytes()[16..<24] == ArraySlice([UInt8](repeating: 0, count: 8)))

        staging.submit()
        #expect(!staging.busy)
        #expect(!staging.isPending)
        #expect(Array(dst.readBytes()[16..<24]) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(staging.stats.chunks == 1)
        #expect(staging.stats.writes == 1)
        #expect(staging.stats.bytes == 8)
        #expect(staging.stats.submits == 1)

        // Frame 2 reuses returned chunk (0 new allocations!)
        staging.writeBuffer(dst, offset: 64, data: [9, 10, 11, 12])
        staging.submit()
        #expect(Array(dst.readBytes()[64..<68]) == [9, 10, 11, 12])
        #expect(staging.stats.chunks == 1)
        #expect(staging.stats.writes == 2)
        #expect(staging.stats.submits == 2)
        #expect(staging.lost == 0)
    }

    @Test("Texture row writes pad non-256B rows cleanly into staging chunk and copy exact rows")
    func textureRowAlignmentPadding() {
        let backend = InMemoryStagingBackend()
        let staging = Staging(backend: backend)
        // 10 px * 4 bytes = 40 bytes/row -> aligned up to 256 bytes/row
        let tex = InMemoryStagingTexture(width: 10, height: 4, bytesPerPixel: 4)
        var rows = [UInt8](repeating: 0, count: 40 * 2)
        for i in 0..<rows.count {
            rows[i] = UInt8((i + 1) & 0xFF)
        }

        staging.writeTextureRows(tex, y: 1, rows: rows)
        #expect(staging.stats.bytes == UInt64(256 * 2))

        let enc = backend.createCommandEncoder()
        staging.flush(into: enc)
        backend.submit(enc)

        let actual = tex.readBytes()
        #expect(Array(actual[0..<40]) == [UInt8](repeating: 0, count: 40))
        #expect(Array(actual[40..<120]) == rows)
        #expect(Array(actual[120..<160]) == [UInt8](repeating: 0, count: 40))
        #expect(staging.stats.flushes == 1)
    }

    @Test("Record keeps chunk active/mapped across multiple batches until flush, and unsubmitted encoder increments lost")
    func recordThenFlushAndDroppedEncoderLost() {
        let backend = InMemoryStagingBackend()
        let staging = Staging(backend: backend)
        let dst = InMemoryStagingBuffer(size: 512)

        do {
            let enc = backend.createCommandEncoder()
            staging.writeBuffer(dst, offset: 0, data: [10, 20, 30, 40])
            staging.record(into: enc)
            #expect(staging.busy) // chunk still active/mapped after record
            #expect(!staging.isPending)

            staging.writeBuffer(dst, offset: 4, data: [50, 60, 70, 80])
            staging.flush(into: enc)
            #expect(!staging.busy)
            #expect(staging.stats.chunks == 1)
            #expect(staging.stats.flushes == 2)
            backend.submit(enc)
        }
        #expect(Array(dst.readBytes()[0..<8]) == [10, 20, 30, 40, 50, 60, 70, 80])
        #expect(staging.lost == 0)

        // Drop an encoder after flush without submitting it -> lost increments by 1
        do {
            let droppedEnc = backend.createCommandEncoder()
            staging.writeBuffer(dst, offset: 16, data: [1, 1, 1, 1])
            staging.flush(into: droppedEnc)
            _ = droppedEnc
        }
        #expect(staging.lost == 1)
    }

    @Test("Auto-submit past maxPending (16 MiB), oversized chunk not kept past keepChunkMax, and trim")
    func overflowAutoSubmitOversizeAndTrim() {
        let backend = InMemoryStagingBackend()
        let staging = Staging(backend: backend)
        let dst = InMemoryStagingBuffer(size: 20 << 20)

        // Two 9 MiB writes trigger auto-submit on the second write because 9 + 9 > 16 MiB.
        let nineMiB = [UInt8](repeating: 0xAA, count: 9 << 20)
        staging.writeBuffer(dst, offset: 0, data: nineMiB)
        #expect(staging.stats.submits == 0)
        staging.writeBuffer(dst, offset: 9 << 20, data: nineMiB)
        #expect(staging.stats.submits == 1)
        staging.submit()
        #expect(staging.stats.submits == 2)

        // 9 MiB > keepChunkMax (1 MiB) so returned chunk is NOT retained; a small write allocates a fresh 128 KiB chunk.
        let chunksBeforeSmall = staging.stats.chunks
        staging.writeBuffer(dst, offset: 0, data: [7, 7, 7, 7])
        #expect(staging.stats.chunks == chunksBeforeSmall + 1)
        staging.submit()

        // trim() discards free/returned pool, so next write allocates a new chunk
        staging.trim()
        let chunksAfterTrim = staging.stats.chunks
        staging.writeBuffer(dst, offset: 0, data: [8, 8, 8, 8])
        #expect(staging.stats.chunks == chunksAfterTrim + 1)
        staging.submit()
    }

    @Test("Direct writer takes buffer writes in place and setDirect keeps first registration")
    func directWriterAndSetDirectFirstWins() {
        final class SetDirectTargetBuffer: StagingBufferHandle, @unchecked Sendable {
            var bytes: [UInt8]
            var length: Int { bytes.count }
            init(size: Int) { self.bytes = [UInt8](repeating: 0, count: size) }
            func write(offset: Int, from data: UnsafeRawBufferPointer) {
                for i in 0..<data.count { bytes[offset + i] = data[i] }
            }
        }
        final class CallCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var _count = 0
            var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
            func increment() { lock.lock(); _count += 1; lock.unlock() }
        }

        let backend = InMemoryStagingBackend()
        let globalFirst = CallCounter()
        let globalSecond = CallCounter()
        Staging.setDirect { buf, offset, data in
            guard let target = buf as? SetDirectTargetBuffer else { return false }
            globalFirst.increment()
            target.write(offset: offset, from: data)
            return true
        }
        Staging.setDirect { buf, _, _ in
            guard buf is SetDirectTargetBuffer else { return false }
            globalSecond.increment()
            return true
        }

        let globalStaging = Staging(backend: backend)
        let globalDst = SetDirectTargetBuffer(size: 64)
        globalStaging.writeBuffer(globalDst, offset: 8, data: [42, 43, 44, 45])
        #expect(Array(globalDst.bytes[8..<12]) == [42, 43, 44, 45])
        #expect(globalFirst.count == 1)
        #expect(globalSecond.count == 0)
        #expect(globalStaging.stats.direct == 1)
        #expect(globalStaging.stats.writes == 1)
        #expect(globalStaging.stats.bytes == 4)
        #expect(globalStaging.stats.chunks == 0)
        #expect(!globalStaging.busy)

        let instanceCalls = CallCounter()
        let instanceStaging = Staging(backend: backend, direct: { buf, offset, data in
            guard let mem = buf as? InMemoryStagingBuffer else { return false }
            instanceCalls.increment()
            mem.write(offset: offset, from: data)
            return true
        })
        let dst = InMemoryStagingBuffer(size: 32)
        instanceStaging.writeBuffer(dst, offset: 4, data: [9, 10, 11])
        #expect(Array(dst.readBytes()[4..<7]) == [9, 10, 11])
        #expect(instanceCalls.count == 1)
        #expect(instanceStaging.stats.direct == 1)
    }

    @Test("Queue passthrough backend skips staging chunks")
    func queuePassthroughSkipsStaging() {
        let backend = InMemoryStagingBackend(isQueuePassthrough: true)
        let staging = Staging(backend: backend)
        let dst = InMemoryStagingBuffer(size: 32)
        staging.writeBuffer(dst, offset: 4, data: [5, 6, 7, 8])
        #expect(Array(dst.readBytes()[4..<8]) == [5, 6, 7, 8])
        #expect(staging.stats.chunks == 0)
        #expect(!staging.busy)
    }

    @Test("Direct callback false fallback and 0-byte writeBuffer early return")
    func directFallbackAndZeroByteWrite() {
        let backend = InMemoryStagingBackend()
        let staging = Staging(backend: backend, direct: { _, _, _ in false })
        let dst = InMemoryStagingBuffer(size: 16)

        // 0-byte writeBuffer returns early without touching staging chunks or direct callback.
        staging.writeBuffer(dst, offset: 0, data: [])
        #expect(staging.stats.chunks == 0)
        #expect(staging.stats.direct == 0)
        #expect(!staging.busy)

        // When direct returns false, writeBuffer falls back to chunked staging.
        staging.writeBuffer(dst, offset: 2, data: [7, 8, 9])
        #expect(staging.stats.chunks == 1)
        #expect(staging.stats.direct == 0)
        let enc = backend.createCommandEncoder()
        staging.flush(into: enc)
        backend.submit(enc)
        #expect(Array(dst.readBytes()[2..<5]) == [7, 8, 9])
    }

    #if canImport(Metal)
    @Test("MetalStagingBackend copies buffer and texture rows on GPU when device is available")
    func metalBackendSmoke() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return
        }
        let staging = Staging(device: device, queue: queue)
        guard let rawDst = device.makeBuffer(length: 256, options: .storageModeShared) else { return }
        let dst = MetalStagingBufferHandle(rawDst)
        staging.writeBuffer(dst, offset: 0, data: [11, 22, 33, 44])
        let enc = MetalStagingCommandEncoder(commandBuffer: queue.makeCommandBuffer()!)
        staging.flush(into: enc)
        enc.commandBuffer.commit()
        enc.commandBuffer.waitUntilCompleted()
        let bytes = rawDst.contents().assumingMemoryBound(to: UInt8.self)
        #expect([bytes[0], bytes[1], bytes[2], bytes[3]] == [11, 22, 33, 44])
    }
    #endif
}
