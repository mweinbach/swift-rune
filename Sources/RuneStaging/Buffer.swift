import Foundation
#if canImport(Metal)
@preconcurrency import Metal
#endif

/// Byte alignment required for 2D texture-to-buffer row copies (`256` bytes, matching
/// `wgpu::COPY_BYTES_PER_ROW_ALIGNMENT` and `Staging.rowAlign`).
public let copyBytesPerRowAlignment: UInt32 = UInt32(Staging.rowAlign)

/// Row stride in bytes for a texture copy of `width` pixels at `bytesPerPixel` bytes each,
/// rounded up to `copyBytesPerRowAlignment` (`256` bytes).
@inline(__always)
public func paddedRowBytes(width: UInt32, bytesPerPixel: UInt32) -> UInt32 {
    let align = copyBytesPerRowAlignment
    let row = width * bytesPerPixel
    let (q, r) = row.quotientAndRemainder(dividingBy: align)
    return (q + (r == 0 ? 0 : 1)) * align
}

/// Copies `height` tightly packed rows of `rowBytes` bytes each out of `data`, whose rows are
/// `paddedRow` bytes apart.
public func unpadRows(_ data: UnsafeRawBufferPointer, rowBytes: Int, height: UInt32, paddedRow: UInt32) -> [UInt8] {
    let h = Int(height)
    guard h > 0, rowBytes > 0, let srcBase = data.baseAddress else {
        return []
    }
    let stride = Int(paddedRow)
    var out = [UInt8](repeating: 0, count: rowBytes * h)
    out.withUnsafeMutableBytes { dst in
        guard let dstBase = dst.baseAddress else { return }
        for y in 0..<h {
            let start = y * stride
            precondition(start + rowBytes <= data.count, "unpadRows source buffer shorter than padded rows")
            dstBase.advanced(by: y * rowBytes).copyMemory(from: srcBase.advanced(by: start), byteCount: rowBytes)
        }
    }
    return out
}

/// Copies `height` tightly packed rows of `rowBytes` bytes each out of `data`, whose rows are
/// `paddedRow` bytes apart.
public func unpadRows(_ data: [UInt8], rowBytes: Int, height: UInt32, paddedRow: UInt32) -> [UInt8] {
    data.withUnsafeBytes { raw in
        unpadRows(raw, rowBytes: rowBytes, height: height, paddedRow: paddedRow)
    }
}

@inline(__always)
private func nextPowerOfTwoCount(_ value: Int) -> Int {
    if value <= 1 { return 1 }
    var v = UInt(value - 1)
    v |= v >> 1
    v |= v >> 2
    v |= v >> 4
    v |= v >> 8
    v |= v >> 16
    if MemoryLayout<UInt>.size == 8 {
        v |= v >> 32
    }
    return Int(v + 1)
}

#if canImport(Metal)
/// A non-generic growable Metal buffer holding fixed-stride items that grows to the next power
/// of two when `ensure(device:count:)` sees a count past its current capacity.
///
/// Mirrors `rune_staging::GrowBuffer`: on the steady path `ensure` is a single comparison and
/// allocates nothing. When it returns `true`, the underlying `MTLBuffer` was replaced and
/// callers must rebind or rewrite.
public struct GrowBuffer: @unchecked Sendable {
    public private(set) var buffer: MTLBuffer
    public let label: String
    public let options: MTLResourceOptions
    public let stride: Int
    public let minBytes: Int
    public private(set) var capacity: Int

    /// Allocates a buffer for `initialCapacity` items of `stride` bytes, floored to `minBytes`.
    public init(
        device: MTLDevice,
        label: String,
        options: MTLResourceOptions = .storageModeShared,
        stride: Int,
        initialCapacity: Int,
        minBytes: Int = 0
    ) {
        let cap = max(initialCapacity, 0)
        self.label = label
        self.options = options
        self.stride = max(stride, 1)
        self.minBytes = max(minBytes, 0)
        self.capacity = cap
        self.buffer = Self.alloc(
            device: device,
            label: label,
            options: options,
            stride: self.stride,
            capacity: cap,
            minBytes: self.minBytes
        )
    }

    /// Ensures room for at least `count` items. Returns `true` if a new buffer was allocated
    /// (capacity grows to the next power of two >= `count`).
    @inline(__always)
    public mutating func ensure(device: MTLDevice, count: Int) -> Bool {
        if count <= capacity {
            return false
        }
        grow(device: device, count: count)
        return true
    }

    private mutating func grow(device: MTLDevice, count: Int) {
        capacity = nextPowerOfTwoCount(count)
        buffer = Self.alloc(
            device: device,
            label: label,
            options: options,
            stride: stride,
            capacity: capacity,
            minBytes: minBytes
        )
    }

