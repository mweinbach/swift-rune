import Testing
import Foundation
import AppKit
@testable import Rune

@Suite("RunePlatformCloseoutDesktopTests")
struct RunePlatformCloseoutDesktopTests {
    // MARK: - Helpers

    private static let pngBytes: Data = {
        ClipboardImage.encodeRGBAAsPNG(width: 1, height: 1, rgba: Data([255, 0, 0, 255]))!
    }()

    @MainActor
    private static func makeBoard(_ items: [[(String, Data)]]) -> NSPasteboard? {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        let pbItems: [NSPasteboardItem] = items.map { pairs in
            let item = NSPasteboardItem()
            for (uti, data) in pairs {
                item.setData(data, forType: NSPasteboard.PasteboardType(uti))
            }
            return item
        }
        guard pb.writeObjects(pbItems) else {
            pb.releaseGlobally()
            return nil
        }
        return pb
    }

    private static func eq(_ key: String, _ mask: UInt) -> MenuKeyEquivalent {
        MenuKeyEquivalent(key: key, modifierMask: mask)
    }

    // MARK: - platform/macos/drop.rs (13 tests)

    @Test("drop: a file URL is its path")
    @MainActor
    func dropFileURLIsItsPath() {
        guard let pb = Self.makeBoard([[("public.file-url", Data("file:///tmp/notes%20one.txt".utf8))]]) else { return }
        defer { pb.releaseGlobally() }
        let items = MacOSDropReader.inspectItems(in: pb).map(\.1)
        #expect(items == [.file("/tmp/notes one.txt")])
    }

    @Test("drop: image data without a file is an image")
    @MainActor
    func dropImageDataWithoutFileIsAnImage() {
        guard let pb = Self.makeBoard([
            [("public.png", Self.pngBytes)],
            [("public.url", Data("https://e.com/a.png".utf8)), ("public.tiff", Data([0x49, 0x49, 0x2A, 0x00]))],
        ]) else { return }
        defer { pb.releaseGlobally() }
        let items = MacOSDropReader.inspectItems(in: pb).map(\.1)
        #expect(items == [.image(uti: "public.png", extension: "png"), .image(uti: "public.tiff", extension: "png")])
    }

    @Test("drop: a file URL wins over the image beside it")
    @MainActor
    func dropFileURLWinsOverImage() {
        guard let pb = Self.makeBoard([[("public.file-url", Data("file:///tmp/a.png".utf8)), ("public.png", Self.pngBytes)]]) else { return }
        defer { pb.releaseGlobally() }
        let items = MacOSDropReader.inspectItems(in: pb).map(\.1)
        #expect(items == [.file("/tmp/a.png")])
    }

    @Test("drop: a promise is named for its type")
    @MainActor
    func dropPromiseNamedForType() {
        guard let pb = Self.makeBoard([[
            ("com.apple.NSFilePromiseItemMetaData", Data("x".utf8)),
            ("com.apple.pasteboard.promised-file-content-type", Data("public.png".utf8)),
        ]]) else { return }
        defer { pb.releaseGlobally() }
        let items = MacOSDropReader.inspectItems(in: pb).map(\.1)
        #expect(items == [.promise(extension: "png")])
    }

    @Test("drop: hover paths stand in for files to come")
    func dropHoverPathsStandInForFilesToCome() {
        #expect(DropPasteboardItem.file("/tmp/a.txt").hoverPath == "/tmp/a.txt")
        #expect(DropPasteboardItem.promise(extension: "png").hoverPath == "File.png")
        #expect(DropPasteboardItem.promise(extension: nil).hoverPath == "File")
        #expect(DropPasteboardItem.image(uti: "public.tiff", extension: "png").hoverPath == "Image.png")
    }

    @Test("drop: promised types map to extensions")
    func dropPromisedTypesMapToExtensions() {
        #expect(DropTempNaming.extensionForPromisedUTI("public.jpeg") == "jpg")
        #expect(DropTempNaming.extensionForPromisedUTI("com.adobe.pdf") == "pdf")
        #expect(DropTempNaming.extensionForPromisedUTI("public.data") == nil)
    }

