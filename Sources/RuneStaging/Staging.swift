import Foundation

/// Process-wide direct buffer write hook (matches `rune_staging::Direct`).
/// Returns `true` if the write was written directly in place, or `false` to fall back to staging.
public typealias StagingDirect = @Sendable (
    _ buffer: any StagingBufferHandle,
    _ offset: Int,
    _ data: UnsafeRawBufferPointer
) -> Bool

/// Upload telemetry counters (matches `rune_staging::Stats`).
public struct StagingStats: Sendable, Equatable, Hashable {
    /// Chunks created (each one buffer allocation).
    public var chunks: UInt64 = 0
    /// Writes staged (including direct writes).
    public var writes: UInt64 = 0
    /// Bytes staged or written directly, including row-alignment padding.
    public var bytes: UInt64 = 0
    /// Pending write batches encoded via `flush` or `record`.
    public var flushes: UInt64 = 0
    /// Pending write batches submitted on their own queue encoder.
    public var submits: UInt64 = 0
    /// Buffer writes handled in place by the `Direct` writer (also counted in `writes` and `bytes`).
    public var direct: UInt64 = 0

    public init(
        chunks: UInt64 = 0,
        writes: UInt64 = 0,
        bytes: UInt64 = 0,
        flushes: UInt64 = 0,
        submits: UInt64 = 0,
        direct: UInt64 = 0
    ) {
        self.chunks = chunks
        self.writes = writes
        self.bytes = bytes
        self.flushes = flushes
        self.submits = submits
        self.direct = direct
    }
}

/// Destination GPU/mock buffer handle for `Staging`.
public protocol StagingBufferHandle: AnyObject, Sendable {
    var length: Int { get }
}

/// Destination GPU/mock texture handle for `Staging`.
public protocol StagingTextureHandle: AnyObject, Sendable {
    var width: Int { get }
    var height: Int { get }
    var bytesPerPixel: Int { get }
}

/// CPU-mappable staging buffer chunk owned by `Staging`.
public protocol StagingChunkBuffer: StagingBufferHandle {
    /// Exposes the mapped writable span for the whole chunk.
    /// Returns `false` if mapping failed (e.g., lost device).
    func withMappedBytes(_ body: (UnsafeMutableRawBufferPointer) -> Void) -> Bool
    /// Unmaps the chunk ahead of GPU command buffer submission.
    func unmap()
    /// Schedules the chunk to be re-mapped for CPU writes once `encoder` finishes executing on the GPU.
    /// Passes `true` when GPU execution succeeded and the chunk is mapped again, or `false` if dropped/lost.
    func remapOnComplete(in encoder: any StagingCommandEncoder, completion: @escaping @Sendable (Bool) -> Void)
}

/// Command encoder recording copy commands from staged chunks to destination buffers/textures.
public protocol StagingCommandEncoder: AnyObject, Sendable {
    func copyBuffer(
        from src: any StagingChunkBuffer,
        sourceOffset: Int,
        to dst: any StagingBufferHandle,
        destinationOffset: Int,
        size: Int
    )
    func copyBufferToTexture(
        from src: any StagingChunkBuffer,
        sourceOffset: Int,
        bytesPerRow: Int,
        to dst: any StagingTextureHandle,
        y: Int,
        rows: Int
    )
}

/// Backend abstraction allowing `Staging` to drive Metal on Apple platforms and an in-memory backend in portable tests.
public protocol StagingBackend: Sendable {
    var isQueuePassthrough: Bool { get }
    var rowAlignment: Int { get }
    var copyBufferAlignment: Int { get }
    var mapAlignment: Int { get }

    func createStagingChunk(size: Int) -> any StagingChunkBuffer
    func createCommandEncoder() -> any StagingCommandEncoder
    func submit(_ encoder: any StagingCommandEncoder)
    func writeQueueBuffer(_ buffer: any StagingBufferHandle, offset: Int, data: UnsafeRawBufferPointer)
    func writeQueueTextureRows(
        _ texture: any StagingTextureHandle,
        y: Int,
        bytesPerRow: Int,
        rows: Int,
        data: UnsafeRawBufferPointer
    )
}

public extension StagingBackend {
    var isQueuePassthrough: Bool { false }
    var rowAlignment: Int { Staging.rowAlign }
    var copyBufferAlignment: Int { Staging.copyBufferAlignment }
    var mapAlignment: Int { Staging.mapAlignment }
}

