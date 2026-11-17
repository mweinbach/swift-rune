import Foundation
import Testing
@testable import Rune

@Suite("Middle-button autoscroll, Linux PRIMARY and semantic selection copying")
struct MiddleSelectionParityTests {
    @Test func middleScrollUsesFrameTimeAndStopsRequestingFramesAtTheEdge() throws {
        let rt = Runtime<Void>(state: (), viewport: Vec2(200, 120), pixelScale: 1) { _, _ in
            col().key("view").size(200, 120).scroll(stickBottom: false)
                .child(col().wFull().h(500).shrink(0))
        }
        _ = rt.frame(at: 0)
        let origin = Vec2(60, 20)
        #if os(Windows) || os(Linux)
        rt.pointerDown(at: origin, button: .middle, at: 0.1)
        #else
        rt.pointerDown(at: origin, button: .middle, at: 0.1)
        #expect(rt.slice2State.autoscroll.active == nil)
        rt.startMiddleAutoscroll(at: origin, now: 0.1)
        #endif
        let path = try #require(rt.slice2State.autoscroll.active?.vertical)
        guard case .image(let center) = rt.currentCursor() else { Issue.record("Missing pan cursor"); return }
        #expect(center.hot == SIMD2(16, 16) && center.crisp)
        rt.pointerMove(to: Vec2(60, 35), at: 0.2)
        #expect(!rt.slice2State.autoscroll.wantsFrame)
        rt.pointerUp(at: Vec2(60, 35), button: .middle, at: 0.21)
        rt.pointerMove(to: Vec2(60, 100), at: 0.3)
        #expect(rt.slice2State.autoscroll.wantsFrame)
        _ = rt.frame(at: 0.3)
        #expect(rt.scrollOffsets[path, default: .zero].y == 0)
        _ = rt.frame(at: 0.32)
        let expected = Float(0.04 * pow(80.0, 2.2) * 0.02)
        #expect(abs(rt.scrollOffsets[path, default: .zero].y - expected) < 0.02)
        #expect(rt.currentCursor() != .image(center))
        _ = rt.runFrameSplit(catchUp: 0, dt: 0.4, hostDelta: 0.4)
        #expect(abs(rt.scrollOffsets[path, default: .zero].y - expected * 21) < 0.05)
        for i in 1...18 { _ = rt.frame(at: 2 + Double(i) * 0.05) }
        #expect(rt.scrollOffsets[path]?.y == rt.scrollMaxExtents[path]?.y)
        #expect(!rt.slice2State.autoscroll.wantsFrame)
        rt.pointerMove(to: Vec2(60, 0), at: 3)
        #expect(rt.slice2State.autoscroll.wantsFrame)
        #expect(rt.keyDown(KeyEvent(key: .escape), at: 3.1))
        #expect(rt.slice2State.autoscroll.active == nil)
    }

    @Test func latchedScrollKeepsSubpixelProgressAndItsOverdueFrame() throws {
        let runtime = Runtime<Void>(state: (), viewport: Vec2(200, 120), pixelScale: 1) { _, _ in
            col().key("view").size(200, 120).scroll(stickBottom: false)
                .child(col().wFull().h(1_500_000).shrink(0))
        }
        _ = runtime.frame(at: 0)
        runtime.update { _, tx in tx.scrollToInstant("view", x: 0, y: 1_000_000) }
        _ = runtime.frame(at: 0.1)
        let start = runtime.scrollOffset(forKey: "view").y
        #expect(start == 1_000_000)
        let origin = Vec2(60, 20)
        #if os(Windows) || os(Linux)
        runtime.pointerDown(at: origin, button: .middle, at: 0.2)
        #else
        runtime.startMiddleAutoscroll(at: origin, now: 0.2)
        #endif
        runtime.pointerUp(at: origin, button: .middle, at: 0.21)
        runtime.pointerMove(to: Vec2(60, 36), at: 0.22)
        runtime.fireMiddleAutoscroll(at: 0.220001)
        #expect(runtime.scrollOffset(forKey: "view").y == start)
        #expect(runtime.slice2State.autoscroll.wantsFrame)
        #expect(runtime.nextWakeDeadline(after: 0.221) == 0.221)
        for tick in 1...8 {
            runtime.fireMiddleAutoscroll(at: 0.220001 + Double(tick) / 1_000)
        }
        #expect(runtime.scrollOffset(forKey: "view").y == 1_000_000.125)
    }

