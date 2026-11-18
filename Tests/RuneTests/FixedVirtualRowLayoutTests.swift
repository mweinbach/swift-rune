import Testing
@testable import Rune
import RuneMotion

@Suite("Fixed virtual row layout")
struct FixedVirtualRowLayoutTests {
    @Test("Fixed rows keep individual layout, text, selection and scroll extents across a changing window",
          arguments: [false, true])
    func restoresSurvivingRows(wholeRows: Bool) throws {
        func make(_ ordinarySolve: Bool) -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(240, 120), pixelScale: 1.25) { _, _ in
                let list: El<Int> = col().wFull().minW(240).borderLayout(ordinarySolve).key("rows")
                    .virtualRows(count: 600, estimatedRowHeight: 20, key: { _, i in "row-\(i)" }) { state, i in
                        let height = Float(18 + i % 4)
                        let label = i % 13 == 1 ? "A long line wrapping at a fixed width" : "text \(i) \(state)"
                        var content: El<Int> = col().wFull().h(height).key("content").child(
                            text(label).w(90).h(16).wrapText().selectable().key("label")
                        ).child(el().size(4, 1)).child(el().size(6, 1))
                        if i % 11 == 0 {
                            content = content.child(el().size(280, 2).absolute(x: 7, y: 1).key("overflow"))
                        }
                        var shell = col().wFull().role(.listItem).label("item \(i)").selectionGroup().child(content)
                        if i == 2 || i == 3 { shell = shell.h(height + 0.5) }
                        else if i == 4 { shell = shell.basis(height + 1).shrink(1).minH(height).maxH(height + 2) }
                        else if !i.isMultiple(of: 7) { shell = shell.h(height) }
                        if i % 19 == 3 { shell.layout.pinTop = 3 }
                        if i == 5 { shell = shell.mt(0.25).mb(0.75) }
                        if i == 25 { shell = shell.absolute(x: 0, y: 60).h(20.5) }
                        return shell
                    }
                return col().sizeFull().scrollXY().key("scroll").child(wholeRows ? list.wholeRows() : list)
            }
        }

        let reused = make(false)
        // With zero border thickness the border-box reservation has the same geometry.
        let ordinary = make(true)
        var usedFewerSlots = false
        var checkedAbsoluteRow = false
        for frame in 0...28 {
            let now = Double(frame) / 60
            func advance(_ runtime: Runtime<Int>) -> RenderFrame {
                if frame == 0 {
                    _ = runtime.renderFrame(at: now)
                    runtime.pointerDown(at: Vec2(2, 8), at: now)
                    runtime.pointerMove(to: Vec2(60, 8), at: now)
                }
                if frame == 2 { runtime.pointerUp(at: Vec2(60, 8), at: now) }
                if frame == 9 { runtime.setViewport(Vec2(230, 140), pixelScale: 1.5) }
                if frame == 12 { runtime.setViewport(Vec2(240, 120), pixelScale: 1.25) }
                if frame == 16 { runtime.update(at: now) { value, tx in value += 1; tx.instant() } }
                if frame > 0 {
                    let dy: Float = frame == 18 ? -2_000 : frame.isMultiple(of: 4) ? 40 : -65
                    runtime.wheel(WheelEvent(dx: frame.isMultiple(of: 5) ? -4 : 0, dy: dy), at: Vec2(100, 50), now: now)
                }
                return runtime.renderFrame(at: now)
            }
            let scene = advance(reused), control = advance(ordinary)
            #expect(reused.elements() == ordinary.elements())
            #expect(reused.accessibilitySnapshot() == ordinary.accessibilitySnapshot())
            #expect(reused.nodeTextLayouts.keys == ordinary.nodeTextLayouts.keys)
            #expect(reused.selectedText() == ordinary.selectedText())
            if frame == 0 {
                #expect(reused.selectedText()?.isEmpty == false)
                #expect(reused.flatNodes.first { $0.key == "row-2" }?.localRect.height == (wholeRows ? 21 : 20.5))
                let before = try #require(reused.flatNodes.first { $0.key == "row-4" }).localRect
                let row = try #require(reused.flatNodes.first { $0.key == "row-5" }).localRect
                let after = try #require(reused.flatNodes.first { $0.key == "row-6" }).localRect
                #expect(row.top - before.bottom == 0.25)
                #expect(after.top - row.bottom == 0.75)
            }
            if let row = reused.flatNodes.first(where: { $0.key == "row-25" }) {
                #expect(row.localSize.y == 20.5)
                checkedAbsoluteRow = true
            }
            #expect(reused.scrollOffset(forKey: "scroll") == ordinary.scrollOffset(forKey: "scroll"))
            try expectMatchingPaint(scene, control)
            if reused.retainedLayout.storageStats.liveNodes < ordinary.retainedLayout.storageStats.liveNodes {
                usedFewerSlots = true
            }
        }
        #expect(usedFewerSlots)
        #expect(checkedAbsoluteRow)
    }

    @Test("Automatic direction reads the mounted rows through a fixed-row remount", arguments: [false, true])
    func autoDirectionAfterScroll(explicitLTR: Bool) throws {
        func make(_ ordinary: Bool) -> Runtime<Void> {
            Runtime(state: (), viewport: Vec2(240, 120), pixelScale: 1) { _, _ in
                let list: El<Void> = col().key("rows").wFull().minW(240).borderLayout(ordinary)
                    .virtualRows(count: 500, estimatedRowHeight: 20, key: { _, i in "r\(i)" }) { _, i in
                        let label = i == 2 ? "…" : (i.isMultiple(of: 2) ? "abc" : "مرحبا")
                        return col().wFull().h(20).child(
                            row().wFull().h(20)
                                .child(el().key("mark\(i)").size(10, 10).bg(.white))
                                .child(text(label).size(70, 20))
                        )
                    }
                let frame = col().key("frame").wFull().child(list)
                return col().sizeFull().scrollY().dir(.auto).key("scroll")
                    .child(explicitLTR ? frame.dir(.ltr) : frame)
            }
        }
        let tested = make(false), ordinary = make(true)
        var compressed = false
        for step in 0...13 {
            let time = Double(step) / 60
            func draw(_ rt: Runtime<Void>) -> RenderFrame {
                if step > 0 { rt.wheel(WheelEvent(dy: -20), at: Vec2(80, 60), now: time) }
                return rt.renderFrame(at: time)
            }
            let actual = draw(tested), expected = draw(ordinary)
            #expect(tested.elements() == ordinary.elements())
            #expect(tested.accessibilitySnapshot() == ordinary.accessibilitySnapshot())
            if tested.retainedLayout.storageStats.liveNodes < ordinary.retainedLayout.storageStats.liveNodes {
                compressed = true
            }
            if step == 13 {
                let marker = try #require(tested.element(byKey: "mark13"))
                #expect(tested.scrollOffset(forKey: "scroll").y == 260)
                #expect(marker.visible[0] == (explicitLTR ? 0 : 230))
                try expectMatchingPaint(actual, expected)
            }
        }
        #expect(compressed == explicitLTR)
    }

    private struct SampledDraw: Equatable {
        var instance: RenderInstance
        var mask: [UInt8] = []
    }

    private func expectMatchingPaint(_ actual: RenderFrame, _ expected: RenderFrame) throws {
        // The two runtimes own independent atlases. A slot can move when a retained
        // row avoids an intermediate text measurement. Compare the draw and its pixels.
        func draws(_ scene: CpuBootScene) throws -> [SampledDraw] {
            try scene.instances.map { instance in
                var draw = SampledDraw(instance: instance)
                guard instance.params.y == KIND_GLYPH, instance.radii.w == 0 else { return draw }
                let page = try #require(Int(exactly: instance.params.z))
                try #require(scene.glyphPages.indices.contains(page))
                let size = scene.glyphSize(at: page)
                let pixels = scene.glyphPages[page]
                let x = try #require(Int(exactly: instance.uv.x))
                let y = try #require(Int(exactly: instance.uv.y))
                let scaled = instance.uv.z > 0
                let filtered = scaled || instance.params.x != 0
                let lcd = !filtered && instance.radii.x > 0.5
                let width = scaled ? instance.uv.z : instance.rect.z * (lcd ? 3 : 1)
                let height = scaled ? instance.uv.w : instance.rect.w
                // Filtered draws also read neighboring texels. Metal clamps those taps
                // at the page edges. Ordinary masks read one byte per covered pixel.
                let fringe = filtered ? 1 : 0
                for dy in -fringe..<(Int(height.rounded(.up)) + fringe) {
                    let row = max(0, min(size.y - 1, y + dy)) * size.x
                    for dx in -fringe..<(Int(width.rounded(.up)) + fringe) {
                        draw.mask.append(pixels[row + max(0, min(size.x - 1, x + dx))])
                    }
                }
                draw.instance.uv.x = 0
                draw.instance.uv.y = 0
                return draw
            }
        }

        #expect(actual.width == expected.width && actual.height == expected.height)
        let a = CpuBootScene(frame: actual), b = CpuBootScene(frame: expected)
        let actualDraws = try draws(a), expectedDraws = try draws(b)
        #expect(actualDraws.count == expectedDraws.count)
        let mismatch = zip(actualDraws, expectedDraws).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(mismatch == nil)
        var actualPixels = CpuBootTarget(width: actual.width, height: actual.height)
        var expectedPixels = CpuBootTarget(width: expected.width, height: expected.height)
        _ = try CpuBoot.paint(a, into: &actualPixels, threads: 1)
        _ = try CpuBoot.paint(b, into: &expectedPixels, threads: 1)
        #expect(actualPixels.pixels.elementsEqual(expectedPixels.pixels))
    }

    @Test("Fractional fixed rows can share a solver slot when the column rounds them to whole points",
          arguments: [false, true])
    func retainsFractionalFixedRows(wholeRows: Bool) {
        func make(_ ordinary: Bool) -> Runtime<Void> {
            Runtime(state: (), viewport: Vec2(240, 140), pixelScale: 1.25) { _, _ in
                let rows: El<Void> = col().wFull().minW(240).borderLayout(ordinary).key("rows")
                    .virtualRows(count: 500, estimatedRowHeight: 20.5, key: { _, i in "r\(i)" }) { _, i in
                        col().wFull().h(i.isMultiple(of: 2) ? 20.25 : 20.75)
                            .child(el().key("mark").size(40, 8).bg(.white))
                    }
                return col().sizeFull().scrollY().key("scroll").child(wholeRows ? rows.wholeRows() : rows)
            }
        }
        let reused = make(false), ordinary = make(true)
        var usedFewerSlots = false
        for frame in 0...12 {
            let now = Double(frame) / 60
            func advance(_ runtime: Runtime<Void>) -> RenderFrame {
                if frame > 0 { runtime.wheel(WheelEvent(dx: 0, dy: -60), at: Vec2(70, 45), now: now) }
                return runtime.renderFrame(at: now)
            }
            let actual = advance(reused), expected = advance(ordinary)
            #expect(actual.instances == expected.instances)
            #expect(reused.elements() == ordinary.elements())
            #expect(reused.scrollMaxExtents == ordinary.scrollMaxExtents)
            if reused.retainedLayout.storageStats.liveNodes < ordinary.retainedLayout.storageStats.liveNodes {
                usedFewerSlots = true
            }
        }
        #expect(usedFewerSlots == wholeRows)
    }

    @Test("An intrinsic flex ancestor keeps its real row and sibling contributions")
    func intrinsicFlexAncestor() {
        func make(_ ordinary: Bool) -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(240, 120), pixelScale: 1) { _, _ in
                col().sizeFull().scrollXY().key("scroll").child(
                    row().wFull().itemsStart().child(
                        col().wFull().minW(100).shrink(1).borderLayout(ordinary).key("rows")
                            .virtualRows(count: 300, estimatedRowHeight: 20, key: { _, i in "r-\(i)" }) { _, i in
                                col().wFull().h(20).child(text("row \(i)").w(i.isMultiple(of: 11) ? 330 : 90))
                            }
                    ).child(el().w(80).h(30).key("sibling"))
                )
            }
        }
        let tested = make(false), control = make(true)
        for i in 0...8 {
            let now = Double(i) / 60
            for runtime in [tested, control] {
                if i > 0 { runtime.wheel(WheelEvent(dx: -4, dy: -80), at: Vec2(70, 25), now: now) }
                _ = runtime.renderFrame(at: now)
            }
            #expect(tested.elements() == control.elements())
            #expect(tested.retainedLayout.storageStats.liveNodes == control.retainedLayout.storageStats.liveNodes)
        }
    }

    @Test("A fractional placeholder retries ordinary layout before releasing live and exiting text")
    func fractionalPositionRetriesTextCollection() throws {
        func make(_ ordinary: Bool) -> Runtime<Int> {
            Runtime(state: 0, viewport: Vec2(240, 120), pixelScale: 1.25) { _, _ in
                col().sizeFull().scrollXY().key("scroll").child(
                    col().wFull().minW(240).borderLayout(ordinary).key("rows")
                        .virtualRows(count: 900, estimatedRowHeight: 20, key: { _, i in "row-\(i)" }) { _, i in
                            col().wFull().h(i.isMultiple(of: 8) ? 20.5 : 20)
                                .child(text("label \(i)").w(80).h(16))
                                .child(el().size(6, 2))
                        }
                )
            }
        }
        let tested = make(false), control = make(true)
        for i in 0...12 {
            let t = Double(i) / 60
            for runtime in [tested, control] {
                if i != 0 {
                    runtime.wheel(WheelEvent(dx: 0, dy: -80), at: Vec2(80, 40), now: t)
                }
                _ = runtime.renderFrame(at: t)
            }
        }
        let old = tested.nodeTextLayouts
        #if DEBUG
        let previousRetries = tested.fixedVirtualLayoutRetries
        #endif
        func nextWindow(_ runtime: Runtime<Int>) throws -> Runtime<Int>.MeasurePassResult {
            let now = 13.0 / 60.0
            runtime.wheel(WheelEvent(dx: 0, dy: -80), at: Vec2(80, 40), now: now)
            return try #require(runtime.tryVirtualRemountPass(at: now, cut: false, commitKind: .instant,
                commitMotion: nil, commitColorSpring: nil, commitCut: false,
                prevMountedIds: runtime.nodeIndexById.keys))
        }
        // Inspect at the commit boundary. The following scene frame retires offscreen exits.
        let actual = try nextWindow(tested), expected = try nextWindow(control)
        #if DEBUG
        #expect(tested.fixedVirtualLayoutRetries > previousRetries)
        #endif
        #expect(actual.textLayouts.mapValues { $0.box.shapeKey } == expected.textLayouts.mapValues { $0.box.shapeKey })
        #expect(tested.exitingTextLayouts.mapValues { $0.box.shapeKey } == control.exitingTextLayouts.mapValues { $0.box.shapeKey })
        let departed = Set(old.keys).subtracting(actual.textLayouts.keys)
        #expect(!departed.isEmpty)
        for id in departed { #expect(tested.exitingTextLayouts[id]?.box.shapeKey == old[id]?.box.shapeKey) }
    }
}
