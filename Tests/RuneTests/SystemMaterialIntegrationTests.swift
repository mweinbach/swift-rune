import Testing
import RuneMotion
@testable import Rune
#if os(macOS)
import AppKit
import QuartzCore
#endif

@Suite("System material rendering")
struct SystemMaterialIntegrationTests {
    @Test func glassCurvesAndFallbackMatchOnBothFramePaths() throws {
        let rt = Runtime<Void>(state: (), viewport: Vec2(160, 50), pixelScale: 2) { _, _ in
            el().size(160, 50)
                .child(el().absolute(x: 5, y: 5).size(40, 40).rounded(10).systemMaterial(.glass))
                .child(el().absolute(x: 55, y: 5).size(40, 40).rounded(10).systemMaterial(.popover))
                .child(el().absolute(x: 105, y: 5).size(40, 40).rounded(10).continuousCorners().systemMaterial(.popover))
        }
        let fallback = rt.renderFrame(at: 0)
        #expect(fallback.materials.map(\.continuous) == [true, false, true])
        #expect(fallback.materials.map(\.radius) == [20, 20, 20])
        let fills = fallback.instances.filter { $0.params.y == KIND_RECT && $0.rect.z == 80 }
        #expect(fills.map(\.radii.x) == [-20, 20, -20])
        #expect(fills.allSatisfy { abs($0.fill.w - 0.94) < 0.001 })
        let reference = rt.frame(at: 0).primitives.filter { $0.kind == .roundedRect && $0.rect.z == 80 }
        #expect(reference.map(\.radii.x) == [-20, 20, -20])
        #expect(reference.allSatisfy { abs($0.fill.w - 0.94) < 0.001 })
    }

    @Test func dimmedMaterialsDoNotConsumeTheNativeLimit() throws {
        let rt = Runtime<Void>(state: (), viewport: Vec2(160, 50), pixelScale: 1) { _, _ in
            var root: El<Void> = el().size(160, 50)
            for i in 0..<MAX_NATIVE_MATERIALS {
                root = root.child(el().absolute(x: Float(i * 15), y: 0).size(10, 10).systemMaterial(.glass).dim(0))
            }
            return root.child(el().absolute(x: 80, y: 0).size(10, 10).systemMaterial(.popover))
        }
        rt.nativeMaterials = true
        let frame = rt.renderFrame(at: 0)
        #expect(frame.materials.map(\.rect.left) == [80])
        #expect(frame.instances.allSatisfy { $0.params.y != KIND_RECT || $0.fill.w == 0 })
    }

    @Test func materialOpacityIncludesIsolatedAncestors() {
        let rt = Runtime<Void>(state: (), viewport: Vec2(100, 50)) { _, _ in
            el().size(100, 50).layerOpacity(0.5)
                .child(el().size(50, 30).opacity(0.5).systemMaterial(.glass))
        }
        rt.nativeMaterials = true
        #expect(rt.renderFrame(at: 0).materials.map(\.opacity) == [0.25])
    }

    @Test func referenceBackdropPrecedesItsOwnFadedLayer() throws {
        let rt = Runtime<Void>(state: (), viewport: Vec2(60, 40)) { _, _ in
            el().size(60, 40)
                .child(el().size(40, 30).opacity(0.5).backdropBlur(8).bg(.white)
                    .child(el().size(12, 8).bg(.black)))
        }
        let primitives = rt.frame(at: 0).primitives
        let blur = try #require(primitives.firstIndex { $0.kind == .backdropBlur })
        let layer = try #require(primitives.firstIndex { $0.kind == .layerBegin })
        #expect(blur < layer)
        #expect(primitives[blur].fill.w == 0.5)
    }

