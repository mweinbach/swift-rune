import RuneMotion
import Testing
@testable import Rune

@Suite("Preparing text for an idle window")
struct PrepareTextTests {
    private struct Window {
        var opened = false
        var layoutCallbacks = 0
    }

    private static let article = "An unmounted view can break this paragraph across several lines before it opens."

    private static func articleView(_ state: Window, _ cx: inout Cx<Window>) -> El<Window> {
        col().wFull().child(
            text(article).wrap(.wrap).wFull().key("article")
                .onScreenLayoutTx { state, _, _ in state.layoutCallbacks += 1 }
        )
    }

    @Test func idleMeasurementLeavesMountedSceneAndAtlasAlone() throws {
        let rt = Runtime(state: Window(), viewport: Vec2(160, 120)) { state, cx in
            if state.opened { return Self.articleView(state, &cx) }
            return el().key("current").size(90, 24)
        }
        let firstFrame = rt.frame(at: 0)
        let elements = rt.elements()
        let accessibility = rt.accessibilitySnapshot()
        let commits = rt.viewCommitCount
        let glyphs = rt.textSystem.glyphAtlas.rasterized
        let hits = rt.hitTestElement(at: Vec2(10, 10))

        rt.updateIf(at: 0.01) { _, tx in
            tx.prepareText(Self.articleView)
            return false
        }
        #expect(rt.textIdleOwed)
        #expect(!rt.textSystem.layoutKeys().contains { $0.authText == Self.article })
        #expect(!rt.textIdleTurn())
        #expect(!rt.textIdleOwed)
        #expect(rt.elements() == elements)
        #expect(rt.accessibilitySnapshot() == accessibility)
        #expect(rt.hitTestElement(at: Vec2(10, 10)) == hits)
        #expect(rt.state.layoutCallbacks == 0)
        #expect(rt.viewCommitCount == commits)
        #expect(rt.textSystem.glyphAtlas.rasterized == glyphs)
        #expect(rt.frame(at: 0.02).primitives == firstFrame.primitives)

        let prepared = try #require(rt.textSystem.layoutKeys().first { $0.authText == Self.article })
        let lines = try #require(rt.textSystem.cachedLayoutBox(for: prepared)?.shaped.lineCount)
        #expect(lines > 1)
        let shaped = rt.textSystem.shapedCount
        rt.update(at: 0.03) { state, _ in state.opened = true }
        _ = rt.frame(at: 0.03)
        #expect(rt.element(byKey: "article")?.text == Self.article)
        #expect(rt.textSystem.shapedCount == shaped)
        #expect(rt.textSystem.cachedLayoutBox(for: prepared)?.shaped.lineCount == lines)
    }

    @Test func latestRequestReplacesEarlierStateTypesAndOnlyMatchingWindowsConsumeIt() {
        struct Reader {}
        let reader = Runtime(state: Reader(), viewport: Vec2(120, 80)) { _, _ in el() }
        let editor = Runtime(state: Window(), viewport: Vec2(230, 110)) { _, _ in el() }
        _ = reader.frame(at: 0)
        _ = editor.frame(at: 0)
        var tx = Tx()
        tx.prepareText { (_: Reader, _: inout Cx<Reader>) in text("discarded") }
        #expect(reader.textIdleOwed)
        tx.prepareText { (_: Window, cx: inout Cx<Window>) in
            text("editor at \(Int(cx.viewport.x))")
        }
        #expect(!reader.textIdleOwed)
        #expect(!reader.textIdleTurn())
        #expect(editor.textIdleOwed)
        #expect(!editor.textIdleTurn())
        #expect(!editor.textIdleTurn())
        #expect(editor.textSystem.layoutKeys().contains { $0.authText == "editor at 230" })
        #expect(!reader.textSystem.layoutKeys().contains { $0.authText == "discarded" })
    }