private final class GlobalDirectRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var registered: StagingDirect?

    func setIfUnset(_ direct: @escaping StagingDirect) {
        lock.lock()
        defer { lock.unlock() }
        if registered == nil {
            registered = direct
        }
    }

    func get() -> StagingDirect? {
        lock.lock()
        defer { lock.unlock() }
        return registered
    }
}

private let globalDirectRegistry = GlobalDirectRegistry()

@inline(__always)
private func alignUp(_ value: Int, to alignment: Int) -> Int {
    guard alignment > 1 else { return value }
    let rem = value % alignment
    return rem == 0 ? value : value + (alignment - rem)
}

@inline(__always)
private func nextPowerOfTwo(_ value: Int) -> Int {
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

private final class ChunkState: @unchecked Sendable {
    let buffer: any StagingChunkBuffer
    var used: Int = 0
    var mapped: Bool = true

    init(buffer: any StagingChunkBuffer) {
        self.buffer = buffer
    }
}

private enum CopyDestination: @unchecked Sendable {
    case buffer(any StagingBufferHandle, Int)
    case textureRows(any StagingTextureHandle, y: Int, rows: Int, bytesPerRow: Int)
}

private struct PendingWrite: @unchecked Sendable {
    let src: any StagingChunkBuffer
    let offset: Int
    let size: Int
    let destination: CopyDestination
}

/// Hands a chunk back when GPU execution completes; if dropped without succeeding (unsubmitted encoder or lost device),
/// increments `lostCounter`.
private final class ChunkReturnGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var chunk: ChunkState?
    private let recycle: @Sendable (ChunkState) -> Void
    private let onLost: @Sendable () -> Void

    init(
        chunk: ChunkState,
        recycle: @escaping @Sendable (ChunkState) -> Void,
        onLost: @escaping @Sendable () -> Void
    ) {
        self.chunk = chunk
        self.recycle = recycle
        self.onLost = onLost
    }

    func complete(succeeded: Bool) {
        lock.lock()
        let taken = chunk
        chunk = nil
        lock.unlock()
        guard let taken else { return }
        if succeeded {
            recycle(taken)
        } else {
            onLost()
        }
    }

    deinit {
        lock.lock()
        let unreturned = chunk != nil
        chunk = nil
        lock.unlock()
        if unreturned {
            onLost()
        }
    }
}

/// Per-frame GPU upload staging pool matching `crates/rune-staging`.
public final class Staging: @unchecked Sendable {
    /// Size of a standard pooled staging chunk (`128 KiB`).
    public static let chunkSize: Int = 128 * 1024
    /// Maximum returned chunks kept in the free pool.
    public static let keepChunks: Int = 8
    /// Maximum aggregate bytes kept in the free pool (`4 MiB`).
    public static let keepBytes: Int = 4 << 20
    /// Maximum individual chunk size eligible for retention (`1 MiB`).
    public static let keepChunkMax: Int = 1 << 20
    /// Pending staged bytes threshold above which `write*` auto-submits (`16 MiB`).
    public static let maxPending: Int = 16 << 20
    /// Alignment for texture row copies (`256` bytes).
    public static let rowAlign: Int = 256
    /// Alignment for buffer copy sizes/offsets (`4` bytes).
    public static let copyBufferAlignment: Int = 4
    /// Alignment for mapped buffer writes (`8` bytes).
    public static let mapAlignment: Int = 8

    /// Registers the process's `Direct` writer. The first registration wins.
    public static func setDirect(_ direct: @escaping StagingDirect) {
        globalDirectRegistry.setIfUnset(direct)
    }

    private let backend: any StagingBackend
    private let customDirect: StagingDirect?

    private let lock = NSLock()
    private let stateLock = NSLock()
    private let returnLock = NSLock()
    private var active: [ChunkState] = []
    private var free: [ChunkState] = []
    private var returned: [ChunkState] = []
    private var pending: [PendingWrite] = []
    private var pendingBytes: Int = 0
    private var _stats = StagingStats()
    private var _busy: Bool = false
    private var _lost: UInt64 = 0

    public init(backend: any StagingBackend, direct: StagingDirect? = nil) {
        self.backend = backend
        self.customDirect = direct
    }