    @Test func middleScrollReleaseSwallowsOnlyItsDismissalAndWheelKeepsPointer() {
        var scroller = MiddleAutoscroll()
        scroller.start(horizontal: "inner", vertical: "outer", origin: Vec2(0, 0), now: 1)
        scroller.move(to: Vec2(-80, 80), at: 1.1)
        #expect((scroller.active?.velocity.x ?? 0) < 0)
        #expect((scroller.active?.velocity.y ?? 0) > 0)
        let step = scroller.step(at: 4)
        #expect(abs((step?.1.y ?? 0) - (0.04 * pow(80.0, 2.2) * 0.05)) < 0.01)
        let tookMiddle = scroller.release(.middle)
        #expect(tookMiddle)
        #expect(scroller.active == nil)
        scroller.start(horizontal: "x", vertical: nil, origin: .zero, now: 2)
        let tookMiddleAgain = scroller.release(.middle)
        #expect(tookMiddleAgain)
        let tookSecondaryPress = scroller.press(.secondary)
        #expect(tookSecondaryPress)
        let skippedPrimary = !scroller.release(.primary)
        #expect(skippedPrimary)
        let tookSecondaryRelease = scroller.release(.secondary)
        #expect(tookSecondaryRelease)
        let skippedExtraRelease = !scroller.release(.secondary)
        #expect(skippedExtraRelease)
        let rt = Runtime<Void>(state: (), viewport: Vec2(200, 120), pixelScale: 1) { _, _ in
            col().wFull().hFull().child(text("row").key("hover"))
        }
        _ = rt.frame(at: 0)
        let previous = rt.pointerPosition
        rt.wheelXY(10, 10, 0, -40, now: 0.1)
        _ = rt.frame(at: 0.2)
        #expect(rt.pointerPosition == previous)
    }

    @Test func copyPublishesAuthoredUTF8StrikeRangesAndSkipsHiddenListMarkers() throws {
        let selectionColor = Color.rgba8(163, 85, 223)
        let rt = Runtime<Void>(state: (), viewport: Vec2(320, 160), pixelScale: 1) { _, _ in
            col().child(
                col().role(.list).cache().child(
                    row().role(.listItem).child(text("1.").a11yHidden()).child(
                        text("ﬀ🙂 foo").key("entry").w(210).selectable().textCase(.uppercase).strike(3..<7).selectionColor(selectionColor)
                    )
                )
            )
        }
        _ = rt.frame(at: 0)
        rt.dispatchFocus(true, at: 0.05)
        #if os(macOS) || os(Windows) || os(Linux)
        let gpu = try OffscreenGPURenderer()
        _ = try gpu.renderOffscreen(gpu.frame(rt, at: 0.06))
        #endif
        let r = try #require(rt.element(byKey: "entry")?.rect)
        rt.pointerDown(at: Vec2(r[0] + 0.1, r[1] + 4), at: 0.1)
        rt.pointerMove(to: Vec2(r[0] + r[2] - 0.1, r[1] + 4), at: 0.15)
        rt.pointerUp(at: Vec2(r[0] + r[2] - 0.1, r[1] + 4), at: 0.17)
        #expect(rt.keyDown(KeyEvent(key: .command("c"), mods: RuneTestKey.primaryMods()), at: 0.2))
        #expect(rt.clipboard.text == "ﬀ🙂 foo")
        #expect(rt.clipboard.html == "<ol><li>ﬀ<s>🙂</s> foo</li></ol>")
        let reference = rt.frame(at: 0.21)
        let shade = selectionColor.scaleAlpha(rt.windowFocused ? 1 : 0.55).simd4(srgb: reference.srgbBlend)
        let selectedRects = reference.primitives.filter { $0.kind == .roundedRect && $0.fill == shade }.map(\.rect)
        #expect(!selectedRects.isEmpty)
        #if os(macOS) || os(Windows) || os(Linux)
        let native = try gpu.frame(rt, at: 0.22)
        #else
        let native = rt.renderFrame(at: 0.22)
        #endif
        let premultiplied = SIMD4(shade.x * shade.w, shade.y * shade.w, shade.z * shade.w, shade.w)
        #expect(native.instances.filter { $0.params.y == KIND_RECT && $0.fill == premultiplied }.map(\.rect) == selectedRects)
        #expect(native.marks.count == native.instances.count)
        #if os(macOS) || os(Windows) || os(Linux)
        let expectedPixels = try gpu.renderOffscreen(reference).rgba
        let actualPixels = try gpu.renderOffscreen(native).rgba
        var interiors = 0
        var disagreements = 0
        for i in stride(from: 0, to: expectedPixels.count, by: 4) {
            guard abs(Int(expectedPixels[i]) - 163) <= 2, abs(Int(expectedPixels[i + 1]) - 85) <= 2,
                  abs(Int(expectedPixels[i + 2]) - 223) <= 2 else { continue }
            interiors += 1
            if (0..<4).contains(where: { abs(Int(expectedPixels[i + $0]) - Int(actualPixels[i + $0])) > 2 }) {
                disagreements += 1
            }
        }
        #expect(interiors > 50)
        #expect(disagreements == 0)
        #endif
    }