    @Test func sameStateWindowsOnlyPrepareRequestsFromTheirOwnTransactions() {
        let owner = Runtime(state: "first window", viewport: Vec2(120, 80)) { _, _ in el() }
        let peer = Runtime(state: "second window", viewport: Vec2(200, 110)) { _, _ in el() }
        _ = owner.frame(at: 0)
        _ = peer.frame(at: 0)
        owner.updateIf(at: 0.01) { _, tx in
            tx.prepareText { (name: String, _: inout Cx<String>) in text(name) }
            return false
        }
        #expect(owner.textIdleOwed)
        #expect(!peer.textIdleOwed)
        #expect(!peer.textIdleTurn())
        #expect(owner.textIdleOwed)
        #expect(!owner.textIdleTurn())
        #expect(owner.textSystem.layoutKeys().contains { $0.authText == "first window" })
        #expect(peer.textSystem.layoutKeys().isEmpty)
    }

    @Test func closingAWindowReleasesAnUnconsumedViewCapture() {
        final class Preview { let title = "retained only by the pending view" }
        weak var released: Preview?
        let peer = Runtime(state: Window(), viewport: Vec2(160, 120)) { _, _ in el() }
        var owner: Runtime<Window>? = Runtime(state: Window(), viewport: Vec2(160, 120)) { _, _ in el() }
        do {
            let preview = Preview()
            released = preview
            owner?.updateIf(at: 0) { _, tx in
                tx.prepareText { (_: Window, _: inout Cx<Window>) in text(preview.title) }
                return false
            }
        }
        #expect(released != nil)
        #expect(owner?.textIdleOwed == true)
        #expect(!peer.textIdleTurn())
        owner = nil
        #expect(released == nil)
        #expect(!peer.textIdleOwed)
    }

    @Test func transactionCanPrepareAViewForAnotherWindowStateType() {
        struct Launcher {}
        struct Document { let title: String }
        let launcher = Runtime(state: Launcher(), viewport: Vec2(100, 60)) { _, _ in el() }
        let document = Runtime(state: Document(title: "selected document"), viewport: Vec2(300, 180)) { _, _ in el() }
        _ = launcher.frame(at: 0)
        _ = document.frame(at: 0)
        launcher.updateIf(at: 0.01) { _, tx in
            tx.prepareText { (doc: Document, cx: inout Cx<Document>) in
                text("\(doc.title) at \(Int(cx.viewport.x))")
            }
            return false
        }
        #expect(!launcher.textIdleOwed)
        #expect(!launcher.textIdleTurn())
        #expect(document.textIdleOwed)
        #expect(!document.textIdleTurn())
        #expect(document.textSystem.layoutKeys().contains { $0.authText == "selected document at 300" })
        #expect(launcher.textSystem.layoutKeys().isEmpty)
    }

    @Test func explicitSizeChangesWrappingAndPreservesTheWindowViewport() throws {
        let rt = Runtime(state: Window(), viewport: Vec2(320, 120)) { _, _ in el() }
        _ = rt.frame(at: 0)
        let added = rt.prepareText(Self.articleView, size: Vec2(75, 120))
        #expect(added > 0)
        let key = try #require(rt.textSystem.layoutKeys().first { $0.authText == Self.article })
        let narrow = try #require(rt.textSystem.cachedLayoutBox(for: key)?.shaped.lineCount)
        #expect(rt.viewport == Vec2(320, 120))
        var tx = Tx()
        tx.prepareText(Self.articleView)
        #expect(!rt.textIdleTurn())
        let candidates = rt.textSystem.layoutKeys().filter { $0.authText == Self.article }
            .compactMap { rt.textSystem.cachedLayoutBox(for: $0)?.shaped.lineCount }
        let wide = try #require(candidates.min())
        #expect(wide < narrow)
    }

    @Test func queuedSizeUsesTheMountedWindowsLayoutAndEnvironment() throws {
        let rt = Runtime(state: "draft", viewport: Vec2(320, 160), pixelScale: 2,
                         systemDark: false, reducedMotion: true) { _, _ in
            col().child(el().key("anchor").size(91, 24))
        }
        _ = rt.frame(at: 0)
        let anchor = try #require(rt.element(byKey: "anchor"))
        var tx = Tx()
        tx.prepareText({ (state: String, cx: inout Cx<String>) in
            let width = Int(cx.layoutRect(of: "anchor")?.width ?? -1)
            return text("\(state) \(Int(cx.viewport.x)) \(Int(cx.viewport.y)) \(width) \(Int(cx.pixelScale)) \(cx.systemDark) \(cx.reducedMotion)")
        }, size: Vec2(75, 90))
        #expect(!rt.textIdleTurn())
        let expected = "draft 75 90 \(Int(anchor.rect[2])) 2 false true"
        #expect(rt.textSystem.layoutKeys().contains { $0.authText == expected })
        #expect(rt.viewport == Vec2(320, 160))
    }