    @Test func finitePositiveBlursEmitThroughBothPaintPaths() {
        for bad in [Float.nan, .infinity, -.infinity, -1, 0] {
            let element: El<Void> = el().backdropBlur(4).backdropBlur(bad)
            #expect(element.backdropBlur == 0)
        }
        let rt = Runtime<Void>(state: (), viewport: Vec2(200, 40), pixelScale: 2) { _, _ in
            var root: El<Void> = el().size(200, 40)
            for i in 0..<(MAX_BACKDROP_BLURS + 1) {
                root = root.child(el().absolute(x: Float(i * 20), y: 0).size(15, 20).backdropBlur(0.01))
            }
            return root
        }
        let native = rt.renderFrame(at: 0).instances.filter { $0.params.y == KIND_BACKDROP_BLUR }
        #expect(native.count == MAX_BACKDROP_BLURS)
        #expect(native.allSatisfy { $0.params.x == 0.02 })
        let reference = rt.frame(at: 0).primitives.filter { $0.kind == .backdropBlur }
        #expect(reference.count == MAX_BACKDROP_BLURS)
        #expect(reference.allSatisfy { $0.params.x == 0.02 })
    }

    #if os(macOS)
    @Test @MainActor func prewarmedOverlayPresentsNativeGlassInItsPanel() throws {
        _ = NSApplication.shared
        let overlay = OverlayHandle(spec: OverlaySpec<Void>(
            name: "Glass integration test", size: Vec2(96, 64),
            options: OverlayOptions(input: .none, prewarm: true), makeState: { () },
            view: { _, _ in el().size(96, 64).rounded(12).systemMaterial(.glass) }
        ))
        overlay.show()
        defer { overlay.hide() }
        let number = try #require(overlay.windowNumber)
        let panel = try #require(NSApplication.shared.window(withWindowNumber: Int(number)))
        let host = try #require(panel.contentView?.subviews.compactMap { $0 as? RuneMaterialHost }.first)
        let effect = try #require(host.subviews.first { $0.alphaValue > 0 })
        #expect(effect.frame.size == NSSize(width: 96, height: 64))
        if let glass = NSClassFromString("NSGlassEffectView") { #expect(effect.isKind(of: glass)) }
        #expect(overlay.surfaceStats.frameCount > 0)
    }

    @Test @MainActor func windowHostsGlassBehindMetalAndRetainsItsViewAcrossSparseAssignments() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        defer { window.close() }
        let metalView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        metalView.wantsLayer = true
        let metal = CAMetalLayer()
        metalView.layer = metal
        RuneMaterialHost.install(metalView, in: window)
        var host: RuneMaterialHost?
        func draw(_ id: UInt64, _ x: Float, _ material: SystemMaterial) -> MaterialDraw {
            MaterialDraw(id: id, material: material, rect: MotionRect(left: x, top: 10, right: x + 80, bottom: 60),
                         radius: 18, continuous: material == .glass)
        }
        let popover = draw(1, 0, .popover)
        let glass = draw(2, 100, .glass)
        func present(_ draws: [MaterialDraw], mode: MaterialMode = .native) -> Bool {
            RuneMaterialHost.present(host: &host, draws: draws, in: metalView, layer: metal, scale: 2, mode: mode) { $0 }
        }
        #expect(present([popover, glass]))
        let mounted = try #require(host)
        let root = try #require(window.contentView)
        let hi = try #require(root.subviews.firstIndex(of: mounted))
        let mi = try #require(root.subviews.firstIndex(of: metalView))
        #expect(hi < mi)
        #expect(mounted.hitTest(NSPoint(x: 25, y: 15)) == nil)
        let glassView = try #require(mounted.subviews.first { $0.frame.origin.x == 50 })
        if let nativeClass = NSClassFromString("NSGlassEffectView") {
            #expect(glassView.isKind(of: nativeClass))
            #expect((glassView.value(forKey: "cornerRadius") as? NSNumber)?.doubleValue == 9)
        } else {
            #expect((glassView as? NSVisualEffectView)?.material == .popover)
        }
        #expect(glassView.frame == NSRect(x: 50, y: 5, width: 40, height: 25))
        #expect(present([glass]))
        #expect(present([draw(3, 0, .popover), glass]))
        #expect(mounted.subviews.first { $0.alphaValue > 0 && $0.frame.origin.x == 50 } === glassView)
        #expect(present([glass], mode: .legacy))
        let legacy = try #require(mounted.subviews.first { $0.alphaValue > 0 && $0.frame.origin.x == 50 } as? NSVisualEffectView)
        #expect(legacy.material == .popover)
        #expect(legacy.layer?.cornerCurve == .continuous)
        #expect(!present([]))
        #expect(mounted.subviews.allSatisfy { $0.alphaValue == 0 })
    }
    #endif
}
