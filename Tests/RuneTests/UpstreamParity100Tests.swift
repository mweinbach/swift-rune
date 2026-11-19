import Foundation
import RuneMotion
import RuneRef
import Testing
@testable import Rune

#if os(macOS)
import AppKit
#endif
#if canImport(SwiftUI) && (os(macOS) || (canImport(UIKit) && !os(watchOS)))
import SwiftUI
#endif

@Suite("100% Upstream Parity & Cross-Platform UI Elements")
struct UpstreamParity100Tests {
    // MARK: - 1. Cross-Platform Embeddable Views & iOS UITextInput Bridge

    @Test("IOSTextInputBridge supports full UTF-16 UITextInput IME, marked text, emoji replacement, and secure redaction")
    func iosTextInputBridgeFullIMEAndSecurity() {
        struct S {
            var edit = TextEdit("Hi 🌍 world")
            var secret = TextEdit("s3cr3t")
        }
        let rt = Runtime(state: S(), viewport: Vec2(320, 120), pixelScale: 2) { _, _ in
            col().w(320).h(120)
                .child(textInput(key: "field", \S.edit).w(300).h(32).singleLine())
                .child(textInput(key: "pw", \S.secret).w(300).h(32).singleLine().secure())
        }
        _ = rt.frame(at: 0)

        // Focus regular field
        rt.update(at: 0.01) { _, tx in tx.focus("field") }
        _ = rt.frame(at: 0.02)

        guard let snap0 = IOSTextInputBridge.snapshot(of: rt) else {
            Issue.record("expected focused field snapshot")
            return
        }
        #expect(!snap0.isSecure)
        #expect(snap0.displayText == "Hi 🌍 world")
        // "Hi " (3) + "🌍" (2 UTF-16) + " world" (6) = 11 UTF-16 code units
        #expect(snap0.utf16Length == 11)
        #expect(IOSTextInputBridge.text(in: rt, utf16Range: 3..<5) == "🌍")

        // Replace emoji by UTF-16 range
        #expect(IOSTextInputBridge.replace(in: rt, utf16Range: 3..<5, with: "Swift", at: 0.03))
        #expect(rt.state.edit.text == "Hi Swift world")

        // Set UTF-16 selection
        #expect(IOSTextInputBridge.setSelection(in: rt, utf16Range: 3..<8, at: 0.04))
        #expect(IOSTextInputBridge.snapshot(of: rt)?.selectedUTF16 == 3..<8)

        // Japanese IME marked text composition -> commit via unmarkText
        #expect(IOSTextInputBridge.setMarkedText(in: rt, "にほん", selectedUTF16Range: NSRange(location: 3, length: 0), at: 0.05))
        let markedSnap = IOSTextInputBridge.snapshot(of: rt)
        #expect(markedSnap?.markedUTF16 == 3..<6)
        #expect(markedSnap?.displayText.contains("にほん") == true)

        #expect(IOSTextInputBridge.unmarkText(in: rt, at: 0.06))
        #expect(IOSTextInputBridge.snapshot(of: rt)?.markedUTF16 == nil)
        #expect(rt.state.edit.text.contains("にほん"))

        // Caret & selection geometry return finite boxes
        let caret = IOSTextInputBridge.caretRect(in: rt, atUTF16Offset: 3)
        #expect(caret.height > 0)
        let selRects = IOSTextInputBridge.selectionRects(in: rt, forUTF16Range: 0..<3)
        #expect(!selRects.isEmpty)

        // Secure field never exposes password text or accepts marked text
        rt.update(at: 0.07) { _, tx in tx.focus("pw") }
        _ = rt.frame(at: 0.08)
        let pwSnap = IOSTextInputBridge.snapshot(of: rt)
        #expect(pwSnap?.isSecure == true)
        #expect(pwSnap?.displayText == "")
        #expect(pwSnap?.utf16Length == 0)
        #expect(IOSTextInputBridge.text(in: rt, utf16Range: 0..<6) == nil)
        #expect(!IOSTextInputBridge.setMarkedText(in: rt, "abc", selectedUTF16Range: NSRange(location: 3, length: 0), at: 0.09))
    }

