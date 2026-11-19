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

        // Conflict isolation: a third setDirect registration for another buffer type is ignored
        // and does not hijack plain Staging(backend:) instances.
        final class IsolatedBuffer: StagingBufferHandle, @unchecked Sendable {
            let length = 32
        }
        let thirdCalls = CallCounter()
        Staging.setDirect { buf, _, _ in
            guard buf is IsolatedBuffer else { return false }
            thirdCalls.increment()
            return true
        }
        let plainStaging = Staging(backend: backend)
        let isolatedBuf = IsolatedBuffer()
        plainStaging.writeBuffer(isolatedBuf, offset: 0, data: [1, 2, 3, 4])
        #expect(thirdCalls.count == 0)
        #expect(plainStaging.stats.direct == 0)
        #expect(plainStaging.stats.chunks == 1)
        plainStaging.submit()
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

        // Real MTLTexture writeTextureRows upload + byte readback verification (non-256B row width).
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 10,
            height: 4,
            mipmapped: false
        )
        texDesc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        texDesc.usage = [.shaderRead]
        guard let rawTex = device.makeTexture(descriptor: texDesc) else { return }
        let texHandle = MetalStagingTextureHandle(rawTex, bytesPerPixel: 4)
        let rowBytes = 10 * 4
        var uploadRows = [UInt8](repeating: 0, count: rowBytes * 2)
        for i in 0..<uploadRows.count {
            uploadRows[i] = UInt8((i * 7 + 3) & 0xFF)
        }

        let texStaging = Staging(device: device, queue: queue)
        texStaging.writeTextureRows(texHandle, y: 1, rows: uploadRows)
        #expect(texStaging.stats.bytes == UInt64(Staging.rowAlign * 2))
        let texCB = queue.makeCommandBuffer()!
        let texEnc = MetalStagingCommandEncoder(commandBuffer: texCB)
        texStaging.flush(into: texEnc)
        if !device.hasUnifiedMemory, let syncBlit = texCB.makeBlitCommandEncoder() {
            syncBlit.synchronize(resource: rawTex)
            syncBlit.endEncoding()
        }
        texCB.commit()
        texCB.waitUntilCompleted()
        #expect(texCB.status == .completed)
        #expect(texStaging.lost == 0)
        #expect(!texStaging.busy)

        var readback = [UInt8](repeating: 0xCC, count: rowBytes * 4)
        readback.withUnsafeMutableBytes { ptr in
            rawTex.getBytes(
                ptr.baseAddress!,
                bytesPerRow: rowBytes,
                from: MTLRegionMake2D(0, 0, 10, 4),
                mipmapLevel: 0
            )
        }
        #expect(Array(readback[0..<rowBytes]) == [UInt8](repeating: 0, count: rowBytes))
        #expect(Array(readback[rowBytes..<(rowBytes * 3)]) == uploadRows)
        #expect(Array(readback[(rowBytes * 3)..<(rowBytes * 4)]) == [UInt8](repeating: 0, count: rowBytes))
    }
    #endif

    @Test("withMappedBytes failNextMap drops unmappable write and increments lost on failed remap")
    func withMappedBytesFailNextMapPath() {
        final class CapturingBackend: StagingBackend, @unchecked Sendable {
            let inner = InMemoryStagingBackend()
            private let lock = NSLock()
            var chunks: [InMemoryStagingChunk] = []
            var failOnCreate = false

            func createStagingChunk(size: Int) -> any StagingChunkBuffer {
                let c = inner.createStagingChunk(size: size) as! InMemoryStagingChunk
                lock.lock()
                if failOnCreate { c.failNextMap = true }
                chunks.append(c)
                lock.unlock()
                return c
            }
            func createCommandEncoder() -> any StagingCommandEncoder { inner.createCommandEncoder() }
            func submit(_ encoder: any StagingCommandEncoder) { inner.submit(encoder) }
            func writeQueueBuffer(_ buffer: any StagingBufferHandle, offset: Int, data: UnsafeRawBufferPointer) {
                inner.writeQueueBuffer(buffer, offset: offset, data: data)
            }
            func writeQueueTextureRows(_ texture: any StagingTextureHandle, y: Int, bytesPerRow: Int, rows: Int, data: UnsafeRawBufferPointer) {
                inner.writeQueueTextureRows(texture, y: y, bytesPerRow: bytesPerRow, rows: rows, data: data)
            }
        }

        // Case 1: initial withMappedBytes returns false -> stageLocked returns early without marking writes/busy.
        let failCreateBackend = CapturingBackend()
        failCreateBackend.failOnCreate = true
        let staging1 = Staging(backend: failCreateBackend)
        let dst1 = InMemoryStagingBuffer(size: 32)
        staging1.writeBuffer(dst1, offset: 0, data: [1, 2, 3, 4])
        #expect(staging1.stats.chunks == 1)
        #expect(staging1.stats.writes == 0)
        #expect(staging1.stats.bytes == 0)
        #expect(!staging1.busy)
        #expect(Array(dst1.readBytes()[0..<4]) == [0, 0, 0, 0])

        // Case 2: remap fails after submit -> lost increments and chunk is not recycled to free pool.
        let backend2 = CapturingBackend()
        let staging2 = Staging(backend: backend2)
        let dst2 = InMemoryStagingBuffer(size: 32)
        staging2.writeBuffer(dst2, offset: 0, data: [5, 6, 7, 8])
        #expect(staging2.stats.chunks == 1)
        #expect(staging2.stats.writes == 1)
        backend2.chunks[0].failNextMap = true
        staging2.submit()
        #expect(Array(dst2.readBytes()[0..<4]) == [5, 6, 7, 8])
        #expect(staging2.lost == 1)

        staging2.writeBuffer(dst2, offset: 8, data: [9, 10, 11, 12])
        #expect(staging2.stats.chunks == 2)
    }

    @Test("paddedRowBytes aligns to 256-byte texture copy alignment")
    func paddedRowBytesAlignsToCopyAlignment() {
        let align = copyBytesPerRowAlignment
        #expect(align == 256)
        #expect(paddedRowBytes(width: 0, bytesPerPixel: 4) == 0)
        #expect(paddedRowBytes(width: 1, bytesPerPixel: 4) == align)
        #expect(paddedRowBytes(width: 64, bytesPerPixel: 4) == 256)
        #expect(paddedRowBytes(width: 65, bytesPerPixel: 4) == 512)
        #expect(paddedRowBytes(width: 37, bytesPerPixel: 4) == align)
        #expect(paddedRowBytes(width: 2048, bytesPerPixel: 1) == 2048)
    }

    @Test("unpadRows strips trailing row padding")
    func unpadRowsStripsTrailingPadding() {
        let data: [UInt8] = [1, 2, 3, 4, 9, 9, 9, 9, 5, 6, 7, 8, 9, 9, 9, 9]
        #expect(unpadRows(data, rowBytes: 4, height: 2, paddedRow: 8) == [1, 2, 3, 4, 5, 6, 7, 8])
        #expect(unpadRows(Array(data.prefix(8)), rowBytes: 4, height: 1, paddedRow: 8) == [1, 2, 3, 4])
        #expect(unpadRows([], rowBytes: 4, height: 0, paddedRow: 256).isEmpty)
    }

    #if canImport(Metal)
    @Test("GrowBuffer reuses on steady ensure and doubles to power-of-two capacity on overflow")
    func metalGrowBufferLifecycle() {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var grow = GrowBuffer(
            device: device,
            label: "test grow",
            stride: 16,
            initialCapacity: 4,
            minBytes: 256
        )
        #expect(grow.capacity == 4)
        #expect(grow.byteLength == 256)
        let firstID = ObjectIdentifier(grow.buffer)

        let grew0 = grow.ensure(device: device, count: 0)
        #expect(!grew0)
        let grew4 = grow.ensure(device: device, count: 4)
        #expect(!grew4)
        #expect(ObjectIdentifier(grow.buffer) == firstID)

        // Growing past 4 items to 20 -> next power of two is 32 -> 32 * 16 = 512 bytes.
        let grew20 = grow.ensure(device: device, count: 20)
        #expect(grew20)
        #expect(grow.capacity == 32)
        #expect(grow.byteLength == 512)
        let secondID = ObjectIdentifier(grow.buffer)
        #expect(secondID != firstID)

        let grew32 = grow.ensure(device: device, count: 32)
        #expect(!grew32)
        #expect(ObjectIdentifier(grow.buffer) == secondID)
    }

    @Test("Readback copies full and sub-origin regions from a Metal texture and unpads rows")
    func metalReadbackFullAndOrigin() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return }

        let w = 10
        let h = 4
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        texDesc.storageMode = .shared
        texDesc.usage = [.shaderRead]
        let tex = try #require(device.makeTexture(descriptor: texDesc))

        var src = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                src[i] = UInt8(x * 20 + 1)
                src[i + 1] = UInt8(y * 50 + 2)
                src[i + 2] = UInt8((x + y) * 11 + 3)
                src[i + 3] = 255
            }
        }
        src.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: w * 4
            )
        }

        // Full texture readback (non-256B row width: 40 bytes -> padded to 256).
        let full = Readback(device: device, label: "full readback", width: UInt32(w), height: UInt32(h), bytesPerPixel: 4)
        #expect(full.paddedRow == 256)
        #expect(full.rowBytes == 40)
        let cb1 = try #require(queue.makeCommandBuffer())
        full.copyFrom(commandBuffer: cb1, texture: tex)
        cb1.commit()
        let fullPixels = full.read(commandBuffer: cb1)
        #expect(fullPixels == src)

        // Sub-rectangle readback from non-zero origin (3, 1), size 4x2.
        let sub = Readback(device: device, label: "sub readback", width: 4, height: 2, bytesPerPixel: 4)
        let cb2 = try #require(queue.makeCommandBuffer())
        sub.copyFrom(commandBuffer: cb2, texture: tex, origin: MTLOrigin(x: 3, y: 1, z: 0))
        cb2.commit()
        let subPixels = try #require(sub.tryRead(commandBuffer: cb2))
        var expectedSub: [UInt8] = []
        for y in 1..<3 {
            let rowStart = (y * w + 3) * 4
            expectedSub.append(contentsOf: src[rowStart..<(rowStart + 4 * 4)])
        }
        #expect(subPixels == expectedSub)
    }
    #endif
}
