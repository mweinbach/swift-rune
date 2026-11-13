import Foundation
import Testing
import Rune
@testable import RuneCustomTitlebar

@Suite("Phase 3 CustomTitlebar example", .serialized)
@MainActor
struct Phase3CustomTitlebarTests {

    @Test("rune-custom-titlebar: zoom cycles band height, theme toggles dark mode, dialog opens and closes")
    func titlebarControlsAndModal() throws {
        let rt = Runtime<CustomTitlebarState>(
            state: CustomTitlebarState(),
            viewport: Vec2(720, 420),
            pixelScale: 2.0,
            systemDark: true,
            view: customTitlebarView
        )
        rt.frame(at: 0.0)

        let titlebar0 = try #require(rt.element(byKey: "titlebar"))
        #expect(abs(titlebar0.rect[3] - 44.0) < 0.5)
        #expect(rt.element(byKey: "status-line")?.text == "scale 2.00, theme presses 0")
        #expect(rt.element(byKey: "scrim") == nil)

        // Click Zoom -> 1.25x (55pt)
        let zoomRect = try #require(rt.element(byKey: "zoom")?.rect)
        let zoomPt = Vec2(zoomRect[0] + zoomRect[2] * 0.5, zoomRect[1] + zoomRect[3] * 0.5)
        rt.pointerMove(to: zoomPt, at: 0.01)
        rt.pointerDown(at: zoomPt, at: 0.02)
        rt.pointerUp(at: zoomPt, at: 0.03)
        rt.frame(at: 0.04)

        #expect(rt.state.zoom == 1)
        let titlebar1 = try #require(rt.element(byKey: "titlebar"))
        #expect(abs(titlebar1.rect[3] - 55.0) < 0.5)

        // Click Theme -> switches dark true -> false, presses == 1
        let themeRect = try #require(rt.element(byKey: "theme")?.rect)
        let themePt = Vec2(themeRect[0] + themeRect[2] * 0.5, themeRect[1] + themeRect[3] * 0.5)
        rt.pointerMove(to: themePt, at: 0.05)
        rt.pointerDown(at: themePt, at: 0.06)
        rt.pointerUp(at: themePt, at: 0.07)
        rt.frame(at: 0.08)

        #expect(rt.state.dark == false)
        #expect(rt.state.presses == 1)
        #expect(rt.element(byKey: "status-line")?.text == "scale 2.00, theme presses 1")

        // Click Dialog -> opens modal scrim + sheet
        let dialogRect = try #require(rt.element(byKey: "dialog")?.rect)
        let dialogPt = Vec2(dialogRect[0] + dialogRect[2] * 0.5, dialogRect[1] + dialogRect[3] * 0.5)
        rt.pointerMove(to: dialogPt, at: 0.09)
        rt.pointerDown(at: dialogPt, at: 0.10)
        rt.pointerUp(at: dialogPt, at: 0.11)
        rt.frame(at: 0.12)

        #expect(rt.state.dialog == true)
        #expect(rt.element(byKey: "scrim") != nil)
        #expect(rt.element(byKey: "sheet") != nil)

        // Click Close inside modal -> closes modal
        let closeRect = try #require(rt.element(byKey: "close-dialog")?.rect)
        let closePt = Vec2(closeRect[0] + closeRect[2] * 0.5, closeRect[1] + closeRect[3] * 0.5)
        rt.pointerMove(to: closePt, at: 0.13)
        rt.pointerDown(at: closePt, at: 0.14)
        rt.pointerUp(at: closePt, at: 0.15)
        rt.frame(at: 0.16)

        #expect(rt.state.dialog == false)
        #expect(rt.element(byKey: "scrim") == nil)
    }
}