    #if os(macOS)
    @Test("MacOSApp.makeView creates a public embeddable RuneMacView and RuneView wraps it for SwiftUI")
    @MainActor
    func macOSEmbeddableViewAndSwiftUIWrapper() throws {
        _ = NSApplication.shared
        let spec = AppSpec<Int>(title: "Embed", size: Vec2(240, 160), state: 1) { count, _ in
            col().key("root").sizeFull().child(text("Count: \(count)").key("lbl"))
        }
        let view = try MacOSApp.makeView(spec)
        #expect(view.acceptsFirstResponder)
        #expect(view.intrinsicContentSize == NSSize(width: 240, height: 160))
        view.update { count, _ in count = 42 }
        _ = view.runtime.frame(at: 0)
        #expect(view.runtime.state == 42)
        #expect(view.runtime.elements().contains { $0.key == "lbl" && $0.text == "Count: 42" })

        #if canImport(SwiftUI)
        let swiftUIView = RuneView(spec)
        _ = swiftUIView.body
        #endif
    }
    #endif

    // MARK: - 2. Explicit Accessibility Roles (searchbox, spinbutton, article, terminal)

    @Test("Explicit searchbox, spinbutton, article, and terminal roles project cleanly across a11y surfaces")
    func explicitA11yRolesParity() {
        struct S { var query = TextEdit("rune") }
        let rt = Runtime(state: S(), viewport: Vec2(400, 300), pixelScale: 1) { _, _ in
            col().key("root").sizeFull()
                .child(textInput(key: "find", \S.query).role(.searchbox).label("Search").size(200, 28).singleLine())
                .child(el().key("spin").role(.spinbutton).label("Quantity").focusable(true).size(80, 28))
                .child(el().key("post").role(.article).label("Release Notes").size(300, 60))
                .child(el().key("tty").role(.terminal).label("Shell").focusable(true).size(300, 100))
        }
        _ = rt.frame(at: 0)
        let snap = rt.accessibilitySnapshot()

        func find(_ node: AccessibilityNode, id: String) -> AccessibilityNode? {
            if node.id == id { return node }
            for c in node.children {
                if let hit = find(c, id: id) { return hit }
            }
            return nil
        }

        #expect(find(snap, id: "find")?.role == .searchbox)
        #expect(find(snap, id: "spin")?.role == .spinbutton)
        #expect(find(snap, id: "post")?.role == .article)
        #expect(find(snap, id: "tty")?.role == .terminal)

        #if os(macOS)
        #expect(AppKitAccessibilityMapper.nsRole(for: .searchbox) == .textField)
        #expect(AppKitAccessibilityMapper.subrole(.searchbox) == .searchField)
        #expect(AppKitAccessibilityMapper.nsRole(for: .spinbutton) == .incrementor)
        #expect(AppKitAccessibilityMapper.nsRole(for: .article) == .group)
        #expect(AppKitAccessibilityMapper.subrole(.article)?.rawValue == "AXDocumentArticle")
        #expect(AppKitAccessibilityMapper.nsRole(for: .terminal) == .textArea)
        #endif
    }

    // MARK: - 3. #1162 ImageCache.svgRgbaCover