    @Test func partialDisplayedLigatureCopiesTheAuthoredScalarAndMarksTheDrawnSlice() throws {
        let runtime = Runtime<Void>(state: (), viewport: Vec2(210, 50), pixelScale: 1) { _, _ in
            text("ﬀ🙂").key("entry").w(210).selectable().textCase(.uppercase).strike(0..<3)
        }
        _ = runtime.frame(at: 0)
        for range in [0..<1, 1..<2] {
            runtime.update { _, tx in tx.selectText("entry", range: range) }
            _ = runtime.frame(at: Double(range.upperBound) * 0.04)
            let snapshot = try #require(runtime.currentTextSelection()?.texts.first)
            #expect(snapshot.range == range)
            #expect(snapshot.len == "FF🙂".utf8.count)
            #expect(snapshot.mark().text == "F")
            #expect(snapshot.text == "ﬀ")
            #expect(runtime.keyDown(KeyEvent(key: .command("c"), mods: RuneTestKey.primaryMods()), at: Double(range.upperBound) * 0.05))
            #expect(runtime.clipboard.text == "ﬀ")
            #expect(runtime.clipboard.html == "<p><s>ﬀ</s></p>")
        }
    }

    @Test func aCopyExclusionInsideAScalarKeepsTheOtherSelectedTextIntact() {
        let runtime = Runtime<Void>(state: (), viewport: Vec2(210, 80), pixelScale: 1) { _, _ in
            col().key("all").selectionGroup(true).child(text("a🙂b").selectable().uncopied(2..<4))
                .child(text("kept").selectable())
        }
        _ = runtime.frame(at: 0)
        runtime.update { _, tx in tx.selectAllText("all") }
        _ = runtime.frame(at: 0.02)
        #expect(runtime.keyDown(KeyEvent(key: .command("c"), mods: RuneTestKey.primaryMods()), at: 0.03))
        #expect(runtime.clipboard.text == "kept")
        #expect(runtime.clipboard.html == "<p>kept</p>")
    }

    @Test func retainedNativeMarkRequiresTheOriginalDrawnUTF8Bytes() throws {
        struct State {
            var label = "a\u{301}\u{323}"
            var marks: [SelectionMark] = []
        }
        let color = Color.rgba8(163, 85, 223)
        let runtime = Runtime(state: State(), viewport: Vec2(210, 50), pixelScale: 1) { state, cx in
            cx.markTexts(state.marks)
            return col().cache().child(text(state.label).key("entry").w(200).selectable().selectionColor(color))
        }
        _ = runtime.frame(at: 0)
        runtime.dispatchFocus(true, at: 0.01)
        let node = try #require(runtime.element(byKey: "entry"))
        runtime.update { state, _ in
            state.marks = [SelectionMark(path: node.path, range: 0..<state.label.utf8.count, text: state.label)]
        }
        let native = runtime.renderFrame(at: 0.02)
        let shade = color.simd4(srgb: native.srgbBlend)
        #expect(native.instances.contains { $0.params.y == KIND_RECT && $0.fill == shade && $0.radii == .zero })
        runtime.update { state, _ in state.label = "a\u{323}\u{301}" }
        let replaced = runtime.renderFrame(at: 0.03)
        #expect(!replaced.instances.contains { $0.params.y == KIND_RECT && $0.fill == shade })
    }