    /// Whether writes are pending or active chunks are still mapped since the last `flush` or `submit`.
    public var busy: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _busy
    }

    /// Whether staged writes are waiting for `flush` or `submit`.
    public var isPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !pending.isEmpty
    }

    /// Chunks whose writes may never have landed because their encoder was dropped unsubmitted or device was lost.
    public var lost: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _lost
    }

    /// Snapshot of staging statistics.
    public var stats: StagingStats {
        lock.lock()
        defer { lock.unlock() }
        return _stats
    }

    /// Stages a write of `data` to `buffer` at `offset` (or handles it in place via `Direct`).
    public func writeBuffer(_ buffer: any StagingBufferHandle, offset: Int, data: UnsafeRawBufferPointer) {
        guard !data.isEmpty else { return }
        if let direct = customDirect ?? globalDirectRegistry.get(), direct(buffer, offset, data) {
            lock.lock()
            _stats.direct += 1
            _stats.writes += 1
            _stats.bytes += UInt64(data.count)
            lock.unlock()
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if backend.isQueuePassthrough {
            backend.writeQueueBuffer(buffer, offset: offset, data: data)
            return
        }
        let size = data.count
        let (src, at) = stageLocked(size: size, align: backend.mapAlignment) { dstSpan in
            guard let srcBase = data.baseAddress, let dstBase = dstSpan.baseAddress else { return }
            dstBase.copyMemory(from: srcBase, byteCount: size)
        }
        pending.append(PendingWrite(src: src, offset: at, size: size, destination: .buffer(buffer, offset)))
    }

    public func writeBuffer(_ buffer: any StagingBufferHandle, offset: Int, data: [UInt8]) {
        data.withUnsafeBytes { raw in
            writeBuffer(buffer, offset: offset, data: raw)
        }
    }

    public func writeBuffer(_ buffer: any StagingBufferHandle, offset: Int, data: Data) {
        data.withUnsafeBytes { raw in
            writeBuffer(buffer, offset: offset, data: raw)
        }
    }

    /// Stages a write of tightly packed full-width texture rows starting at row `y`.
    public func writeTextureRows(_ texture: any StagingTextureHandle, y: Int, rows: UnsafeRawBufferPointer) {
        let rowBytes = texture.width * texture.bytesPerPixel
        guard rowBytes > 0 else { return }
        let count = rows.count / rowBytes
        guard count > 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        if backend.isQueuePassthrough {
            backend.writeQueueTextureRows(texture, y: y, bytesPerRow: rowBytes, rows: count, data: rows)
            return
        }
        let rowAlign = backend.rowAlignment
        let padded = alignUp(rowBytes, to: rowAlign)
        let size = padded * count
        let (src, at) = stageLocked(size: size, align: rowAlign) { dstSpan in
            guard let srcBase = rows.baseAddress, let dstBase = dstSpan.baseAddress else { return }
            if padded == rowBytes {
                dstBase.copyMemory(from: srcBase, byteCount: size)
            } else {
                for r in 0..<count {
                    let dstPtr = dstBase.advanced(by: r * padded)
                    let srcPtr = srcBase.advanced(by: r * rowBytes)
                    dstPtr.copyMemory(from: srcPtr, byteCount: rowBytes)
                }
            }
        }
        pending.append(PendingWrite(
            src: src,
            offset: at,
            size: size,
            destination: .textureRows(texture, y: y, rows: count, bytesPerRow: padded)
        ))
    }

    public func writeTextureRows(_ texture: any StagingTextureHandle, y: Int, rows: [UInt8]) {
        rows.withUnsafeBytes { raw in
            writeTextureRows(texture, y: y, rows: raw)
        }
    }

    public func writeTextureRows(_ texture: any StagingTextureHandle, y: Int, rows: Data) {
        rows.withUnsafeBytes { raw in
            writeTextureRows(texture, y: y, rows: raw)
        }
    }

    /// Records pending writes into `encoder` and releases/unmaps active chunks for GPU execution.
    public func flush(into encoder: any StagingCommandEncoder) {
        guard busy else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty || !active.isEmpty else { return }
        encodeLocked(into: encoder)
        _stats.flushes += 1
    }

    /// Records pending copies into `encoder` while leaving active chunks mapped so subsequent writes share them.
    public func record(into encoder: any StagingCommandEncoder) {
        guard busy else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return }
        copyLocked(into: encoder)
        _stats.flushes += 1
    }

    /// Submits pending writes immediately on a dedicated command encoder.
    public func submit() {
        guard busy else { return }
        lock.lock()
        defer { lock.unlock() }
        submitLocked()
    }

    /// Frees chunks kept for reuse (including chunks returned by the GPU). Chunks with pending writes stay.
    public func trim() {
        lock.lock()
        returnLock.lock()
        returned.removeAll()
        returnLock.unlock()
        free.removeAll()
        lock.unlock()
    }

    // MARK: - Internal Locked Operations

    private func setBusy(_ flag: Bool) {
        stateLock.lock()
        _busy = flag
        stateLock.unlock()
    }

    private func incrementLost() {
        stateLock.lock()
        _lost += 1
        stateLock.unlock()
    }

    private func stageLocked(
        size rawSize: Int,
        align: Int,
        fill: (UnsafeMutableRawBufferPointer) -> Void
    ) -> (any StagingChunkBuffer, Int) {
        let size = alignUp(rawSize, to: backend.copyBufferAlignment)
        if pendingBytes + size > Self.maxPending {
            submitLocked()
        }

        let index: Int
        if let existing = active.firstIndex(where: { alignUp($0.used, to: align) + size <= $0.buffer.length }) {
            index = existing
        } else {
            receiveLocked()
            let chunk: ChunkState
            if let freeIdx = free.firstIndex(where: { $0.buffer.length >= size }) {
                chunk = free.swapRemove(freeIdx)
            } else {
                _stats.chunks += 1
                let cap = max(Self.chunkSize, nextPowerOfTwo(size))
                let buf = backend.createStagingChunk(size: cap)
                chunk = ChunkState(buffer: buf)
            }
            active.append(chunk)
            index = active.count - 1
        }

        let chunk = active[index]
        let at = alignUp(chunk.used, to: align)
        chunk.used = at + size
        let mappedOk = chunk.buffer.withMappedBytes { fullSpan in
            guard let base = fullSpan.baseAddress, at + size <= fullSpan.count else { return }
            let slice = UnsafeMutableRawBufferPointer(start: base.advanced(by: at), count: size)
            fill(slice)
        }
        guard mappedOk else {
            return (chunk.buffer, at)
        }
        pendingBytes += size
        _stats.writes += 1
        _stats.bytes += UInt64(size)
        setBusy(true)
        return (chunk.buffer, at)
    }

    private func receiveLocked() {
        returnLock.lock()
        guard !returned.isEmpty else {
            returnLock.unlock()
            return
        }
        let items = returned
        returned.removeAll(keepingCapacity: true)
        returnLock.unlock()
        for chunk in items {
            chunk.used = 0
            let kept = free.reduce(0) { $0 + $1.buffer.length }
            let size = chunk.buffer.length
            if size <= Self.keepChunkMax && free.count < Self.keepChunks && kept + size <= Self.keepBytes {
                free.append(chunk)
            }
        }
    }

    private func encodeLocked(into encoder: any StagingCommandEncoder) {
        copyLocked(into: encoder)
        let drained = active
        active.removeAll(keepingCapacity: true)
        for chunk in drained {
            chunk.mapped = false
            chunk.buffer.unmap()
            let buffer = chunk.buffer
            let returnGuard = ChunkReturnGuard(
                chunk: chunk,
                recycle: { [weak self] returnedChunk in
                    guard let self else { return }
                    self.returnLock.lock()
                    returnedChunk.mapped = true
                    self.returned.append(returnedChunk)
                    self.returnLock.unlock()
                },
                onLost: { [weak self] in
                    self?.incrementLost()
                }
            )
            buffer.remapOnComplete(in: encoder) { succeeded in
                returnGuard.complete(succeeded: succeeded)
            }
        }
        setBusy(false)
    }

    private func copyLocked(into encoder: any StagingCommandEncoder) {
        for p in pending {
            switch p.destination {
            case .buffer(let dst, let dstOffset):
                encoder.copyBuffer(
                    from: p.src,
                    sourceOffset: p.offset,
                    to: dst,
                    destinationOffset: dstOffset,
                    size: p.size
                )
            case .textureRows(let tex, let y, let rows, let bytesPerRow):
                encoder.copyBufferToTexture(
                    from: p.src,
                    sourceOffset: p.offset,
                    bytesPerRow: bytesPerRow,
                    to: tex,
                    y: y,
                    rows: rows
                )
            }
        }
        pending.removeAll(keepingCapacity: true)
        pendingBytes = 0
    }

    private func submitLocked() {
        guard !pending.isEmpty else { return }
        let encoder = backend.createCommandEncoder()
        encodeLocked(into: encoder)
        backend.submit(encoder)
        _stats.submits += 1
    }
}

