import Foundation
import Testing
@testable import Rune

/// The document, band sizes, and scroll positions also run in Rune's
/// `runtime/web/page_tests.rs` and `runtime/web/a11y_tests.rs`.
@Suite @MainActor
struct WebPageRuntimeTests {
    private func document(scale: Float = 1) -> Runtime<Int> {
        Runtime(state: 0, viewport: Vec2(400, 200), pixelScale: scale) { _, _ in
            col().wFull()
                .child(col().key("top").wFull().h(300))
                .child(col().key("button").wFull().h(100).focusable().onClick { $0 += 1 })
                .child(col().key("bottom").wFull().h(600))
        }
    }

    @Test func naturalHeightAndHitTestingFollowTheSnappedBand() throws {
        let rt = document()
        rt.pageMode()
        _ = rt.frame(at: 0)
        #expect(rt.pageHeight == 1_000)
        #expect(rt.viewport == Vec2(400, 200))
        #expect(try #require(rt.element(byKey: "button")).rect[1] == 300)

        #expect(rt.setPageScroll(250.4, at: 0.1))
        #expect(!rt.setPageScroll(250.4, at: 0.1))
        _ = rt.frame(at: 0.1)
        #expect(rt.pageOffset == 250)
        #expect(try #require(rt.element(byKey: "button")).rect[1] == 50)
        rt.pointerDown(at: Vec2(100, 80), at: 0.11)
        rt.pointerUp(at: Vec2(100, 80), at: 0.12)
        _ = rt.frame(at: 0.13)
        #expect(rt.state == 1)
    }

    @Test func narrowBandFollowsFractionalScrollAndRubberBanding() throws {
        let rt = document(scale: 2)
        rt.pageMode()
        #expect(!rt.setPageBand(200, view: 200))
        _ = rt.frame(at: 0)
        #expect(rt.setPageScroll(20.25))
        #expect(rt.pageScrollY == 20.5)
        #expect(rt.pageOffset == 20.5)
        #expect(rt.setPageScroll(-60))
        _ = rt.frame(at: 0.1)
        #expect(rt.pageOffset == -60)
        #expect(try #require(rt.element(byKey: "top")).rect[1] == 60)
        #expect(rt.setPageScroll(.nan))
        #expect(rt.pageScrollY == 0)
    }

    @Test func overscanRebasesAtTheMarginAndStopsAtTheFoot() throws {
        let rt = Runtime<Void>(state: (), viewport: Vec2(400, 800), pixelScale: 1) { _, _ in
            col().wFull().children((0..<10).map { i in
                col().key("block-\(i)").wFull().h(500)
            })
        }
        rt.pageMode()
        #expect(!rt.setPageBand(1_312, view: 800))
        _ = rt.frame(at: 0)
        #expect(rt.pageHeight == 5_000)
        #expect(!rt.setPageScroll(120))
        #expect(!rt.setPageScroll(448))
        #expect(rt.pageOffset == 0)
        #expect(rt.setPageScroll(1_000))
        #expect(rt.pageOffset == 744)
        #expect(!rt.setPageScroll(1_100))
        #expect(rt.pageWindow.start == 356)
        #expect(rt.pageWindow.height == 800)
        #expect(rt.setPageScroll(4_200))
        #expect(rt.pageOffset == 3_688)
        #expect(rt.pageOffset + 1_312 == rt.pageHeight)
    }

    @Test func visibilityTracksTheWindowWhileTheBandCoasts() throws {
        let rt = Runtime<[Bool]>(state: [], viewport: Vec2(400, 712), pixelScale: 1) { _, _ in
            col().wFull()
                .child(col().key("button").wFull().h(100).onVisible { state, on, _ in state.append(on) })
                .child(col().wFull().h(900))
        }
        rt.pageMode()
        _ = rt.setPageBand(712, view: 200)
        for _ in 0..<3 { _ = rt.frame(at: 0) }
        #expect(rt.state == [true])
        #expect(!rt.setPageScroll(380))
        for _ in 0..<3 { _ = rt.frame(at: 0.1) }
        #expect(rt.pageWindow.start == 380)
        #expect(rt.pageWindow.height == 200)
        #expect(try #require(rt.element(byKey: "button")).rect[1] == 0)
        #expect(rt.state == [true, false])
    }

    @Test func bandHeightResizeKeepsTheLayoutAndWindowSize() {
        let rt = document()
        rt.pageMode()
        _ = rt.frame(at: 0)
        _ = rt.takeWindowFrameRequest()
        let commits = rt.viewCommitCount
        rt.setViewport(Vec2(400, 160))
        _ = rt.frame(at: 0.1)
        #expect(rt.viewport == Vec2(400, 160))
        #expect(rt.pageHeight == 1_000)
        #expect(rt.viewCommitCount == commits)
        #expect(rt.takeWindowFrameRequest() == nil)
    }

    @Test func horizontalPageScrollUsesTheLivePathAndLeavesFocusOnTheControl() throws {
        let rt = Runtime<Void>(state: (), viewport: Vec2(400, 300), pixelScale: 1) { _, _ in
            col().wFull().child(row().key("strip").size(200, 40).scrollX().child(
                el().key("code").size(600, 40).shrink(0).focusable()
            ))
        }
        rt.pageMode()
        _ = rt.frame(at: 0)
        let path = try #require(rt.element(byKey: "strip")).path
        #expect(rt.accessibilityAction("code", .focus, at: 0))
        #expect(!rt.setPageScrollX("absent", x: 120))
        #expect(!rt.setPageScrollX(path, x: .infinity))
        #expect(rt.setPageScrollX(path, x: 120))
        _ = rt.frame(at: 0.1)
        #expect(rt.scrollOffset(forKey: "strip").x == 120)
        #expect(try #require(rt.element(byKey: "code")).rect[0] == -120)
        #expect(rt.focusedKey == "code")
        #expect(!rt.setPageScrollX(path, x: 120))
        #expect(rt.setPageScrollX(path, x: 1_000))
        #expect(rt.scrollOffset(forKey: "strip").x == 400)
        #expect(rt.setPageScrollX(path, x: -5))
        #expect(rt.scrollOffset(forKey: "strip").x == 0)
    }

    @Test func ordinaryWindowIgnoresDocumentScroll() {
        let rt = document()
        _ = rt.frame(at: 0)
        #expect(!rt.setPageBand(600, view: 200))
        #expect(!rt.setPageScroll(250))
        #expect(rt.pageOffset == 0)
        #expect(rt.pageScrollY == 0)
        #expect(rt.pageWindow.start == 0)
        #expect(rt.pageWindow.height == 200)
    }

    @Test func bandReanchoringKeepsTheExistingBrowserAccessibilityTree() throws {
        let spec = AppSpec<Void>(title: "Page", size: Vec2(480, 812), state: ()) { _, _ in
            col().role(.main).wFull().children((0..<10).map { i in
                text("Section \(i)").key("section-\(i)").role(.heading).wFull().h(500)
            })
        }
        let host = WebAppHost(spec: spec, config: WebAppConfig(webDocument: true))
        let session = WebBrowserSession(host)
        _ = host.runtime.setPageBand(812, view: 300)
        _ = try session.renderFrame(at: 0)
        let initial = try #require(session.takeAccessibility())
        #expect(String(decoding: initial, as: UTF8.self).contains("Section 9"))
        #expect(session.send(Data(#"{"kind":"pageScroll","y":1200}"#.utf8), at: 0.1))
        _ = try session.renderFrame(at: 0.1)
        #expect(host.runtime.pageOffset == 944)
        #expect(session.takeAccessibility() == nil)
    }
}
