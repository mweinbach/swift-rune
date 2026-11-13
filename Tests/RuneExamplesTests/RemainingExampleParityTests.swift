import Foundation
import Testing
@testable import Rune
@testable import RuneDragOut
@testable import RuneDropFiles
@testable import RuneRichClipboard

@Suite("Remaining Example Parity Tests (Phase 1)", .serialized)
@MainActor
struct RemainingExampleParityTests {
    // Upstream: examples/rich-clipboard/src/main.rs:72 (unblocked HTML sanitizer + tx.copyRich + memory Clipboard)
    @Test("rich-clipboard: copy button writes rich payload and memory clipboard sanitizes untrusted HTML")
    func richClipboardCopyAndSanitize() throws {
        let board = Clipboard(kind: .memory)
        let rt = Runtime<RichClipboardState>(
            state: RichClipboardState(clipboard: board),
            viewport: Vec2(560, 420),
            pixelScale: 2.0,
            systemDark: true,
            view: richClipboardView
        )
        rt.frame(at: 0.0)

        let copyRect = try #require(rt.element(byKey: "copy")?.rect)
        let copyCenter = Vec2(copyRect[0] + copyRect[2] * 0.5, copyRect[1] + copyRect[3] * 0.5)
        rt.pointerDown(at: copyCenter, at: 0.01)
        rt.pointerUp(at: copyCenter, at: 0.02)
        rt.frame(at: 0.03)
        #expect(rt.richClipboard == sampleRichPayload())

        board.writeRich(
            RichClipboardPayload(
                text: "Hi",
                html: "<b>Hi</b><img src=x onerror=alert(1)>"
            )
        )
        let readRect = try #require(rt.element(byKey: "read")?.rect)
        let readCenter = Vec2(readRect[0] + readRect[2] * 0.5, readRect[1] + readRect[3] * 0.5)
        rt.pointerDown(at: readCenter, at: 0.04)
        rt.pointerUp(at: readCenter, at: 0.05)
        rt.frame(at: 0.06)

        let last = try #require(rt.state.last)
        #expect(last.0 == "Read")
        #expect(last.1.text == "Hi")
        #expect(last.1.html == "<b>Hi</b><img src=x>")
    }

    // Upstream: examples/rich-clipboard/src/main.rs:72
    @Test(
        "rich-clipboard: a_rich_paste_shows_its_forms_and_the_field_keeps_the_text",
        .disabled("Blocked on @el/@platform: Runtime lacks Runtime.useClipboard(_:), tx.requestPaste(), and El.onPaste")
    )
    func richClipboardFullPasteFlow() {}

    // Upstream: examples/drag-out/src/main.rs:68 (unblocked drag state + tile layout)
    @Test("drag-out: renders file/app/text tiles and dims active tile while dragging")
    func dragOutTileLayoutAndDragState() throws {
        let state = DragOutState(
            file: URL(fileURLWithPath: "/tmp/a.txt"),
            app: URL(fileURLWithPath: "/Applications/Example.app")
        )
        let rt = Runtime<DragOutState>(
            state: state,
            viewport: Vec2(520, 200),
            pixelScale: 2.0,
            systemDark: true,
            view: dragOutView
        )
        rt.frame(at: 0.0)
        #expect(rt.element(byKey: "file") != nil)
        let appRect = try #require(rt.element(byKey: "app")?.rect)
        let appCenter = Vec2(appRect[0] + appRect[2] * 0.5, appRect[1] + appRect[3] * 0.5)
        rt.pointerMove(to: appCenter, at: 0.01)
        rt.pointerDown(at: appCenter, at: 0.02)
        rt.pointerMove(to: Vec2(appCenter.x + 20, appCenter.y), at: 0.03)
        rt.frame(at: 0.04)
        #expect(rt.state.dragging == "app")

        rt.pointerUp(at: Vec2(appCenter.x + 20, appCenter.y), at: 0.05)
        rt.frame(at: 0.06)
        #expect(rt.state.dragging == nil)
        #expect(rt.state.last?.0 == "app")
    }

    // Upstream: examples/drag-out/src/main.rs:68
    @Test(
        "drag-out: dragging_a_tile_hands_its_file_to_the_system",
        .disabled("Blocked on @platform/@el: El.dragOut / El.onDragStart and Runtime.events drag-out dispatch")
    )
    func dragOutSystemSession() {}

    // Upstream: examples/drop-files/src/main.rs:75 (unblocked zone layout & formatting)
    @Test("drop-files: formats dropped file names and highlights hovered zone")
    func dropFilesFormattingAndHover() throws {
        let names = formatNames([
            DroppedFile(path: "/tmp/a.png", name: "a.png", sizeBytes: 12),
            DroppedFile(path: "/tmp/notes.txt", name: "notes.txt", sizeBytes: 34),
        ])
        #expect(names == "a.png, notes.txt")

        let rt = Runtime<DropFilesState>(
            state: DropFilesState(),
            viewport: Vec2(520, 240),
            pixelScale: 2.0,
            systemDark: true,
            view: dropFilesView
        )
        rt.frame(at: 0.0)
        let picRect = try #require(rt.element(byKey: "pictures")?.rect)
        let center = Vec2(picRect[0] + picRect[2] * 0.5, picRect[1] + picRect[3] * 0.5)
        rt.pointerMove(to: center, at: 0.01)
        rt.frame(at: 0.02)
        #expect(rt.state.over == "pictures")
    }

    // Upstream: examples/drop-files/src/main.rs:75
    @Test(
        "drop-files: pictures_go_to_the_pictures_zone_and_the_rest_to_the_zone_around_them",
        .disabled("Blocked on @platform/@el: El.onDropFiles / El.onDropHover / acceptsExtensions and Runtime.dragFiles/dropFiles")
    )
    func dropFilesSystemDispatch() {}

    // Upstream: examples/motion-bento/src/tests.rs:11
    @Test(
        "motion-bento: script_taps_reach_the_same_state_as_the_schedule",
        .disabled("Blocked on Phase 2: motion-bento dock/schedule view + Shell AppSpec.poll(t)")
    )
    func motionBentoScriptTapsReachSchedule() {}

    // Upstream: examples/kit-gallery/src/layer_timing.rs:40, 84 (manual #[ignore] GPU baseline benchmarks)
    @Test(
        "kit-gallery: disabled_controls_match_legacy_pixels & disabled_controls_gpu_cost",
        .disabled("Manual upstream #[ignore] GPU baseline benchmark requiring RUNE_KIT_PIXEL_BASELINE & Metal timestamp queries")
    )
    func kitGalleryLayerTimingManualBenchmarks() {}
}