    @Test func unmountedRowsCopyAuthoredBytesAndOmitTheMappedExclusion() throws {
        let runtime = Runtime<Void>(state: (), viewport: Vec2(210, 60), pixelScale: 1) { _, _ in
            col().wFull().hFull().scroll(stickBottom: false).child(
                col().key("rows").wFull().growth(.default).selectionGroup(true).virtualRows(
                    55, 30, key: { _, row in "row-\(row)" },
                    build: { _, row in
                        col().wFull().h(30).child(text("ﬀ!🙂\(row)").key("body").wFull()
                            .selectable().uncopied(3..<4).textCase(.uppercase))
                    }
                )
            )
        }
        _ = runtime.frame(at: 0)
        let initial = runtime.elements()
        #expect(!initial.contains { $0.path.contains("/@row-30/") })
        runtime.update { _, tx in tx.selectAllText("rows") }
        _ = runtime.frame(at: 0.02)
        let expected = (0..<55).map { "ﬀ🙂\($0)" }.joined(separator: "\n")
        #expect(runtime.selectedText() == expected)
        let selection = try #require(runtime.currentTextSelection())
        #expect(selection.texts.count == 55)
        let middle = try #require(selection.texts.dropFirst(30).first)
        #expect(middle.mark().text == "FF!🙂30")
        #expect(runtime.keyDown(KeyEvent(key: .command("c"), mods: RuneTestKey.primaryMods()), at: 0.03))
        #expect(runtime.clipboard.text == expected)
        #expect(runtime.clipboard.html == nil)
    }

    @Test func primarySelectionKeepsExactBytesAndIgnoresRevealedSecretsAndLateReplies() throws {
        struct State {
            var edit = TextEdit("é")
            var secure = false
        }
        let runtime = Runtime(state: State(), viewport: Vec2(220, 90), pixelScale: 1) { s, _ in
            col().child(textInput(key: "editor", \State.edit).secure(s.secure).revealed(true).w(180).h(30))
        }
        _ = runtime.frame(at: 0)
        let r = try #require(runtime.element(byKey: "editor")?.rect)
        let point = Vec2(r[0] + 0.1, r[1] + 5)
        runtime.pointerMove(to: point, at: 0.1)
        #if os(Linux)
        runtime.pointerDown(at: point, button: .middle, at: 0.12)
        #else
        #expect(runtime.primaryPasteDown(at: point, now: 0.12))
        #endif
        let target = try #require(runtime.clipboardRouting.primary.paste)
        runtime.queuePrimaryPaste(target: target, text: "Ω")
        _ = runtime.frame(at: 0.15)
        #expect(runtime.state.edit.text == "Ωé")
        #expect(runtime.clipboard.text.isEmpty)
        runtime.update(at: 0.2) { state, _ in state.edit = TextEdit("é"); state.edit.selectAll() }
        #if os(Linux)
        runtime.pointerUp(at: point, at: 0.21)
        #else
        runtime.clipboardRouting.primary.pending = true
        #endif
        _ = runtime.frame(at: 0.22)
        #expect(runtime.clipboardRouting.primary.write?.utf8.elementsEqual("é".utf8) == true)
        runtime.clipboardRouting.primary.write = nil
        runtime.clipboardRouting.primary.pending = true
        _ = runtime.frame(at: 0.23)
        #expect(runtime.clipboardRouting.primary.write == nil)
        runtime.update(at: 0.3) { state, _ in state.edit = TextEdit("e\u{301}"); state.edit.selectAll() }
        runtime.clipboardRouting.primary.pending = true
        _ = runtime.frame(at: 0.31)
        #expect(runtime.clipboardRouting.primary.write?.utf8.elementsEqual("e\u{301}".utf8) == true)
        runtime.clipboardRouting.primary.write = nil
        runtime.update(at: 0.4) { state, _ in state.secure = true; state.edit = TextEdit("secret"); state.edit.selectAll() }
        runtime.clipboardRouting.primary.pending = true
        _ = runtime.frame(at: 0.41)
        #expect(runtime.clipboardRouting.primary.write == nil)
        #expect(!runtime.primaryPasteDown(at: point, now: 0.42))
        runtime.queuePrimaryPaste(target: target, text: "late")
        _ = runtime.frame(at: 0.43)
        #expect(runtime.state.edit.text == "secret")
    }
}
