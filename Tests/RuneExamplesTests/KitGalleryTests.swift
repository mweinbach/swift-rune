import Foundation
import Testing
@testable import Rune
@testable import RuneKit
@testable import RuneKitGallery

@Suite("Kit Gallery Parity Tests (Phase 1)", .serialized)
@MainActor
struct KitGalleryTests {
    @Test("every_story_builds: all 131 stories render across OpenCode, Neutral, and Palette in light & dark")
    func everyStoryBuilds() {
        #expect(galleryStories.count == 131)
        let ids = galleryStories.map(\.id)
        #expect(Set(ids).count == 131)

        let kits: [(neutral: Bool, palette: Bool)] = [
            (false, false),
            (true, false),
            (false, true),
        ]

        for (neutral, palette) in kits {
            for dark in [false, true] {
                for id in ids {
                    var state = GalleryState(neutral: neutral, palette: palette)
                    applyStorySetup(&state, storyId: id)
                    let kit = resolveGalleryKit(state, dark: dark)
                    var overlays: [El<GalleryState>] = []
                    let body = renderGalleryStory(state, kit, overlays: &overlays)
                    #expect(state.story == id)
                    _ = body
                }
            }
        }
    }

    @Test("CLI flags parse --kit neutral, --kit palette black|warm, and --reduced-motion")
    func cliKitFlagParsing() {
        let neutral = GalleryState.initFromArgs(["rune-kit-gallery", "--kit", "neutral"])
        #expect(neutral.neutral)
        #expect(!neutral.palette)

        let paletteBlack = GalleryState.initFromArgs(["rune-kit-gallery", "--kit", "palette", "black", "--reduced-motion"])
        #expect(paletteBlack.palette)
        #expect(paletteBlack.paletteBlack)
        #expect(!paletteBlack.paletteWarm)
        #expect(paletteBlack.reduced)

        let paletteWarm = GalleryState.initFromArgs(["rune-kit-gallery", "--kit", "palette", "warm"])
        #expect(paletteWarm.palette)
        #expect(paletteWarm.paletteWarm)
    }

    @Test("Combobox story filters by typing, navigates with arrows, confirms with Enter, and dismisses on Escape")
    func comboboxKeyboardScriptFlow() throws {
        var initial = GalleryState()
        applyStorySetup(&initial, storyId: "rune-combobox--searchable")
        #expect(initial.comboOpen)

        let rt = Runtime(
            state: initial,
            viewport: Vec2(720, 480),
            pixelScale: 1,
            systemDark: true,
            onKey: galleryHandleKey,
            view: galleryView
        )
        rt.frame(at: 0)
        #expect(rt.element(byKey: "model-popup") != nil)

        // Move up from 0 wraps to last model, then type "099" to narrow to Model 099 and press Enter.
        _ = rt.keyDown(KeyEvent(key: .arrowUp), at: 0.01)
        var t = 0.02
        for ch in "099" {
            _ = rt.keyDown(KeyEvent(key: .text(String(ch))), at: t)
            t += 0.01
        }
        _ = rt.keyDown(KeyEvent(key: .enter), at: 0.06)
        rt.frame(at: 0.08)

        #expect(rt.state.edits[5].text == "099")
        #expect(rt.state.pick["model"] == "model-99")
        #expect(!rt.state.comboOpen)

        // Clicking trigger reopens and Escape closes.
        let triggerRect = try #require(rt.element(byKey: "model-trigger")?.rect)
        let pt = Vec2(triggerRect[0] + 12, triggerRect[1] + 12)
        rt.pointerDown(at: pt, at: 0.1)
        rt.pointerUp(at: pt, at: 0.11)
        rt.frame(at: 0.12)
        #expect(rt.state.comboOpen)

        _ = rt.keyDown(KeyEvent(key: .escape), at: 0.15)
        rt.frame(at: 0.16)
        #expect(!rt.state.comboOpen)
    }

    @Test("Help tooltip appears on hovering copy button and stagger list toggles rows")
    func hoverTooltipAndStaggerList() throws {
        var tipState = GalleryState()
        applyStorySetup(&tipState, storyId: "rune-text--selectable-help")
        let tipRt = Runtime(
            state: tipState,
            viewport: Vec2(720, 480),
            pixelScale: 1,
            systemDark: true,
            onKey: galleryHandleKey,
            view: galleryView
        )
        tipRt.frame(at: 0)
        #expect(tipRt.element(byKey: "copy-tip-tip") == nil)

        let copyRect = try #require(tipRt.element(byKey: "copy")?.rect)
        tipRt.pointerMove(to: Vec2(copyRect[0] + copyRect[2] * 0.5, copyRect[1] + copyRect[3] * 0.5), at: 0.05)
        tipRt.frame(at: 0.1)
        #expect(tipRt.state.hoverCopy)
        #expect(tipRt.element(byKey: "copy-tip-tip") != nil)

        var staggerState = GalleryState()
        applyStorySetup(&staggerState, storyId: "motion-stagger-list")
        let staggerRt = Runtime(
            state: staggerState,
            viewport: Vec2(720, 480),
            pixelScale: 1,
            systemDark: true,
            onKey: galleryHandleKey,
            view: galleryView
        )
        staggerRt.frame(at: 0)
        #expect(staggerRt.element(byKey: "Inbox") == nil)

        let openerRect = try #require(staggerRt.element(byKey: "opener")?.rect)
        let center = Vec2(openerRect[0] + openerRect[2] * 0.5, openerRect[1] + openerRect[3] * 0.5)
        staggerRt.pointerDown(at: center, at: 0.05)
        staggerRt.pointerUp(at: center, at: 0.06)
        staggerRt.frame(at: 0.1)
        #expect(staggerRt.state.isOn("rows"))
        #expect(staggerRt.element(byKey: "Inbox") != nil)
        #expect(staggerRt.element(byKey: "Trash") != nil)
    }

    @Test("Motion focus modal opens dialog and dismisses cleanly on Escape")
    func motionFocusModalFlow() throws {
        var modalState = GalleryState()
        applyStorySetup(&modalState, storyId: "motion-focus-modal")
        let rt = Runtime(
            state: modalState,
            viewport: Vec2(720, 480),
            pixelScale: 1,
            systemDark: true,
            onKey: galleryHandleKey,
            view: galleryView
        )
        rt.frame(at: 0)
        #expect(rt.element(byKey: "dialog") == nil)

        let openerRect = try #require(rt.element(byKey: "opener")?.rect)
        let center = Vec2(openerRect[0] + openerRect[2] * 0.5, openerRect[1] + openerRect[3] * 0.5)
        rt.pointerDown(at: center, at: 0.05)
        rt.pointerUp(at: center, at: 0.06)
        rt.frame(at: 0.1)
        #expect(rt.state.open == "dialog")
        #expect(rt.element(byKey: "dialog") != nil)

        _ = rt.keyDown(KeyEvent(key: .escape), at: 0.15)
        rt.frame(at: 0.2)
        #expect(rt.state.open == nil)
        // Advance past exit transition (~0.8s) so exiting dialog is removed.
        for step in 1...12 {
            rt.frame(at: 0.2 + Double(step) * 0.1)
        }
        #expect(rt.element(byKey: "dialog") == nil)
    }
}