    @Test func restDropsUnusedPreparationAndKeepsMountedText() {
        let rt = Runtime(state: Window(), viewport: Vec2(160, 120)) { _, _ in
            text("already mounted").key("original")
        }
        _ = rt.frame(at: 0)
        let mounted = rt.textSystem.layoutKeys()
        #expect(mounted.contains { $0.authText == "already mounted" })
        #expect(rt.prepareText(Self.articleView, size: rt.viewport) > 0)
        #expect(rt.prepareText(Self.articleView, size: rt.viewport) == 0)
        rt.rest(at: 0.1)
        let kept = rt.textSystem.layoutKeys()
        #expect(mounted.isSubset(of: kept))
        #expect(!kept.contains { $0.authText == Self.article })
    }

    @Test func preparingARevealedSecureFieldLeavesNoLayoutOrGlyphs() {
        struct Form {
            var edit = TextEdit("private preview field")
        }
        var form = Form()
        form.edit.isSecure = true
        form.edit.isRevealed = true
        let rt = Runtime(state: form, viewport: Vec2(160, 120)) { _, _ in el() }
        _ = rt.frame(at: 0)
        let keys = rt.textSystem.layoutKeys()
        let glyphs = rt.textSystem.glyphAtlas.rasterized
        let added = rt.prepareText({ _, _ in textInput(key: "preview", \Form.edit) }, size: rt.viewport)
        #expect(added == 0)
        #expect(rt.textSystem.layoutKeys() == keys)
        #expect(rt.textSystem.glyphAtlas.rasterized == glyphs)
    }

    enum Overflow: CaseIterable, Sendable {
        case clamp, ellipsis, fade, middle, head
    }

    @Test(arguments: Overflow.allCases)
    func overflowTextCanReusePreparationOnMount(_ overflow: Overflow) throws {
        let view: Runtime<Bool>.ViewFn = { _, _ in
            let label: El<Bool> = text(Self.article).key("clipped").wFull()
            switch overflow {
            case .clamp: return label.maxLines(1)
            case .ellipsis: return label.truncate()
            case .fade: return label.truncateFade()
            case .middle: return label.truncateMiddle()
            case .head: return label.truncateHead()
            }
        }
        let root: Runtime<Bool>.ViewFn = { opened, cx in
            opened ? view(opened, &cx) : el()
        }
        let size = Vec2(75, 75)
        let warm = Runtime(state: false, viewport: size, view: root)
        let cold = Runtime(state: false, viewport: size, view: root)
        _ = warm.frame(at: 0)
        _ = cold.frame(at: 0)
        let glyphs = warm.textSystem.glyphAtlas.rasterized
        #expect(warm.prepareText(view, size: size) > 0)
        let preparedShapes = warm.textSystem.shapedCount
        #expect(warm.prepareText(view, size: size) == 0)
        #expect(warm.textSystem.shapedCount == preparedShapes)
        #expect(warm.textSystem.glyphAtlas.rasterized == glyphs)
        warm.update(at: 0.1) { state, _ in state = true }
        cold.update(at: 0.1) { state, _ in state = true }
        let warmFrame = warm.frame(at: 0.1)
        let coldFrame = cold.frame(at: 0.1)
        let warmNode = try #require(warm.element(byKey: "clipped"))
        let coldNode = try #require(cold.element(byKey: "clipped"))
        #expect(warmNode.rect == coldNode.rect)
        #expect(warmFrame.primitives == coldFrame.primitives)
        #expect(warm.textSystem.shapedCount == preparedShapes)
    }
}
