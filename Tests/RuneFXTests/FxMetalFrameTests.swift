#if canImport(Metal)
import Foundation
import Metal
import Testing
@testable import RuneFX

@Suite("Metal effect frame preparation")
struct FxMetalFrameTests {
    @Test func retainedGraphsStayImmutableAndSteadyFramesReuseStorage() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fx = try FxRenderer(device: device)
        let size = SIMD2<UInt32>(64, 64)
        let gradients = Array(repeating: Fx.fill(FillParams(.meshGradient(.dusk())))
            .on(.rounded(x: 0, y: 0, w: 24, h: 24, radius: 4)), count: 32)
        let full = FxFrame(viewport: size, layers: gradients)

        // Return integer addresses only; otherwise the benchmark would retain a snapshot
        // and correctly force copy-on-write in the next prepare.
        func addresses() -> [UInt] {
            let g = fx.prepare(frame: full)
            return [
                g.instances.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) },
                g.prepared.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) },
                g.tableData.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) },
            ]
        }
        let first = addresses()
        #expect(first.allSatisfy { $0 != 0 })
        #expect(addresses() == first)
        let saved = fx.prepare(frame: full)
        let empty = fx.prepare(frame: FxFrame(viewport: size, layers: []))
        #expect(empty.instances.isEmpty && empty.tableData.isEmpty && empty.prepared.isEmpty)
        #expect(saved.instances.count == 32 && saved.prepared.count == 32 && !saved.tableData.isEmpty)
        #expect(saved == FxRenderPassGraph.build(viewport: size, scale: 1, layers: gradients))
    }

    @Test func adjacentBatchesMatchIndependentMetalDrawsAcrossPipelineAndPlaceChanges() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let fx = try FxRenderer(device: device, pixelFormat: .rgba8Unorm_srgb)
        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 64, height: 64, mipmapped: false)
        target.usage = .renderTarget
        target.storageMode = .shared
        var layers: [FxLayer] = []
        for i in 0..<80 {
            let effect = i == 40 ? Fx.fill(FillParams(.meshGradient(.dusk()))) :
                Fx.glow(GlowParams(color: rgb(i.isMultiple(of: 2) ? 0xff4422 : 0x2255ff)))
            let layer = effect.on(.rounded(x: Float(i % 11) * 2, y: Float(i % 9) * 3,
                                           w: 18, h: 20, radius: 4)).opacity(0.42)
            layers.append(i == 18 ? layer.under() : layer.over())
        }
        var slots = Array(repeating: FxSlot(), count: layers.count)
        slots[25] = FxSlot().blend(.screen)
        let frame = FxFrame(viewport: SIMD2(64, 64), layers: layers)
        let graph = fx.prepare(frame: frame, slots: slots)
        #expect(fx.builtPipelines == 3) // Visible variants already compiled before drawing.
        let handle = fx.layerResourceHandle(0)
        #expect(handle != nil && handle == fx.layerResourceHandle(25))

        func render(batch: Bool, place: Place?, explicitGraph: Bool = false) throws -> [UInt8] {
            let texture = try #require(device.makeTexture(descriptor: target))
            let command = try #require(queue.makeCommandBuffer())
            let desc = MTLRenderPassDescriptor()
            desc.colorAttachments[0].texture = texture
            desc.colorAttachments[0].loadAction = .clear
            desc.colorAttachments[0].storeAction = .store
            let encoder = try #require(command.makeRenderCommandEncoder(descriptor: desc))
            if explicitGraph {
                try fx.encode(graph: graph, viewport: frame.viewport, encoder: encoder, place: place)
            } else if batch {
                try fx.drawAll(encoder: encoder, layers: layers, place: place)
            } else {
                for (index, layer) in layers.enumerated() where place == nil || layer.place == place {
                    try fx.drawLayer(encoder: encoder, layer: index)
                }
            }
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            #expect(command.status == .completed)
            var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
            texture.getBytes(&bytes, bytesPerRow: 256, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
            return bytes
        }
        for place: Place? in [nil, .over] {
            let reference = try render(batch: false, place: place)
            #expect(reference.contains { $0 != 0 })
            let batch = try render(batch: true, place: place)
            #expect(batch == reference)
            #expect(fx.lastDrawStats.draws == (place == nil ? 5 : 6))
            #expect(fx.lastDrawStats.pipelineBinds == 5)
            #expect(fx.lastDrawStats.resourceBinds == 1)
            let explicit = try render(batch: true, place: place, explicitGraph: true)
            #expect(explicit == reference)
            #expect(fx.lastDrawStats.resourceBinds == 1)
        }
    }

    @Test func multiplePreparedAndExplicitGraphsCanShareAnUnsubmittedCommandBuffer() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        let fx = try FxRenderer(device: device, pixelFormat: .rgba8Unorm)
        let target = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 32, height: 8, mipmapped: false)
        target.usage = .renderTarget
        target.storageMode = .shared
        let size = SIMD2<UInt32>(32, 8)
        let command = try #require(queue.makeCommandBuffer())
        let left = Fx.fill(FillParams(.meshGradient(.dusk()))).on(.rounded(x: 0, y: 0, w: 8, h: 8, radius: 0))
        let right = Fx.fill(FillParams(.meshGradient(.dusk()))).on(.rounded(x: 24, y: 0, w: 8, h: 8, radius: 0))

        func encode(_ body: (MTLRenderCommandEncoder) throws -> Void) throws -> MTLTexture {
            let texture = try #require(device.makeTexture(descriptor: target))
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            descriptor.colorAttachments[0].storeAction = .store
            let encoder = try #require(command.makeRenderCommandEncoder(descriptor: descriptor))
            try body(encoder)
            encoder.endEncoding()
            return texture
        }

        var checks: [(MTLTexture, MTLTexture, MTLTexture)] = []
        // The larger case exceeds Metal's inline-constant limit.
        for count in [1, 60] {
            let a = Array(repeating: left, count: count), b = Array(repeating: right, count: count)
            fx.prepare(frame: FxFrame(viewport: size, layers: a))
            let first = try encode { try fx.drawAll(encoder: $0, layers: a) }
            let graph = fx.prepare(viewport: size, scale: 1, layers: b)
            let second = try encode { try fx.encode(graph: graph, viewport: size, encoder: $0) }
            let again = try encode { try fx.drawLayer(encoder: $0, layer: 0) }
            // A second prepare replaces the current frame before the first one executes.
            fx.prepare(frame: FxFrame(viewport: size, layers: b))
            _ = try encode { try fx.drawAll(encoder: $0, layers: b) }
            checks.append((first, second, again))
        }
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        func alpha(_ texture: MTLTexture, x: Int) -> UInt8 {
            var pixel = SIMD4<UInt8>.zero
            texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(x, 4, 1, 1), mipmapLevel: 0)
            return pixel.w
        }
        for (first, second, again) in checks {
            #expect(alpha(first, x: 4) == 255 && alpha(first, x: 28) == 0)
            #expect(alpha(second, x: 4) == 0 && alpha(second, x: 28) == 255)
            #expect(alpha(again, x: 4) == 255 && alpha(again, x: 28) == 0)
        }
    }

    @Test func suppliedComputePassSamplesFireSimulation() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        guard device.supportsCounterSampling(.atStageBoundary),
              let stamps = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) else { return }
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = stamps
        descriptor.storageMode = .shared
        descriptor.sampleCount = 2
        let buffer = try device.makeCounterSampleBuffer(descriptor: descriptor)
        let pass = MTLComputePassDescriptor()
        pass.sampleBufferAttachments[0]?.sampleBuffer = buffer
        pass.sampleBufferAttachments[0]?.startOfEncoderSampleIndex = 0
        pass.sampleBufferAttachments[0]?.endOfEncoderSampleIndex = 1
        let fx = try FxRenderer(device: device, pixelFormat: .rgba16Float)
        fx.setFireSim(true)
        let layer = Fx.fire(FireParams()).on(.rounded(x: 8, y: 60, w: 48, h: 24, radius: 6)).at(0.05)
        fx.prepare(frame: FxFrame(viewport: SIMD2(64, 96), layers: [layer]))
        let queue = try #require(device.makeCommandQueue())
        let command = try #require(queue.makeCommandBuffer())
        #expect(try fx.simulate(commandBuffer: command, pass: pass))
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        let data = try #require(try buffer.resolveCounterRange(0..<2))
        let ticks = data.withUnsafeBytes { $0.bindMemory(to: MTLCounterResultTimestamp.self).map(\.timestamp) }
        #expect(ticks.count == 2 && ticks[0] != 0 && ticks[1] > ticks[0] && ticks[1] != UInt64.max)
    }
}
#endif
