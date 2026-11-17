#if canImport(Metal)
import Foundation
import Metal

/// A command encoder can outlive the next prepare. Metal snapshots small arguments in
/// its command stream; larger buffers become immutable as soon as an encoder binds them.
final class FxMetalBuffers {
    struct Storage {
        let device: MTLDevice
        private(set) var buffer: MTLBuffer
        private var used = 0
        private var bound = false
        private static let inlineLimit = 1024

        init(device: MTLDevice, label: String, capacity: Int) throws {
            self.device = device
            guard let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) else {
                throw FxRendererError.metalUnavailable
            }
            self.buffer = buffer
            buffer.label = label
        }

        mutating func upload<T>(_ elements: [T]) throws {
            try elements.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress, !bytes.isEmpty else { used = 0; return }
                if bound, bytes.count == used, memcmp(base, buffer.contents(), used) == 0 { return }
                try ensureWritable(bytes.count, preserve: false)
                memcpy(buffer.contents(), base, bytes.count)
                used = bytes.count
            }
        }

        mutating func update<T>(_ value: inout T, offset: Int) throws {
            try withUnsafeBytes(of: &value) { bytes in
                guard let base = bytes.baseAddress, offset >= 0, offset <= used - bytes.count else {
                    throw FxRendererError.bufferUnavailable
                }
                if memcmp(base, buffer.contents().advanced(by: offset), bytes.count) == 0 { return }
                try ensureWritable(used, preserve: true)
                memcpy(buffer.contents().advanced(by: offset), base, bytes.count)
            }
        }

        private mutating func ensureWritable(_ required: Int, preserve: Bool) throws {
            guard bound || required > buffer.length else { return }
            guard required <= device.maxBufferLength else { throw FxRendererError.bufferUnavailable }
            var capacity = buffer.length
            while capacity < required {
                capacity = capacity > device.maxBufferLength / 2 ? device.maxBufferLength : capacity * 2
            }
            guard let next = device.makeBuffer(length: capacity, options: .storageModeShared) else {
                throw FxRendererError.bufferUnavailable
            }
            next.label = buffer.label
            if preserve { memcpy(next.contents(), buffer.contents(), used) }
            buffer = next
            bound = false
        }

        mutating func bind(_ encoder: MTLRenderCommandEncoder, at index: Int, vertex: Bool) {
            if used > 0, used <= Self.inlineLimit {
                if vertex { encoder.setVertexBytes(buffer.contents(), length: used, index: index) }
                encoder.setFragmentBytes(buffer.contents(), length: used, index: index)
            } else {
                if vertex { encoder.setVertexBuffer(buffer, offset: 0, index: index) }
                encoder.setFragmentBuffer(buffer, offset: 0, index: index)
                if used > 0 { bound = true }
            }
        }
    }

    var instances: Storage
    var tables: Storage

    init(device: MTLDevice) throws {
        instances = try Storage(device: device, label: "fx insts", capacity: 64 * MemoryLayout<FxInstRaw>.stride)
        tables = try Storage(device: device, label: "fx tables", capacity: 4096 * MemoryLayout<SIMD4<Float>>.stride)
    }

    func upload(_ graph: FxRenderPassGraph) throws {
        try instances.upload(graph.instances)
        try tables.upload(graph.tableData)
    }
}
#endif
