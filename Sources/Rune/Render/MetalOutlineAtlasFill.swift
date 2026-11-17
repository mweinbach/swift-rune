#if canImport(Metal) && canImport(QuartzCore)
import Foundation
@preconcurrency import Metal

/// Retains the mask placements already filled in one glyph texture. The immutable
/// plan lets another renderer, a recycled atlas or an abandoned command recover.
internal final class MetalOutlineAtlasFill {
    private final class Page {
        weak var texture: MTLTexture?
        var sourceID: UUID?
        var baseGeneration: UInt64 = 0
        var epoch: UInt64 = 0
        var resident = 0
        var encoded: FillCommand?
    }
    /// Keep the completion outcome, without retaining all the resources of an old frame.
    private final class FillCommand: @unchecked Sendable {
        private weak var command: MTLCommandBuffer?
        private let lock = NSLock()
        private var succeeded = false

        init(_ command: MTLCommandBuffer) {
            self.command = command
            command.addCompletedHandler { [weak self] buffer in
                guard let self else { return }
                lock.withLock { succeeded = buffer.status == .completed }
            }
        }

        func precedes(_ next: MTLCommandBuffer) -> Bool {
            guard let command else { return lock.withLock { succeeded } }
            switch command.status {
            case .completed: return true
            case .committed, .scheduled: return command.commandQueue === next.commandQueue
            case .error: return false
            default: return command === next
            }
        }
    }
    private var pages: [Int: Page] = [:]
    private(set) var maskCount: UInt64 = 0
    private(set) var passes: UInt64 = 0

    func encode(_ plan: OutlineMaskPlan, page index: Int = 0, into target: MTLTexture, curves: MTLTexture, standIn: MTLTexture,
                pipeline: MTLRenderPipelineState, command: MTLCommandBuffer,
                baseChange: (from: UInt64, to: UInt64, region: MTLRegion)? = nil) throws {
        let page = pages[index] ?? Page()
        let ordered = page.encoded?.precedes(command) == true
        let resident = ordered && page.texture === target && page.sourceID == plan.curves.storeID && page.epoch == plan.epoch
        let prefix = min(page.resident, plan.fills.count)
        let jobs: [RenderInstance]
        if resident, page.baseGeneration == plan.baseGeneration {
            guard prefix < plan.fills.count else { return }
            jobs = plan.fills[prefix...].map(\.instance)
        } else if resident, let baseChange, baseChange.from == page.baseGeneration, baseChange.to == plan.baseGeneration {
            // A CPU bitmap can update a rectangle on the same shelf as GPU-filled text.
            // Repair only placements whose pixels or gutters that upload replaced.
            let changed = baseChange.region
            let bounds = SIMD4(changed.origin.x, changed.origin.y, changed.origin.x + changed.size.width,
                               changed.origin.y + changed.size.height)
            let repaired = plan.fills.prefix(prefix).filter { $0.overlaps(bounds, in: plan.base) }
            jobs = repaired.map(\.instance) + plan.fills[prefix...].map(\.instance)
            if jobs.isEmpty {
                page.baseGeneration = plan.baseGeneration
                page.resident = prefix
                return
            }
        } else {
            jobs = plan.fills.map(\.instance)
        }
        guard !jobs.isEmpty else { return }
        let bytes = jobs.count * MemoryLayout<RenderInstance>.stride
        let buffer: MTLBuffer?
        if bytes <= 4096 {
            buffer = nil
        } else {
            guard let upload = jobs.withUnsafeBytes({ data in
                command.device.makeBuffer(bytes: data.baseAddress!, length: bytes, options: .storageModeShared)
            }) else { throw MetalRenderer.RendererError.metalUnavailable }
            buffer = upload
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw MetalRenderer.RendererError.metalUnavailable }
        encoder.label = "Rune Windfoil glyph atlas fill"
        encoder.setRenderPipelineState(pipeline)
        var globals = RenderGlobals(viewport: SIMD2(Float(target.width), Float(target.height)))
        if let buffer {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        } else {
            jobs.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: bytes, index: 0) }
        }
        encoder.setVertexBytes(&globals, length: MemoryLayout<RenderGlobals>.stride, index: 1)
        encoder.setFragmentBytes(&globals, length: MemoryLayout<RenderGlobals>.stride, index: 1)
        encoder.setFragmentTexture(standIn, index: 0)
        encoder.setFragmentTexture(standIn, index: 1)
        encoder.setFragmentTexture(curves, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: jobs.count)
        encoder.endEncoding()
        page.texture = target
        page.sourceID = plan.curves.storeID
        page.baseGeneration = plan.baseGeneration
        page.epoch = plan.epoch
        page.resident = plan.fills.count
        page.encoded = FillCommand(command)
        pages[index] = page
        maskCount &+= UInt64(jobs.count)
        passes &+= 1
    }

    func forget() {
        pages.removeAll(keepingCapacity: true)
    }
}
#endif