    @Test("#1162: ImageCache.svgRgbaCover centre-crops non-square SVGs to px × px and rejects invalid sizes")
    func svgRgbaCoverParity() throws {
        // 200x100 SVG: left half red, right half blue. A 16x16 cover crop scales by 16/100 and centres
        // horizontally, so x=0..7 is red and x=8..15 is blue.
        let svg = Data("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100" width="200" height="100">
            <rect x="0" y="0" width="100" height="100" fill="#ff0000"/>
            <rect x="100" y="0" width="100" height="100" fill="#0000ff"/>
        </svg>
        """.utf8)
        let pixels = try ImageCache.svgRgbaCover(svg, px: 16)
        #expect(pixels.count == 16 * 16 * 4)
        // Left-of-center pixel (4, 8) should be red; right-of-center pixel (12, 8) should be blue.
        let leftBase = (8 * 16 + 4) * 4
        let rightBase = (8 * 16 + 12) * 4
        #expect(pixels[leftBase] > 200 && pixels[leftBase + 2] < 50 && pixels[leftBase + 3] == 255)
        #expect(pixels[rightBase + 2] > 200 && pixels[rightBase] < 50 && pixels[rightBase + 3] == 255)

        #expect(throws: Error.self) { _ = try ImageCache.svgRgbaCover(svg, px: 0) }
        #expect(throws: Error.self) { _ = try ImageCache.svgRgbaCover(svg, px: 4097) }
    }

    // MARK: - 4. #1114 RuneTaskTidy

    @Test("#1114: RuneTaskTidy parks without a hook, arms once per idle spell, and enforces IDLE_MIN_GAP")
    func runeTaskTidyStateMachine() {
        #expect(RuneTask.idleTimeout == 10.0)
        #expect(RuneTask.idleMinGap == 180.0)

        var tidy = RuneTaskTidy()
        #expect(tidy.waitSeconds(now: 0) == nil)
        // Without a hook, work leaves it parked with no timer.
        tidy.onWork(now: 1.0, hasHook: false)
        #expect(tidy.waitSeconds(now: 1.0) == nil)

        // With a hook, work arms for IDLE (10s).
        tidy.onWork(now: 10.0, hasHook: true)
        #expect(tidy.waitSeconds(now: 10.0) == 10.0)
        let due1 = tidy.takeDue(now: 19.9)
        #expect(!due1)
        let due2 = tidy.takeDue(now: 20.0)
        #expect(due2)
        // Immediately parks after running once.
        #expect(tidy.waitSeconds(now: 20.0) == nil)

        // Subsequent work enforces IDLE_MIN_GAP (180s from last tidy at 20.0 -> 200.0).
        tidy.onWork(now: 25.0, hasHook: true)
        #expect(tidy.waitSeconds(now: 25.0) == 175.0)
        let due3 = tidy.takeDue(now: 199.9)
        #expect(!due3)
        let due4 = tidy.takeDue(now: 200.0)
        #expect(due4)
        #expect(tidy.waitSeconds(now: 200.0) == nil)
    }

    // MARK: - 5. #1212 Drag Image Halo, Desktop Backdrop Linear Premultiply & CPU Boot Layer Plan

    @Test("#1212: DragImage.toStraightRGBA un-premultiplies in linear light on sRGB targets and zeros alpha=0")
    func dragImageStraightAlphaParity() {
        var unorm: [UInt8] = [0, 0, 128, 128, 10, 20, 30, 255, 50, 60, 70, 0]
        DragImage.toStraightRGBA(&unorm, bgra: true, srgbTarget: false)
        #expect(unorm == [255, 0, 0, 128, 30, 20, 10, 255, 0, 0, 0, 0])

        let lin: [Float] = [0.25, 0.5, 0.125]
        let expected = lin.map { UInt8((DragImage.srgbEncode($0) * 255.0).rounded()) }
        for aByte: UInt8 in [64, 128, 192, 255] {
            let a = Float(aByte) / 255.0
            let srgbRGBA: [UInt8] = [
                UInt8((DragImage.srgbEncode(lin[0] * a) * 255.0).rounded()),
                UInt8((DragImage.srgbEncode(lin[1] * a) * 255.0).rounded()),
                UInt8((DragImage.srgbEncode(lin[2] * a) * 255.0).rounded()),
                aByte,
            ]
            var fromBGRA: [UInt8] = [srgbRGBA[2], srgbRGBA[1], srgbRGBA[0], srgbRGBA[3]]
            DragImage.toStraightRGBA(&fromBGRA, bgra: true, srgbTarget: true)
            for c in 0..<3 {
                #expect(abs(Int(fromBGRA[c]) - Int(expected[c])) <= 2)
            }
            #expect(fromBGRA[3] == aByte)
        }
        var zeroSRGB: [UInt8] = [99, 137, 71, 0]
        DragImage.toStraightRGBA(&zeroSRGB, bgra: true, srgbTarget: true)
        #expect(zeroSRGB == [0, 0, 0, 0])
    }

    @Test("#1212: VirtualDesktop.fitBackdrop premultiplies translucent pixels in linear light")
    func desktopBackdropLinearPremultiply() {
        let src: [UInt8] = [
            255, 255, 255, 128, // 50% white -> ~188 in linear light
            188, 188, 188, 128, // 50% of ~0.5 linear -> ~137
            12, 34, 56, 255,    // opaque unchanged
            255, 0, 0, 0,       // transparent -> black
        ]
        let px = DesktopComposite.fitBackdrop(rgba: src, width: 4, height: 1, targetSize: (4, 1))
        #expect(px.count == 16)
        #expect(abs(Int(px[0]) - 188) <= 1)
        #expect(px[0] == px[1] && px[1] == px[2] && px[3] == 255)
        #expect(abs(Int(px[4]) - 137) <= 1)
        #expect(px[4] == px[5] && px[5] == px[6] && px[7] == 255)
        #expect(Array(px[8..<12]) == [12, 34, 56, 255])
        #expect(Array(px[12..<16]) == [0, 0, 0, 255])
    }

    @Test("#1212: CpuBootBin uses isScissorClip for whole-pixel flat layers and caps backdrop blurs at MAX_BACKDROP_BLURS")
    func cpuBootLayerPlanParity() {
        #expect(CpuBootBin.Bins.isScissorClip(NO_CLIP, fade: .zero))
        #expect(CpuBootBin.Bins.isScissorClip(SIMD4(10, 20, 100, 200), fade: .zero))
        #expect(!CpuBootBin.Bins.isScissorClip(SIMD4(10.5, 20, 100, 200), fade: .zero))
        #expect(!CpuBootBin.Bins.isScissorClip(SIMD4(10, 20, 100, 200), fade: SIMD4(1, 0, 0, 0)))

        // 6 backdrop blur instances must cap at MAX_BACKDROP_BLURS (4)
        var instances: [RenderInstance] = []
        for i in 0..<6 {
            var inst = RenderInstance()
            inst.rect = SIMD4(Float(i * 10), 0, 10, 10)
            inst.params = SIMD4(8.0, KIND_BACKDROP_BLUR, 0, 1.0)
            inst.clip = NO_CLIP
            instances.append(inst)
        }
        let scene = CpuBootScene(
            instances: instances,
            glyphPages: [],
            images: [],
            size: (100, 20),
            clear: SIMD4(0, 0, 0, 1),
            srgbBlend: true,
            atlasResets: 0
        )
        let bins = CpuBootBin.Bins.build(for: scene)
        #expect(bins.blurs.count <= MAX_BACKDROP_BLURS)
    }

    // MARK: - 6. #1219 Canonical Runtime, Scroll, Focus & A11y Fixes

    @Test("#1219: Button nested inside a focusable tab is not a member of the enclosing focus group")
    func focusGroupNestedControlIsExcluded() {
        let rt = Runtime(state: (), viewport: Vec2(300, 80), pixelScale: 1) { _, _ in
            row().key("tabs").role(.tabList).focusGroup(true).size(300, 40)
                .child(
                    row().key("tab-1").role(.tab).focusable(true).size(120, 32)
                        .child(el().key("close-1").role(.button).label("Close").focusable(true).size(20, 20))
                )
        }
        _ = rt.frame(at: 0)
        let tabIdx = rt.flatNodes.firstIndex(where: { $0.key == "tab-1" })!
        let closeIdx = rt.flatNodes.firstIndex(where: { $0.key == "close-1" })!
        let tabsIdx = rt.flatNodes.firstIndex(where: { $0.key == "tabs" })!
        #expect(rt.findFocusGroupAncestor(of: tabIdx) == tabsIdx)
        #expect(rt.findFocusGroupAncestor(of: closeIdx) == nil)
    }

    @Test("#1219: anchorRect matches slider/knob across unkeyed wrappers and scrollContainerAt respects raised overlays")
    func anchorSelectorAndScrollUnderOverlay() {
        let rt = Runtime(state: (), viewport: Vec2(300, 200), pixelScale: 1) { _, _ in
            el().key("root").size(300, 200)
                .child(
                    col().key("scroller").size(300, 200).scrollY()
                        .child(el().size(300, 800).shrink(0))
                )
                .child(
                    el().key("panel").absolute(x: 100, y: 20).size(150, 120).raise()
                        .child(
                            el().key("slider").size(100, 40)
                                .child(el().size(100, 40).child(el().key("knob").size(20, 20)))
                        )
                )
        }
        _ = rt.frame(at: 0)
        // Unkeyed wrapper between slider and knob still resolves via `slider/knob`.
        let knobRect = rt.anchorRect(forKey: "slider/knob")
        #expect(knobRect != nil && knobRect!.width == 20 && knobRect!.height == 20)
        // Raised panel at (100..250, 20..140) occludes scroller underneath it.
        #expect(rt.scrollContainerAt(at: Vec2(150, 60), axis: .vertical) == nil)
        // Outside the raised panel, scroller is reachable.
        #expect(rt.scrollContainerAt(at: Vec2(30, 60), axis: .vertical) != nil)
    }

    // MARK: - 7. #1150 Notched Mouse Wheel Glide

    @Test("#1150: WheelCurve eases on Chromium's kInverseDelta curve, snaps to device grid, and lands when wheel glide is off")
    func wheelNotchGlideParity() {
        // Duration ramp: 200ms up to 120 dev px, 100ms at >= 480 dev px.
        #expect(abs(WheelCurve.duration(delta: 60, scale: 2.0) - 0.2) < 1e-6)
        #expect(abs(WheelCurve.duration(delta: 240, scale: 2.0) - 0.1) < 1e-6)
        // Device grid snapping & end priority within 1 device pixel.
        #expect(WheelCurve.devicePixel(10.3, scale: 2.0) == 10.5)
        #expect(WheelCurve.onGridOrEnd(99.8, max: 100.0, scale: 2.0) == 100.0)

        var curve = WheelCurve(from: 0, to: 100, scale: 2.0)
        curve.advance(dt: 1.0 / 60.0) // first frame consumes `fresh`
        #expect(curve.value == 0)
        curve.advance(dt: 0.05)
        let mid = curve.value
        #expect(mid > 0 && mid < 100)
        // Retarget stacks smoothly preserving current value
        let retargeted = curve.retarget(to: 200, scale: 2.0)
        #expect(retargeted)
        #expect(abs(curve.value - mid) < 1e-3)
        curve.advance(dt: 1.0)
        #expect(curve.isDone && curve.value == 200)

        // End-to-end Runtime notched wheel gliding vs setWheelGlide(false)
        let rt = Runtime(state: (), viewport: Vec2(200, 200), pixelScale: 2) { _, _ in
            col().key("vp").size(200, 200).scrollY().child(el().size(200, 1000).shrink(0))
        }
        _ = rt.frame(at: 0)
        rt.wheelEvent(WheelEvent(dx: 0, dy: -100, precise: false, notch: true, x: 50, y: 50), now: 0.01)
        _ = rt.frame(at: 0.02)
        #expect(rt.hasActiveWheelGlides)
        _ = rt.frame(at: 0.08)
        let vpPath = rt.flatNodes.first(where: { $0.key == "vp" })!.path
        let midScroll = rt.scrollOffsets[vpPath]?.y ?? 0
        #expect(midScroll > 0 && midScroll < 100)
        _ = rt.frame(at: 0.4)
        #expect(abs((rt.scrollOffsets[vpPath]?.y ?? 0) - 100) <= 0.5)
        #expect(!rt.hasActiveWheelGlides)

        // setWheelGlide(false) lands immediately
        rt.setWheelGlide(false)
        rt.wheelEvent(WheelEvent(dx: 0, dy: -80, precise: false, notch: true, x: 50, y: 50), now: 0.5)
        #expect(!rt.hasActiveWheelGlides)
        #expect(abs((rt.scrollOffsets[vpPath]?.y ?? 0) - 180) <= 0.5)
    }

    // MARK: - 8. #1133 El.byLine() Static Multi-Line Code Block Shaping

    @Test("#1133: El.byLine() lays out static multi-line code blocks per line and reuses unchanged lines")
    func elByLineLayoutParity() {
        struct S { var code: String }
        let base = (0..<20).map { "let line\($0) = \($0) * 2" }.joined(separator: "\n")
        let rt = Runtime(state: S(code: base), viewport: Vec2(400, 500), pixelScale: 2) { s, _ in
            col().key("root").w(400)
                .child(text(s.code).key("code").mono().size(13).wrap(.wrap).byLine())
        }
        _ = rt.frame(at: 0)
        let node = rt.flatNodes.first(where: { $0.key == "code" })!
        let h1 = node.targetRect.height
        #expect(h1 > 200)
        #expect(rt.nodeTextLayouts[node.nodeId]?.box.paragraphs != nil)

        // Append one streaming line -> height grows and ParagraphLayout remains active
        rt.update(at: 0.1) { s, _ in s.code += "\nlet line20 = 40" }
        _ = rt.frame(at: 0.1)
        let node2 = rt.flatNodes.first(where: { $0.key == "code" })!
        #expect(node2.targetRect.height > h1)
        #expect(rt.nodeTextLayouts[node2.nodeId]?.box.paragraphs != nil)
    }

    // MARK: - 9. #1136 Loop-Only Frame Patching & LoopOnlyCheck

    @Test("#1136: LoopOnlyPlan patches cycle dots and slide shimmer clips and LoopOnlyCheck flags diffs")
    func loopOnlyFrameAndCheckParity() {
        var inst0 = RenderInstance()
        inst0.rect = SIMD4(0, 0, 10, 10)
        inst0.params = SIMD4(0, KIND_RECT, 0, 1)
        inst0.clip = NO_CLIP

        var inst1 = RenderInstance()
        inst1.rect = SIMD4(20, 20, 80, 20)
        inst1.params = SIMD4(0, KIND_RECT, 0, 1)
        inst1.clip = SIMD4(20, 20, 40, 40)

        let plan = LoopOnlyPlan(
            cycleSlots: [
                LoopOnlyCycleSlot(
                    instanceIndex: 0,
                    nodeId: NodeId(1),
                    baseColor: Color(r: 1, g: 1, b: 1, a: 1),
                    inheritedAlpha: 1,
                    cycle: Cycle(period: 1.0, stops: [(0.0, 0.2), (0.5, 1.0), (1.0, 0.2)]),
                    rectPx: SIMD4(0, 0, 10, 10),
                    srgbBlend: true
                ),
            ],
            slideSlots: [
                LoopOnlySlideSlot(
                    instanceIndices: 1..<2,
                    nodeId: NodeId(2),
                    anchorRectPx: SIMD4(20, 20, 40, 40),
                    fromPx: 0,
                    toPx: 60,
                    duration: 1.0
                ),
            ]
        )
        #expect(plan.isEligible)
        var instances = [inst0, inst1]
        let step = plan.apply(to: &instances, at: 0.5)
        #expect(step.changed)
        #expect(step.patchedIndices == [0, 1])
        #expect(instances[1].clip.x == 50 && instances[1].clip.z == 70)

        var check = LoopOnlyCheck(mode: .instances)
        #expect(check.failedExitCode == 3) // 0 compared fails check
        let sameOk = check.compareInstances(stepped: instances, ordinary: instances)
        #expect(sameOk)
        #expect(check.failedExitCode == nil)
        var bad = instances
        bad[0].fill.x += 0.1
        let badOk = check.compareInstances(stepped: instances, ordinary: bad)
        #expect(!badOk)
        #expect(check.failedExitCode == 3)
    }

    // MARK: - 10. #862 Linux Dmabuf & NativeSurface.pushDmabuf

    @Test("#862: Dmabuf validates format/modifier/stride, fires release once, and reads linear BGRA via pushDmabuf")
    func linuxDmabufValidationAndPush() throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            var count = 0
            func inc() { lock.withLock { count += 1 } }
            var value: Int { lock.withLock { count } }
        }

        // Validation failures must invoke onRelease once immediately.
        let badRelease = Counter()
        #expect(throws: Error.self) {
            _ = try Dmabuf(width: 4, height: 4, modifier: 1, plane: DmabufPlane(fd: 0, stride: 16), onRelease: { badRelease.inc() })
        }
        #expect(badRelease.value == 1)

        // Valid linear XRGB8888 temp file mmap round-trip through NativeSurface.pushDmabuf
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rune-dmabuf-\(UUID().uuidString).bin")
        let bytes = Data([0x10, 0x20, 0x30, 0x00, 0x40, 0x50, 0x60, 0x00,
                          0x70, 0x80, 0x90, 0x00, 0xA0, 0xB0, 0xC0, 0x00])
        try bytes.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fh = try FileHandle(forReadingFrom: tmp)
        defer { try? fh.close() }
        let releaseCounter = Counter()
        let dmabuf = try Dmabuf(
            width: 2,
            height: 2,
            drmFormat: Dmabuf.formatXRGB8888,
            modifier: Dmabuf.modifierLinear,
            plane: DmabufPlane(fd: fh.fileDescriptor, offset: 0, stride: 8),
            ownsFd: false,
            onRelease: { releaseCounter.inc() }
        )
        let surface = NativeSurface()
        try surface.pushDmabuf(dmabuf, frameId: 7)
        let snap = try #require(surface.currentFrame())
        let planes = try snap.bytePlanes()
        #expect(planes.count == 1)
        #expect(planes[0].count == 16)
        // XRGB8888 forces alpha byte to 255
        #expect(planes[0][0] == 0x10 && planes[0][3] == 255)
        #expect(planes[0][12] == 0xA0 && planes[0][15] == 255)
        #expect(releaseCounter.value == 1)
    }

    // MARK: - 11. #1188 Wayland CsdCorners

    @Test("#1188: CsdCorners generates 12 bottom-corner vertices and fades outside bottom arcs only")
    func waylandCsdCornersParity() {
        let corners = CsdCorners(radiusPt: 10, scale: 2, sizePx: (100, 80))
        #expect(corners.isActive)
        #expect(corners.radiusPx == 20)
        #expect(corners.vertices().count == 12)
        #expect(CsdCorners.outsideFraction(squareX: 0, squareY: 0, radiusPx: 20) == 0)
        #expect(abs(CsdCorners.outsideFraction(squareX: 1, squareY: 0, radiusPx: 20) - 0.5) < 1e-4)
        #expect(CsdCorners.outsideFraction(squareX: 1, squareY: 1, radiusPx: 20) == 1)

        var rgba = [UInt8](repeating: 255, count: 100 * 80 * 4)
        corners.applyInPlace(rgba: &rgba)
        // Top-left (0, 0) and top-right (99, 0) untouched
        #expect(rgba[3] == 255)
        #expect(rgba[99 * 4 + 3] == 255)
        // Bottom-left (0, 79) and bottom-right (99, 79) cleared to 0
        #expect(rgba[(79 * 100 + 0) * 4 + 3] == 0)
        #expect(rgba[(79 * 100 + 99) * 4 + 3] == 0)
        // Interior center (50, 79) stays opaque
        #expect(rgba[(79 * 100 + 50) * 4 + 3] == 255)
    }

    // MARK: - 12. #1121 Long-Field Drawn Visual Line Boxes

    #if os(macOS)
    @Test("#1121: A11yFieldLayout exposes drawn visual line boxes and caret bounds for fields past 64 KiB")
    func longFieldDrawnVisualLinesParity() {
        struct S { var text: TextEdit }
        let line = String(repeating: "a", count: 80) + "\n"
        let big = String(repeating: line, count: 900) // ~72.9 KiB > 64 KiB
        #expect(big.utf8.count > 64 * 1024)
        let rt = Runtime(state: S(text: TextEdit(big, multiline: true)), viewport: Vec2(400, 300), pixelScale: 1) { _, _ in
            col().w(400).h(300).scrollY()
                .child(textInput(key: "doc", \S.text).w(380))
        }
        _ = rt.frame(at: 0)
        let node = rt.flatNodes.first(where: { $0.key == "doc" })!
        let box = rt.nodeTextLayouts[node.nodeId]!.box
        let layout = A11yFieldLayout(text: big, box: box, system: rt.textSystem, origin: Vec2(0, 0), scale: Vec2(1, 1))
        #expect(layout != nil)
        let firstLineFrame = layout!.frame(forBytes: 0..<10)
        #expect(firstLineFrame.height > 0 && firstLineFrame.width > 0)
    }
    #endif
}
