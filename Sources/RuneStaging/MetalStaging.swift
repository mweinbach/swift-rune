#if canImport(Metal)
import Foundation
@preconcurrency import Metal

/// Metal `MTLBuffer` wrapper conforming to `StagingBufferHandle`.
public final class MetalStagingBufferHandle: StagingBufferHandle, @unchecked Sendable {
    public let buffer: MTLBuffer
    public var length: Int { buffer.length }

    public init(_ buffer: MTLBuffer) {
        self.buffer = buffer
    }
}

/// Metal `MTLTexture` wrapper conforming to `StagingTextureHandle`.
public final class MetalStagingTextureHandle: StagingTextureHandle, @unchecked Sendable {
    public let texture: MTLTexture
    public let bytesPerPixel: Int
    public var width: Int { texture.width }
    public var height: Int { texture.height }

    public init(_ texture: MTLTexture, bytesPerPixel: Int = 4) {
        self.texture = texture
        self.bytesPerPixel = bytesPerPixel
    }
}

/// Shared-memory `MTLBuffer` chunk for `MetalStagingBackend`.
public final class MetalStagingChunkBuffer: StagingChunkBuffer, @unchecked Sendable {
    public let buffer: MTLBuffer
    public var length: Int { buffer.length }

    public init(_ buffer: MTLBuffer) {
        self.buffer = buffer
    }

    public func withMappedBytes(_ body: (UnsafeMutableRawBufferPointer) -> Void) -> Bool {
        let span = UnsafeMutableRawBufferPointer(start: buffer.contents(), count: buffer.length)
        body(span)
        return true
    }

    public func unmap() {
        // Shared-memory Metal buffers remain CPU-addressable without unmap calls;
        // GPU synchronization is enforced by completion handlers below.
    }

    public func remapOnComplete(in encoder: any StagingCommandEncoder, completion: @escaping @Sendable (Bool) -> Void) {
        guard let metalEnc = encoder as? MetalStagingCommandEncoder else {
            completion(false)
            return
        }
        metalEnc.addCompletion(completion)
    }
}

/// Metal command buffer encoder recording blit copies and recycling staging chunks on completion.
public final class MetalStagingCommandEncoder: StagingCommandEncoder, @unchecked Sendable {
    public let commandBuffer: MTLCommandBuffer
    private let lock = NSLock()
    private var completions: [@Sendable (Bool) -> Void] = []
    private var handlerInstalled = false

    public init(commandBuffer: MTLCommandBuffer) {
        self.commandBuffer = commandBuffer
    }

    public func copyBuffer(
        from src: any StagingChunkBuffer,
        sourceOffset: Int,
        to dst: any StagingBufferHandle,
        destinationOffset: Int,
        size: Int
    ) {
        guard let srcChunk = src as? MetalStagingChunkBuffer,
              let dstBuf = dst as? MetalStagingBufferHandle,
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return
        }
        blit.copy(
            from: srcChunk.buffer,
            sourceOffset: sourceOffset,
            to: dstBuf.buffer,
            destinationOffset: destinationOffset,
            size: size
        )
        blit.endEncoding()
    }

    public func copyBufferToTexture(
        from src: any StagingChunkBuffer,
        sourceOffset: Int,
        bytesPerRow: Int,
        to dst: any StagingTextureHandle,
        y: Int,
        rows: Int
    ) {
        guard let srcChunk = src as? MetalStagingChunkBuffer,
              let dstTex = dst as? MetalStagingTextureHandle,
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return
        }
        blit.copy(
            from: srcChunk.buffer,
            sourceOffset: sourceOffset,
            sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: bytesPerRow * rows,
            sourceSize: MTLSize(width: dstTex.width, height: rows, depth: 1),
            to: dstTex.texture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: y, z: 0)
        )
        blit.endEncoding()
    }

    func addCompletion(_ completion: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        completions.append(completion)
        let shouldInstall = !handlerInstalled
        handlerInstalled = true
        lock.unlock()

        if shouldInstall {
            commandBuffer.addCompletedHandler { [weak self] cb in
                guard let self else { return }
                self.lock.lock()
                let list = self.completions
                self.completions.removeAll()
                self.lock.unlock()
                let ok = cb.status == .completed
                for cbItem in list {
                    cbItem(ok)
                }
            }
        }
    }

    deinit {
        lock.lock()
        let remaining = completions
        completions.removeAll()
        lock.unlock()
        for item in remaining {
            item(false)
        }
    }
}

/// Metal backend for `Staging`.
public final class MetalStagingBackend: StagingBackend, @unchecked Sendable {
    public let device: MTLDevice
    public let queue: MTLCommandQueue

    public init(device: MTLDevice, queue: MTLCommandQueue) {
        self.device = device
        self.queue = queue
    }

    public func createStagingChunk(size: Int) -> any StagingChunkBuffer {
        guard let buf = device.makeBuffer(length: max(256, size), options: .storageModeShared) else {
            fatalError("MetalStagingBackend failed to allocate \(size)-byte staging buffer")
        }
        buf.label = "rune staging"
        return MetalStagingChunkBuffer(buf)
    }

    public func createCommandEncoder() -> any StagingCommandEncoder {
        guard let cb = queue.makeCommandBuffer() else {
            fatalError("MetalStagingBackend failed to create MTLCommandBuffer")
        }
        cb.label = "rune uploads"
        return MetalStagingCommandEncoder(commandBuffer: cb)
    }

    public func submit(_ encoder: any StagingCommandEncoder) {
        guard let metalEnc = encoder as? MetalStagingCommandEncoder else { return }
        metalEnc.commandBuffer.commit()
    }

    public func writeQueueBuffer(_ buffer: any StagingBufferHandle, offset: Int, data: UnsafeRawBufferPointer) {
        guard let metalBuf = buffer as? MetalStagingBufferHandle,
              offset >= 0,
              offset + data.count <= metalBuf.length,
              let src = data.baseAddress else {
            return
        }
        metalBuf.buffer.contents().advanced(by: offset).copyMemory(from: src, byteCount: data.count)
    }

    public func writeQueueTextureRows(
        _ texture: any StagingTextureHandle,
        y: Int,
        bytesPerRow: Int,
        rows: Int,
        data: UnsafeRawBufferPointer
    ) {
        guard let metalTex = texture as? MetalStagingTextureHandle, let src = data.baseAddress else { return }
        metalTex.texture.replace(
            region: MTLRegionMake2D(0, y, metalTex.width, rows),
            mipmapLevel: 0,
            withBytes: src,
            bytesPerRow: bytesPerRow
        )
    }
}

public extension Staging {
    convenience init(device: MTLDevice, queue: MTLCommandQueue) {
        self.init(backend: MetalStagingBackend(device: device, queue: queue))
    }
}
#endif