private extension Array {
    mutating func swapRemove(_ index: Int) -> Element {
        if index != count - 1 {
            swapAt(index, count - 1)
        }
        return removeLast()
    }
}

// MARK: - Portable In-Memory Backend (Cross-Platform & Tests)

/// In-memory buffer handle used by `InMemoryStagingBackend`.
public final class InMemoryStagingBuffer: StagingBufferHandle, @unchecked Sendable {
    private let lock = NSLock()
    public var bytes: [UInt8]
    public var length: Int { bytes.count }

    public init(size: Int) {
        self.bytes = [UInt8](repeating: 0, count: max(0, size))
    }

    public func write(offset: Int, from src: UnsafeRawBufferPointer) {
        lock.lock()
        defer { lock.unlock() }
        guard offset >= 0, offset + src.count <= bytes.count, let base = src.baseAddress else { return }
        bytes.withUnsafeMutableBytes { dst in
            dst.baseAddress?.advanced(by: offset).copyMemory(from: base, byteCount: src.count)
        }
    }

    public func readBytes() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

/// In-memory texture handle used by `InMemoryStagingBackend`.
public final class InMemoryStagingTexture: StagingTextureHandle, @unchecked Sendable {
    private let lock = NSLock()
    public let width: Int
    public let height: Int
    public let bytesPerPixel: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int, bytesPerPixel: Int = 4) {
        self.width = width
        self.height = height
        self.bytesPerPixel = bytesPerPixel
        self.bytes = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
    }