    @Test("drop: file URLs resolve to paths")
    func dropFileURLsResolveToPaths() {
        #expect(DropTempNaming.filePath(fromURLString: "file:///tmp/notes%20one.txt") == "/tmp/notes one.txt")
        #expect(DropTempNaming.filePath(fromURLString: "https://e.com/a.png") == nil)
    }

    @Test("drop: taken names are numbered")
    func dropTakenNamesAreNumbered() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rune-drop-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(DropTempNaming.freeName(stem: "Image", ext: "png", existing: []) == "Image.png")
        try Data().write(to: dir.appendingPathComponent("Image.png"))
        try Data().write(to: dir.appendingPathComponent("Image 2.png"))
        let existing = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))
        #expect(DropTempNaming.freeName(stem: "Image", ext: "png", existing: existing) == "Image 3.png")
    }

    @Test("drop: text alone gives nothing")
    @MainActor
    func dropTextAloneGivesNothing() {
        guard let pb = Self.makeBoard([
            [("public.utf8-plain-text", Data("hello".utf8))],
            [("public.url", Data("https://e.com/".utf8))],
        ]) else { return }
        defer { pb.releaseGlobally() }
        #expect(MacOSDropReader.inspectItems(in: pb).isEmpty)
    }

    @Test("drop: images are written named for their URL")
    @MainActor
    func dropImagesWrittenNamedForURL() throws {
        guard let pb = Self.makeBoard([
            [("public.png", Self.pngBytes)],
            [("public.png", Self.pngBytes)],
            [("public.url", Data("https://e.com/img/kitten.jpg?w=2".utf8)), ("public.png", Self.pngBytes)],
        ]) else { return }
        defer { pb.releaseGlobally() }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rune-drop-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let paths: [URL] = MacOSDropReader.inspectItems(in: pb).compactMap { pbItem, kind in
            guard case let .image(uti, ext) = kind else { return nil }
            return MacOSDropReader.writeImage(from: pbItem, uti: uti, extension: ext, directory: dir)
        }
        #expect(paths.map(\.lastPathComponent) == ["Image.png", "Image 2.png", "kitten.png"])
        #expect(try Data(contentsOf: paths[0]) == Self.pngBytes)
    }

    @Test("drop: URL stems")
    func dropURLStems() {
        #expect(DropTempNaming.urlStem(fromURLString: "https://e.com/a/cat.photo.png?x=1") == "cat.photo")
        #expect(DropTempNaming.urlStem(fromURLString: "https://e.com/") == nil)
        #expect(DropTempNaming.urlStem(fromURLString: "https://e.com") == nil)
        #expect(DropTempNaming.urlStem(fromURLString: "data:image/png;base64,AAAA") == nil)
    }

    @Test("drop: the operation follows the source")
    @MainActor
    func dropOperationFollowsSource() {
        #expect(MacOSDropReader.operation(forSourceMask: 1 | 2 | 16) == 1)
        #expect(MacOSDropReader.operation(forSourceMask: 4) == 4)
        #expect(MacOSDropReader.operation(forSourceMask: 0) == 0)
        #expect(MacOSDropReader.operation(forSourceMask: 2) == 0)
    }

    @Test("drop: moves coalesce and steps track the drag")
    func dropMovesCoalesceAndStepsTrackDrag() {
        var queue = MacOSDropQueue()
        queue.push(.enter(["a"], Vec2(1, 1)))
        queue.push(.move(Vec2(2, 2)))
        queue.push(.move(Vec2(3, 3)))
        #expect(queue.isOver)
        queue.push(.drop(["a"], Vec2(3, 3)))
        #expect(!queue.isOver)
        #expect(queue.take() == [
            .enter(["a"], Vec2(1, 1)),
            .move(Vec2(3, 3)),
            .drop(["a"], Vec2(3, 3)),
        ])
    }

    // MARK: - drag_out/mod.rs (10 tests)

    @Test("drag_out: threshold is straight-line travel beyond the platform distance")
    func dragOutThresholdStraightLine() {
        let t = DragItem.defaultThreshold
        #expect(!DragItem.pastThreshold(from: Vec2(10, 10), to: Vec2(10, 10), threshold: t))
        #expect(!DragItem.pastThreshold(from: Vec2(10, 10), to: Vec2(10 + t, 10), threshold: t))
        #expect(DragItem.pastThreshold(from: Vec2(10, 10), to: Vec2(10 + t + 0.1, 10), threshold: t))
        let d = t * 0.75
        #expect(DragItem.pastThreshold(from: .zero, to: Vec2(d, d), threshold: t))
    }

    @Test("drag_out: a drag item collects files image and text")
    func dragOutItemCollectsFilesImageText() {
        let item = DragItem().file(path: "/a.png").file(path: "/b.txt").text("hello").png(Data([1, 2, 3]))
        #expect(item.paths == [URL(fileURLWithPath: "/a.png"), URL(fileURLWithPath: "/b.txt")])
        #expect(item.plainText == "hello")
        #expect(item.pngData == Data([1, 2, 3]))
        #expect(!item.allowsMove && item.dragImage == nil && !item.isEmpty)
        #expect(DragItem().isEmpty)
        #expect(DragItem().allowMove().allowsMove)
    }

    @Test("drag_out: a drag offers copy unless told otherwise")
    func dragOutOffersCopyUnlessToldOtherwise() {
        let copyOnly = DragItem()
        #expect(copyOnly.offers(.copy) && !copyOnly.offers(.move) && !copyOnly.offers(.link))
        let copyAndMove = DragItem().allowMove()
        #expect(copyAndMove.offers(.copy) && copyAndMove.offers(.move))
        let moveOnly = DragItem().operation(.move)
        #expect(!moveOnly.offers(.copy) && moveOnly.offers(.move) && moveOnly.allowsMove)
        let linkAndCopy = DragItem().operation(.link).allow(.copy)
        #expect(linkAndCopy.offers(.copy) && linkAndCopy.offers(.link) && !linkAndCopy.offers(.move))
    }

    @Test("drag_out: drag image frames start over the element or under the pointer")
    func dragOutImageFrames() throws {
        let rect = MotionRect.fromXYWH(20, 40, 200, 32)
        let press = Vec2(50, 60)
        let image = try #require(DragImage.rgba(width: 1, height: 1, pixels: Data([0, 0, 0, 0])))
        #expect(image.frame(bounds: rect, press: press, natural: Vec2(64, 64)) == MotionRect.fromXYWH(18, 28, 64, 64))
        #expect(image.size(10, 20).frame(bounds: rect, press: press, natural: Vec2(64, 64)) == MotionRect.fromXYWH(45, 50, 10, 20))
        #expect(image.overElement().frame(bounds: rect, press: press, natural: Vec2(64, 64)) == rect)
        #expect(image.size(10, 12).overElement().frame(bounds: rect, press: press, natural: Vec2(64, 64)) == MotionRect.fromXYWH(20, 40, 10, 12))
        #expect(image.overElement().frame(bounds: MotionRect.fromXYWH(5, 5, 0, 0), press: press, natural: Vec2(1, 1)) == MotionRect.fromXYWH(5, 5, 1, 1))
    }

    @Test("drag_out: the snapshot frame is its pixel-aligned crop")
    func dragOutSnapshotFramePixelAlignedCrop() throws {
        let image = try #require(DragImage.rgba(width: 41, height: 21, pixels: Data(repeating: 0, count: 41 * 21 * 4)))
            .size(20.5, 10.5)
            .at(Vec2(10, 5))
        #expect(image.frame(bounds: MotionRect.fromXYWH(10.2, 5.3, 20, 10), press: .zero, natural: Vec2(41, 21)) == MotionRect.fromXYWH(10, 5, 20.5, 10.5))
    }

    @Test("drag_out: an opaque backing fills transparent pixels and keeps opaque ones")
    func dragOutOpaqueBackingFillsTransparentPixels() throws {
        let pixels = Data([
            255, 0, 0, 255,
            0, 0, 0, 0,
            255, 255, 255, 128,
        ])
        let image = try #require(DragImage.rgba(width: 3, height: 1, pixels: pixels)).size(3, 1).overElement()
        let flat = try #require(image.over(Color(r: 0, g: 0, b: 1, a: 1)))
        #expect(flat.pointsSize == Vec2(3, 1))
        #expect(flat.placement == .element)
        let decoded = try PortablePNG.decode(try #require(flat.pngData))
        let rgba = decoded.rgba
        #expect(Array(rgba[0..<4]) == [255, 0, 0, 255])
        #expect(Array(rgba[4..<8]) == [0, 0, 255, 255])
        let half = Array(rgba[8..<12])
        #expect(half[3] == 255)
        #expect(half[0] == half[1] && half[0] > 150 && half[2] == 255)
    }

    @Test("drag_out: the picture is the item's image else the snapshot over the backing")
    func dragOutPicturePrecedence() throws {
        let snap = try #require(DragImage.rgba(width: 1, height: 1, pixels: Data([0, 0, 0, 0])))
        let own = try #require(DragImage.rgba(width: 1, height: 1, pixels: Data([1, 2, 3, 255])))
        #expect(DragImage.picture(for: DragItem(), snapshot: snap) == snap)
        #expect(DragImage.picture(for: DragItem().image(own), snapshot: snap) == own)
        #expect(DragImage.picture(for: DragItem(), snapshot: nil) == nil)
        let flat = try #require(DragImage.picture(for: DragItem().opaque(.white), snapshot: snap))
        let decoded = try PortablePNG.decode(try #require(flat.pngData))
        #expect(Array(decoded.rgba[0..<4]) == [255, 255, 255, 255])
    }

    @Test("drag_out: rgba encodes png and rejects a wrong length")
    func dragOutRGBAEncodesPNGRejectsWrongLength() throws {
        let item = DragItem().rgba(width: 1, height: 1, pixels: Data([255, 0, 0, 255]))
        let png = try #require(item.pngData)
        #expect(Array(png[1..<4]) == Array("PNG".utf8))
        #expect(DragItem().rgba(width: 2, height: 2, pixels: Data([0, 0, 0, 0])).pngData == nil)
        #expect(DragImage.rgba(width: 0, height: 0, pixels: Data()) == nil)
        #expect(DragImage.rgba(width: 1, height: 1, pixels: Data([0, 0, 0, 0]))?.size(8, 8).pointsSize == Vec2(8, 8))
    }

    @Test("drag_out: snapshot crop clamps to the frame in device pixels")
    func dragOutSnapshotCropClamps() {
        #expect(DragImage.snapshotCrop(rect: MotionRect.fromXYWH(10, 5, 20, 10), scale: 2, size: (400, 300)) == [20, 10, 40, 20])
        #expect(DragImage.snapshotCrop(rect: MotionRect.fromXYWH(-5, -5, 10, 10), scale: 2, size: (400, 300)) == [0, 0, 10, 10])
        #expect(DragImage.snapshotCrop(rect: MotionRect.fromXYWH(190, 0, 50, 10), scale: 2, size: (400, 300)) == [380, 0, 20, 20])
        #expect(DragImage.snapshotCrop(rect: MotionRect.fromXYWH(500, 0, 10, 10), scale: 2, size: (400, 300)) == nil)
    }

    @Test("drag_out: readback unpremultiplies and swaps bgra")
    func dragOutReadbackUnpremultipliesAndSwapsBGRA() {
        var p: [UInt8] = [0, 0, 128, 128, 10, 20, 30, 255]
        DragImage.toStraightRGBA(&p, bgra: true)
        #expect(p == [255, 0, 0, 128, 30, 20, 10, 255])
    }

    // MARK: - drag_out/macos.rs (session & mask helpers)

    @Test("drag_out macos: the mask offers what the item allows")
    func dragOutMacOSMaskOffersWhatItemAllows() {
        #expect(MacOSDragOutLogic.dragOperationMask(for: DragItem()) == MacOSDragOutLogic.nsCopyMask)
        #expect(MacOSDragOutLogic.dragOperationMask(for: DragItem().allowMove()) == (MacOSDragOutLogic.nsCopyMask | MacOSDragOutLogic.nsMoveMask))
        #expect(MacOSDragOutLogic.dragOperationMask(for: DragItem().operation(.move)) == MacOSDragOutLogic.nsMoveMask)
        #expect(MacOSDragOutLogic.dragOperationMask(for: DragItem().operation(.link).allow(.copy)) == (MacOSDragOutLogic.nsLinkMask | MacOSDragOutLogic.nsCopyMask))
    }

    @Test("drag_out macos: nothing is offered to the app's own windows unless withinApp")
    func dragOutMacOSWithinApplicationMask() {
        let m = MacOSDragOutLogic.nsCopyMask | MacOSDragOutLogic.nsLinkMask
        #expect(MacOSDragOutLogic.operationMask(for: m, withinApplication: false, dropsWithinApp: false) == m)
        #expect(MacOSDragOutLogic.operationMask(for: m, withinApplication: true, dropsWithinApp: false) == 0)
        #expect(MacOSDragOutLogic.operationMask(for: m, withinApplication: true, dropsWithinApp: true) == m)
        #expect(MacOSDragOutLogic.operationMask(for: m, withinApplication: false, dropsWithinApp: true) == m)
    }

    @Test("drag_out macos: modifier keys only count when several operations are offered")
    func dragOutMacOSModifierKeysOnlyWhenMultipleOps() {
        #expect(MacOSDragOutLogic.ignoreModifierKeys(for: DragItem()))
        #expect(!MacOSDragOutLogic.ignoreModifierKeys(for: DragItem().allow(.link)))
        #expect(!MacOSDragOutLogic.ignoreModifierKeys(for: DragItem().allowMove()))
    }

    @Test("drag_out macos: operations map to outcomes")
    func dragOutMacOSOperationsMapToOutcomes() {
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsCopyMask) == .copied)
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsMoveMask) == .moved)
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsDeleteMask) == .moved)
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsGenericMask) == .moved)
        #expect(MacOSDragOutLogic.outcome(from: MacOSDragOutLogic.nsLinkMask) == .linked)
        #expect(MacOSDragOutLogic.outcome(from: 0) == .cancelled)
    }

    @Test("drag_out macos: unended session reports cancelled once and ended session does not repeat")
    @MainActor
    func dragOutMacOSSessionCompletionGuards() {
        var log1: [DragOutcome] = []
        do {
            let s1 = MacOSDragOutCoordinator.Session(
                operationMask: .copy,
                dropsWithinApp: false,
                ignoreModifiers: true,
                mutedWindows: [],
                mutedViews: []
            ) { log1.append($0) }
            _ = s1
        }
        #expect(log1 == [.cancelled])

        var log2: [DragOutcome] = []
        do {
            let s2 = MacOSDragOutCoordinator.Session(
                operationMask: .copy,
                dropsWithinApp: false,
                ignoreModifiers: true,
                mutedWindows: [],
                mutedViews: []
            ) { log2.append($0) }
            s2.finish(with: .copied)
        }
        #expect(log2 == [.copied])
    }

    // MARK: - tray.rs (2 tests)

    @Test("tray: enabled leaves separators alone")
    func trayEnabledLeavesSeparatorsAlone() {
        #expect(TrayItem.separator.enabled(false) == .separator)
        #expect(TrayItem.action(id: "q", label: "Quit").enabled(false) == .action(id: "q", label: "Quit", enabled: false))
    }

    @Test("tray: a short icon is refused")
    func trayShortIconIsRefused() {
        let icon = TrayIcon(width: 2, height: 2, rgba: Data([0, 0, 0]))
        #expect(!icon.isValid)
        #expect(throws: TrayError.self) {
            _ = try icon.validated()
        }
    }

    // MARK: - native_menu/key_equivalent_tests.rs (4 tests)

    @Test("native_menu: equivalents are the characters the accelerators name")
    func menuEquivalentsAreCharactersNamed() {
        let cmd = MenuKeyEquivalent.commandMask
        let ctrl = MenuKeyEquivalent.controlMask
        let opt = MenuKeyEquivalent.optionMask
        let shift = MenuKeyEquivalent.shiftMask

        #expect(MenuKeyEquivalent(parsing: "cmd+b") == Self.eq("b", cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+=") == Self.eq("=", cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+-") == Self.eq("-", cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+r") == Self.eq("r", cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+1") == Self.eq("1", cmd))
        #expect(MenuKeyEquivalent(parsing: "ctrl+cmd+s") == Self.eq("s", ctrl | cmd))
        #expect(MenuKeyEquivalent(parsing: "ctrl+cmd+f") == Self.eq("f", ctrl | cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+shift+z") == Self.eq("z", shift | cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+shift+=") == Self.eq("=", shift | cmd))
        #expect(MenuKeyEquivalent(parsing: "ctrl+alt+shift+cmd+k") == Self.eq("k", ctrl | opt | shift | cmd))
    }

    @Test("native_menu: named keys use appkit characters")
    func menuNamedKeysUseAppKitCharacters() {
        let cmd = MenuKeyEquivalent.commandMask
        let ctrl = MenuKeyEquivalent.controlMask
        let opt = MenuKeyEquivalent.optionMask
        let shift = MenuKeyEquivalent.shiftMask

        #expect(MenuKeyEquivalent(parsing: "alt+cmd+left") == Self.eq("\u{f702}", opt | cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+up") == Self.eq("\u{f700}", cmd))
        #expect(MenuKeyEquivalent(parsing: "f5") == Self.eq("\u{f708}", 0))
        #expect(MenuKeyEquivalent(parsing: "shift+f24") == Self.eq("\u{f71b}", shift))
        #expect(MenuKeyEquivalent(parsing: "cmd+enter") == Self.eq("\r", cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+backspace") == Self.eq("\u{8}", cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+delete") == Self.eq("\u{f728}", cmd))
        #expect(MenuKeyEquivalent(parsing: "cmd+escape") == Self.eq("\u{1b}", cmd))
        #expect(MenuKeyEquivalent(parsing: "ctrl+tab") == Self.eq("\t", ctrl))
        #expect(MenuKeyEquivalent(parsing: "cmd+space") == Self.eq(" ", cmd))
    }

    @Test("native_menu: every key has one lowercase character")
    func menuEveryKeyHasOneLowercaseCharacter() {
        let names = [
            "a", "z", "0", "9", "minus", "equal", "comma", "period", "slash", "semicolon", "quote",
            "bracketleft", "bracketright", "backslash", "backquote", "f1", "f24", "escape", "enter", "space", "tab",
            "backspace", "delete", "insert", "home", "end", "pageup", "pagedown", "left", "right", "up", "down",
        ]
        for name in names {
            guard let eq = MenuKeyEquivalent(parsing: "cmd+\(name)") else {
                Issue.record("failed to parse cmd+\(name)")
                continue
            }
            #expect(eq.key.unicodeScalars.count == 1, "expected 1 char for \(name), got \(eq.key.debugDescription)")
            #expect(eq.key.lowercased() == eq.key, "capital would add Shift for \(name)")
        }
    }

    @Test("native_menu: menu keycaps show the accelerator")
    func menuKeycapsShowAccelerator() {
        #expect(Chord(parsing: "cmd+b")?.menuKeycaps(on: .mac) == ["⌘", "B"])
        #expect(Chord(parsing: "cmd+b")?.menuKeycaps(on: .linux) == ["Super", "B"])
        #expect(Chord(parsing: "ctrl+cmd+f")?.menuKeycaps().last == "F")
        #expect(Chord(parsing: "cmd+=")?.menuKeycaps().last == "=")
        #expect(Chord(parsing: "cmd+shift+z")?.menuKeycaps().last == "Z")
        #expect(Chord(parsing: "ctrl+f5")?.menuKeycaps().last == "F5")
        #expect(Chord(parsing: "ctrl+left")?.menuKeycaps().last == "←")
    }
}