    private static func alloc(
        device: MTLDevice,
        label: String,
        options: MTLResourceOptions,
        stride: Int,
        capacity: Int,
        minBytes: Int
    ) -> MTLBuffer {
        let requested = max(capacity * stride, minBytes)
        let length = max(requested, 1)
        guard let buf = device.makeBuffer(length: length, options: options) else {
            fatalError("GrowBuffer failed to allocate \(length)-byte Metal buffer '\(label)'")
        }
        buf.label = label
        return buf
    }

    /// Byte length of the currently allocated backing `MTLBuffer`.
    @inline(__always)
    public var byteLength: Int {
        buffer.length
    }
}

/// A reusable CPU-readable shared Metal buffer sized to read back a 2D texture (`rune_staging::Readback`).
public struct Readback: @unchecked Sendable {
    public let buffer: MTLBuffer
    public let width: UInt32
    public let height: UInt32
    public let bytesPerPixel: UInt32
    public let paddedRow: UInt32

    public init(
        device: MTLDevice,
        label: String = "readback",
        width: UInt32,
        height: UInt32,
        bytesPerPixel: UInt32
    ) {
        let padded = paddedRowBytes(width: width, bytesPerPixel: bytesPerPixel)
        let totalBytes = max(Int(padded) * Int(height), 1)
        guard let buf = device.makeBuffer(length: totalBytes, options: .storageModeShared) else {
            fatalError("Readback failed to allocate \(totalBytes)-byte Metal buffer '\(label)'")
        }
        buf.label = label
        self.buffer = buf
        self.width = width
        self.height = height
        self.bytesPerPixel = bytesPerPixel
        self.paddedRow = padded
    }

    /// Unpadded row width in bytes (`width * bytesPerPixel`).
    @inline(__always)
    public var rowBytes: Int {
        Int(width * bytesPerPixel)
    }

    /// Records a blit copy of `texture`'s mip 0 from `(0, 0, 0)` into this readback buffer.
    public func copyFrom(commandBuffer: MTLCommandBuffer, texture: MTLTexture) {
        copyFrom(commandBuffer: commandBuffer, texture: texture, origin: MTLOrigin(x: 0, y: 0, z: 0))
    }

    /// Records a blit copy of `texture`'s mip 0 starting at `origin` into this readback buffer.
    public func copyFrom(commandBuffer: MTLCommandBuffer, texture: MTLTexture, origin: MTLOrigin) {
        guard width > 0, height > 0, let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        copyFrom(blitEncoder: blit, texture: texture, origin: origin)
        blit.endEncoding()
    }

    /// Records a blit copy of `texture`'s mip 0 starting at `origin` into an active blit encoder.
    public func copyFrom(
        blitEncoder: MTLBlitCommandEncoder,
        texture: MTLTexture,
        origin: MTLOrigin = MTLOrigin(x: 0, y: 0, z: 0)
    ) {
        guard width > 0, height > 0 else { return }
        let stride = Int(paddedRow)
        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: origin,
            sourceSize: MTLSize(width: Int(width), height: Int(height), depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: stride,
            destinationBytesPerImage: stride * Int(height)
        )
    }

    /// Unpads pixels out of the shared readback buffer, returning `nil` if the buffer is too small.
    public func tryTakeMapped() -> [UInt8]? {
        let needed = Int(paddedRow) * Int(height)
        guard needed <= buffer.length else { return nil }
        let span = UnsafeRawBufferPointer(start: buffer.contents(), count: needed)
        return unpadRows(span, rowBytes: rowBytes, height: height, paddedRow: paddedRow)
    }

    /// Unpads pixels out of the shared readback buffer.
    public func takeMapped() -> [UInt8] {
        guard let pixels = tryTakeMapped() else {
            fatalError("Readback buffer length \(buffer.length) smaller than \(Int(paddedRow) * Int(height))")
        }
        return pixels
    }

    /// Waits for `commandBuffer` to finish executing and returns unpadded pixels, or `nil` on GPU error.
    public func tryRead(commandBuffer: MTLCommandBuffer) -> [UInt8]? {
        if commandBuffer.status != .completed && commandBuffer.status != .error {
            commandBuffer.waitUntilCompleted()
        }
        guard commandBuffer.status == .completed else { return nil }
        return tryTakeMapped()
    }

    /// Waits for `commandBuffer` to finish executing and returns unpadded pixels.
    public func read(commandBuffer: MTLCommandBuffer) -> [UInt8] {
        if commandBuffer.status != .completed && commandBuffer.status != .error {
            commandBuffer.waitUntilCompleted()
        }
        precondition(commandBuffer.status == .completed, "Readback command buffer failed: \(String(describing: commandBuffer.error))")
        return takeMapped()
    }
}
#endif