    public func writeRows(
        from src: UnsafeRawBufferPointer,
        sourceOffset: Int,
        bytesPerRow: Int,
        y: Int,
        rows: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        let rowWidth = width * bytesPerPixel
        guard let base = src.baseAddress else { return }
        bytes.withUnsafeMutableBytes { dst in
            guard let dstBase = dst.baseAddress else { return }
            for r in 0..<rows {
                let dstRow = y + r
                guard dstRow >= 0, dstRow < height else { continue }
                let sOff = sourceOffset + r * bytesPerRow
                let dOff = dstRow * rowWidth
                guard sOff + rowWidth <= src.count, dOff + rowWidth <= dst.count else { continue }
                dstBase.advanced(by: dOff).copyMemory(from: base.advanced(by: sOff), byteCount: rowWidth)
            }
        }
    }

    public func readBytes() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}

/// In-memory mapped staging chunk used by `InMemoryStagingBackend`.
public final class InMemoryStagingChunk: StagingChunkBuffer, @unchecked Sendable {
    private let lock = NSLock()
    public var storage: [UInt8]
    public var length: Int { storage.count }
    public private(set) var isMapped: Bool = true
    public var failNextMap: Bool = false

    public init(size: Int) {
        self.storage = [UInt8](repeating: 0, count: size)
    }

    public func withMappedBytes(_ body: (UnsafeMutableRawBufferPointer) -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isMapped, !failNextMap else { return false }
        storage.withUnsafeMutableBytes(body)
        return true
    }

    public func unmap() {
        lock.lock()
        isMapped = false
        lock.unlock()
    }

    public func remapOnComplete(in encoder: any StagingCommandEncoder, completion: @escaping @Sendable (Bool) -> Void) {
        guard let memEnc = encoder as? InMemoryStagingEncoder else {
            completion(false)
            return
        }
        memEnc.addCompletion { [weak self] ok in
            guard let self else {
                completion(false)
                return
            }
            self.lock.lock()
            let canMap = ok && !self.failNextMap
            if canMap {
                self.isMapped = true
            }
            self.lock.unlock()
            completion(canMap)
        }
    }

    func snapshotBytes() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// In-memory encoder that executes recorded copies upon `submit(_:)` and fires `false` if dropped unsubmitted.
public final class InMemoryStagingEncoder: StagingCommandEncoder, @unchecked Sendable {
    private let lock = NSLock()
    private var ops: [@Sendable () -> Void] = []
    private var completions: [@Sendable (Bool) -> Void] = []
    private var committed: Bool = false

    public init() {}

    public func copyBuffer(
        from src: any StagingChunkBuffer,
        sourceOffset: Int,
        to dst: any StagingBufferHandle,
        destinationOffset: Int,
        size: Int
    ) {
        guard let srcChunk = src as? InMemoryStagingChunk, let dstBuf = dst as? InMemoryStagingBuffer else { return }
        lock.lock()
        ops.append {
            let bytes = srcChunk.snapshotBytes()
            bytes.withUnsafeBytes { raw in
                guard sourceOffset + size <= raw.count, let base = raw.baseAddress else { return }
                let slice = UnsafeRawBufferPointer(start: base.advanced(by: sourceOffset), count: size)
                dstBuf.write(offset: destinationOffset, from: slice)
            }
        }
        lock.unlock()
    }

    public func copyBufferToTexture(
        from src: any StagingChunkBuffer,
        sourceOffset: Int,
        bytesPerRow: Int,
        to dst: any StagingTextureHandle,
        y: Int,
        rows: Int
    ) {
        guard let srcChunk = src as? InMemoryStagingChunk, let dstTex = dst as? InMemoryStagingTexture else { return }
        lock.lock()
        ops.append {
            let bytes = srcChunk.snapshotBytes()
            bytes.withUnsafeBytes { raw in
                dstTex.writeRows(from: raw, sourceOffset: sourceOffset, bytesPerRow: bytesPerRow, y: y, rows: rows)
            }
        }
        lock.unlock()
    }

    func addCompletion(_ cb: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        completions.append(cb)
        lock.unlock()
    }

    func finishAndRun() {
        lock.lock()
        committed = true
        let pendingOps = ops
        let pendingCompletions = completions
        ops.removeAll()
        completions.removeAll()
        lock.unlock()
        for op in pendingOps { op() }
        for cb in pendingCompletions { cb(true) }
    }

    deinit {
        lock.lock()
        let dropped = !committed
        let pendingCompletions = completions
        completions.removeAll()
        lock.unlock()
        if dropped {
            for cb in pendingCompletions { cb(false) }
        }
    }
}

/// Cross-platform in-memory staging backend for deterministic tests and headless simulation.
public final class InMemoryStagingBackend: StagingBackend, @unchecked Sendable {
    public let isQueuePassthrough: Bool
    private let lock = NSLock()
    public private(set) var createdChunks: Int = 0
    public private(set) var submittedEncoders: Int = 0
    public var onSubmitEncoder: (@Sendable (InMemoryStagingEncoder) -> Void)?

    public init(isQueuePassthrough: Bool = false) {
        self.isQueuePassthrough = isQueuePassthrough
    }

    public func createStagingChunk(size: Int) -> any StagingChunkBuffer {
        lock.lock()
        createdChunks += 1
        lock.unlock()
        return InMemoryStagingChunk(size: size)
    }

    public func createCommandEncoder() -> any StagingCommandEncoder {
        InMemoryStagingEncoder()
    }

    public func submit(_ encoder: any StagingCommandEncoder) {
        guard let memEnc = encoder as? InMemoryStagingEncoder else { return }
        lock.lock()
        submittedEncoders += 1
        let hook = onSubmitEncoder
        lock.unlock()
        if let hook {
            hook(memEnc)
        } else {
            memEnc.finishAndRun()
        }
    }

    public func writeQueueBuffer(_ buffer: any StagingBufferHandle, offset: Int, data: UnsafeRawBufferPointer) {
        (buffer as? InMemoryStagingBuffer)?.write(offset: offset, from: data)
    }

    public func writeQueueTextureRows(
        _ texture: any StagingTextureHandle,
        y: Int,
        bytesPerRow: Int,
        rows: Int,
        data: UnsafeRawBufferPointer
    ) {
        (texture as? InMemoryStagingTexture)?.writeRows(
            from: data,
            sourceOffset: 0,
            bytesPerRow: bytesPerRow,
            y: y,
            rows: rows
        )
    }
}
