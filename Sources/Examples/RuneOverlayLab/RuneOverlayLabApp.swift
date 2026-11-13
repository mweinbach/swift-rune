import Foundation
import Rune
import RuneKit
#if os(macOS)
import AppKit
#endif
#if canImport(Darwin)
import Darwin
#endif

public struct PickerState: Sendable {
    public var displayIndex: Int
    public var displayName: String
    public var bounds: Vec2
    public var underlay: Bool
    public var lastPointer: Vec2?
    public var selectionStart: Vec2?
    public var selectionEnd: Vec2?
    public var cancelled: Bool = false

    public init(
        displayIndex: Int = 0,
        displayName: String = "Primary",
        bounds: Vec2 = Vec2(1440, 900),
        underlay: Bool = false,
        lastPointer: Vec2? = nil,
        selectionStart: Vec2? = nil,
        selectionEnd: Vec2? = nil,
        cancelled: Bool = false
    ) {
        self.displayIndex = displayIndex
        self.displayName = displayName
        self.bounds = bounds
        self.underlay = underlay
        self.lastPointer = lastPointer
        self.selectionStart = selectionStart
        self.selectionEnd = selectionEnd
        self.cancelled = cancelled
    }
}

public struct PillState: Sendable {
    public var expanded: Bool = false
    public var inputMode: OverlayInput = .regions
    public var clickCount: UInt32 = 0
    public var offset: Vec2 = .zero
    public var dragStartOffset: Vec2 = .zero
    public var pointerPos: Vec2 = Vec2(130, 32)
    public var pickerActive: Bool = false

    public init(
        expanded: Bool = false,
        inputMode: OverlayInput = .regions,
        clickCount: UInt32 = 0,
        offset: Vec2 = .zero,
        pointerPos: Vec2 = Vec2(130, 32),
        pickerActive: Bool = false
    ) {
        self.expanded = expanded
        self.inputMode = inputMode
        self.clickCount = clickCount
        self.offset = offset
        self.dragStartOffset = offset
        self.pointerPos = pointerPos
        self.pickerActive = pickerActive
    }
}

public struct LabSceneState: Sendable {
    public enum Mode: Sendable {
        case pill
        case picker
    }

    public var mode: Mode = .pill
    public var pill: PillState = PillState()
    public var picker: PickerState = PickerState(bounds: Vec2(460, 320), underlay: false)

    public init() {}
}

public final class LabController: @unchecked Sendable {
    public let displays: [DisplayInfo]
    public let pickers: [OverlayHandle<PickerState>]
    public let pill: OverlayHandle<PillState>
    public let underlay: Bool

    private let onPickerRequested: (() -> Void)?
    private let onQuitRequested: (() -> Void)?

    public init(
        displays: [DisplayInfo],
        pickers: [OverlayHandle<PickerState>],
        pill: OverlayHandle<PillState>,
        underlay: Bool,
        onPickerRequested: (() -> Void)? = nil,
        onQuitRequested: (() -> Void)? = nil
    ) {
        self.displays = displays
        self.pickers = pickers
        self.pill = pill
        self.underlay = underlay
        self.onPickerRequested = onPickerRequested
        self.onQuitRequested = onQuitRequested
    }

    public func showPill() {
        for p in pickers { p.hide() }
        pill.show()
        pill.update { $0.pickerActive = false }
    }

    public func showPicker() {
        pill.hide()
        for p in pickers {
            p.update {
                $0.cancelled = false
                $0.selectionStart = nil
                $0.selectionEnd = nil
            }
            p.show()
        }
        pickers.first?.requestKeys()
        onPickerRequested?()
    }

    public func hideAll() {
        pill.hide()
        for p in pickers { p.hide() }
    }

    public func setPillInput(_ input: OverlayInput) {
        pill.setInput(input)
        pill.update { $0.inputMode = input }
    }

    public func setExpanded(_ expanded: Bool) {
        pill.update { $0.expanded = expanded }
    }

    public func handleCommand(_ rawCommand: String) -> String {
        let cmd = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch cmd {
        case "show", "pill":
            showPill()
            return "ok:pill"
        case "picker":
            showPicker()
            return "ok:picker"
        case "hide":
            hideAll()
            return "ok:hidden"
        case "hit", "regions":
            setPillInput(.regions)
            return "ok:regions"
        case "all":
            setPillInput(.all)
            return "ok:all"
        case "none":
            setPillInput(.none)
            return "ok:none"
        case "expand":
            setExpanded(true)
            return "ok:expanded"
        case "collapse":
            setExpanded(false)
            return "ok:collapsed"
        case "status":
            let winNum = pill.windowNumber.map(String.init) ?? "none"
            let excl = "\(pill.captureExclusion)"
            return "pillVisible=\(pill.isVisible) pickers=\(pickers.count) windowNumber=\(winNum) captureExclusion=\(excl)"
        case "quit":
            hideAll()
            onQuitRequested?()
            return "ok:quit"
        default:
            return "err:unknown:\(cmd)"
        }
    }
}

@main
public enum RuneOverlayLabApp {
    public static func currentDisplays() -> [DisplayInfo] {
        #if os(macOS)
        let screens = NSScreen.screens
        if !screens.isEmpty {
            let mainHeight = screens[0].frame.height
            return screens.enumerated().map { idx, screen in
                let f = screen.frame
                let displayId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? UInt32(idx + 1)
                let topLeftY = Int32((mainHeight - f.maxY).rounded())
                return DisplayInfo(
                    id: RuneDisplayId(native: .macOS(displayId)),
                    name: screen.localizedName,
                    position: (Int32(f.origin.x.rounded()), topLeftY),
                    size: (UInt32(max(1, f.width.rounded())), UInt32(max(1, f.height.rounded()))),
                    scale: Double(screen.backingScaleFactor),
                    primary: idx == 0
                )
            }
        }
        #endif
        return [DisplayInfo()]
    }

    public static func renderPicker<State>(
        _ s: PickerState,
        mutate: @escaping (@escaping (inout PickerState) -> Void, inout State) -> Void
    ) -> El<State> {
        let t = Tok.theme(dark: true)
        let bgColor = s.underlay ? Color.srgb(0.05, 0.07, 0.13, 0.42) : Color.srgb(0, 0, 0, 0.14)
        let pointerLabel = s.lastPointer.map { "(\(Int($0.x)), \(Int($0.y)))" } ?? "move pointer"

        var root: El<State> = el()
            .key("picker-root-\(s.displayIndex)")
            .sizeFull()
            .bg(bgColor)
            .hit(true)
            .onPointerMove { state, ptr, tx in
                mutate({ $0.lastPointer = ptr.local }, &state)
                tx.liveOnly()
            }
            .onDrag { state, drag, tx in
                mutate({ p in
                    if p.selectionStart == nil {
                        p.selectionStart = drag.startLocal
                    }
                    p.selectionEnd = drag.local
                }, &state)
                tx.instant()
            }

        if let p0 = s.selectionStart, let p1 = s.selectionEnd {
            let left = min(p0.x, p1.x)
            let top = min(p0.y, p1.y)
            let w = max(2, abs(p1.x - p0.x))
            let h = max(2, abs(p1.y - p0.y))
            root = root.child(
                el()
                    .key("selection-box")
                    .pin(top: top, left: left)
                    .w(w)
                    .h(h)
                    .rounded(6)
                    .bg(Tok.accent(0, dark: true).alpha(0.18))
                    .border(2, Tok.accent(0, dark: true))
            )
        }

        let headingText: El<State> = text("Display Picker #\(s.displayIndex) — \(s.displayName)")
            .font(Tok.Typography.title)
            .color(t.text)
        let captionText: El<State> = text("Drag to select region • Esc to return to pill • \(pointerLabel)")
            .font(Tok.Typography.monoCaption)
            .color(t.textSecondary)
        let banner: El<State> = col()
            .key("picker-banner")
            .pin(top: 28, left: 28)
            .p(14)
            .gap(6)
            .rounded(12)
            .bg(t.card.alpha(0.94))
            .border(1, t.cardBorder)
            .child(headingText)
            .child(captionText)

        return root.child(banner)
    }

    public static func renderPill<State>(
        _ s: PillState,
        mutate: @escaping (@escaping (inout PillState) -> Void, inout State) -> Void
    ) -> El<State> {
        let t = Tok.theme(dark: true)
        let cardW: Float = s.expanded ? 286 : 220
        let cardH: Float = s.expanded ? 124 : 50
        let modeBadge: String
        switch s.inputMode {
        case .regions: modeBadge = "HIT-ONLY"
        case .all: modeBadge = "ALL"
        case .none: modeBadge = "NONE"
        case .legacy: modeBadge = "LEGACY"
        }

        let header: El<State> = row()
            .wFull()
            .itemsCenter()
            .justifyBetween()
            .child(text("Overlay Lab").font(Tok.Typography.label).color(t.text))
            .child(
                row()
                    .key("mode-badge")
                    .px(8)
                    .h(22)
                    .center()
                    .rounded(999)
                    .bg(Tok.accent(0, dark: true).alpha(0.2))
                    .child(text(modeBadge).size(11).color(t.text))
            )

        var card: El<State> = col()
            .key("pill-card")
            .hit(true)
            .pin(top: max(8, 24 + s.offset.y), left: max(8, 24 + s.offset.x))
            .w(cardW)
            .h(cardH)
            .p(12)
            .gap(10)
            .rounded(16)
            .bg(t.card.alpha(0.94))
            .border(1, t.cardBorder)
            .onDrag { state, drag, tx in
                mutate({ p in
                    p.offset = Vec2(
                        p.dragStartOffset.x + drag.delta.x,
                        p.dragStartOffset.y + drag.delta.y
                    )
                }, &state)
                tx.instant()
            }
            .onDragEnd { state, _, _ in
                mutate({ $0.dragStartOffset = $0.offset }, &state)
            }
            .child(header)

        if s.expanded {
            let expandedRow: El<State> = row()
                .wFull()
                .gap(8)
                .itemsCenter()
                .child(
                    row()
                        .key("btn-toggle-expand")
                        .role(.button)
                        .label("Collapse")
                        .hit(true)
                        .h(28)
                        .px(10)
                        .center()
                        .rounded(8)
                        .bg(t.hover)
                        .onClick { state in
                            mutate({ $0.expanded = false }, &state)
                        }
                        .child(text("Collapse").size(12).color(t.text))
                )
                .child(
                    row()
                        .key("btn-picker")
                        .role(.button)
                        .label("Picker")
                        .hit(true)
                        .h(28)
                        .px(10)
                        .center()
                        .rounded(8)
                        .bg(Tok.accent(0, dark: true))
                        .onClick { state in
                            mutate({ $0.pickerActive = true }, &state)
                        }
                        .child(text("Picker").size(12).color(.white))
                )
                .child(
                    text("Ptr (\(Int(s.pointerPos.x)), \(Int(s.pointerPos.y)))")
                        .size(11)
                        .color(t.textSecondary)
                )
            card = card.child(expandedRow)
        } else {
            let collapsedRow: El<State> = row()
                .wFull()
                .justifyBetween()
                .itemsCenter()
                .child(text("Drag me • clicks \(s.clickCount)").size(11).color(t.textSecondary))
                .child(
                    row()
                        .key("btn-expand")
                        .role(.button)
                        .label("Expand")
                        .hit(true)
                        .h(20)
                        .px(8)
                        .center()
                        .rounded(6)
                        .bg(t.hover)
                        .onClick { state in
                            mutate({
                                $0.expanded = true
                                $0.clickCount &+= 1
                            }, &state)
                        }
                        .child(text("Expand").size(11).color(t.text))
                )
            card = card.child(collapsedRow)
        }

        let canvas: El<State> = el()
            .key("pill-canvas")
            .sizeFull()
            .bg(.transparent)
            .onPointerMove { state, ptr, tx in
                mutate({ $0.pointerPos = ptr.local }, &state)
                tx.liveOnly()
            }
            .child(card)

        return canvas
    }

    public static func pickerView(_ s: PickerState, _ cx: inout Cx<PickerState>) -> El<PickerState> {
        renderPicker(s) { edit, state in
            edit(&state)
        }
    }

    public static func pillView(_ s: PillState, _ cx: inout Cx<PillState>) -> El<PillState> {
        renderPill(s) { edit, state in
            edit(&state)
        }
    }

    public static func sceneView(_ s: LabSceneState, _ cx: inout Cx<LabSceneState>) -> El<LabSceneState> {
        switch s.mode {
        case .pill:
            return renderPill(s.pill) { edit, state in
                edit(&state.pill)
            }
        case .picker:
            return renderPicker(s.picker) { edit, state in
                edit(&state.picker)
            }
        }
    }

    public static func makeLab(
        displays: [DisplayInfo] = currentDisplays(),
        underlay: Bool = ProcessInfo.processInfo.environment["OVERLAY_LAB_UNDERLAY"] == "1",
        onQuit: (() -> Void)? = nil
    ) -> LabController {
        let resolvedDisplays = displays.isEmpty ? [DisplayInfo()] : displays
        var pickerBox: [OverlayHandle<PickerState>] = []
        var pillHandleRef: OverlayHandle<PillState>? = nil

        let pillOptions = OverlayOptions(
            placement: .edge(.top, margin: 24),
            display: .underPointer,
            followPointer: true,
            level: .aboveOverlays,
            excludeFromCapture: false,
            keyPolicy: .nonActivating,
            input: .regions,
            prewarm: true,
            interactive: true
        )
        let pillConfigured = OverlaySpec<PillState>(
            name: "overlay-lab-pill",
            size: Vec2(340, 180),
            edge: .top,
            margin: 24,
            interactive: true,
            options: pillOptions,
            makeState: { PillState() },
            view: pillView
        )
        .configured(pillOptions)
        .onCreated { created in
            fputs(
                "overlay-lab pill created (windowNumber: \(String(describing: created.windowNumber)), captureExclusion: \(created.capabilities.captureExclusion))\n",
                stderr
            )
        }

        let pillHandle = pillConfigured.makeHandle()
        pillHandleRef = pillHandle

        for (idx, display) in resolvedDisplays.enumerated() {
            let bounds = Vec2(Float(max(1, display.size.0)), Float(max(1, display.size.1)))
            let displayName = display.name ?? "Display \(idx + 1)"
            let opts = OverlayOptions(
                placement: .fullDisplay,
                display: .index(idx),
                followPointer: false,
                level: .aboveStatus,
                excludeFromCapture: false,
                keyPolicy: .activating,
                input: .all,
                prewarm: true,
                interactive: true
            )
            let pickerHandle = OverlaySpec<PickerState>(
                name: "overlay-lab-picker-\(idx)",
                size: bounds,
                interactive: true,
                options: opts,
                makeState: {
                    PickerState(
                        displayIndex: idx,
                        displayName: displayName,
                        bounds: bounds,
                        underlay: underlay
                    )
                },
                view: pickerView
            )
            .configured(opts)
            .onCreated { created in
                fputs(
                    "overlay-lab picker-\(idx) created (windowNumber: \(String(describing: created.windowNumber)), captureExclusion: \(created.capabilities.captureExclusion))\n",
                    stderr
                )
            }
            .onKey { state, event, _ in
                if event.key == .escape {
                    state.cancelled = true
                    for h in pickerBox { h.hide() }
                    pillHandleRef?.show()
                    pillHandleRef?.update { $0.pickerActive = false }
                    return true
                }
                return false
            }
            .makeHandle()
            pickerBox.append(pickerHandle)
        }

        return LabController(
            displays: resolvedDisplays,
            pickers: pickerBox,
            pill: pillHandle,
            underlay: underlay,
            onQuitRequested: onQuit
        )
    }

    public static func makeApp(
        arguments: [String] = Array(CommandLine.arguments.dropFirst())
    ) -> App<LabSceneState> {
        let parsed = ToolingArgs.parse(arguments)
        let isHeadless = parsed.isHeadlessRequested
        let env = ProcessInfo.processInfo.environment
        let underlay = env["OVERLAY_LAB_UNDERLAY"] == "1" || env["OVERLAY_LAB_UNDERLAY"] == "true"
        let startWithPicker = env["OVERLAY_LAB_PICKER"] == "1" || env["OVERLAY_LAB_PICKER"] == "true"
        let autoQuitSeconds = env["OVERLAY_LAB_SECONDS"].flatMap(Double.init)
        let controlPath = env["OVERLAY_LAB_CONTROL"]

        var app = App<LabSceneState>(
            title: "Overlay Lab",
            size: Vec2(460, 320),
            dark: true,
            state: LabSceneState(),
            view: sceneView
        )
        .windowless(true)

        let commands = app.handle()
        if !isHeadless {
            app = app.setup { _ in
                let lab = makeLab(
                    displays: currentDisplays(),
                    underlay: underlay,
                    onQuit: { commands.quit() }
                )
                if startWithPicker {
                    lab.showPicker()
                } else {
                    lab.showPill()
                }

                if let seconds = autoQuitSeconds, seconds > 0 {
                    Thread.detachNewThread {
                        Thread.sleep(forTimeInterval: seconds)
                        lab.hideAll()
                        commands.quit()
                    }
                }

                if let controlPath, !controlPath.isEmpty {
                    startControlSocket(at: controlPath, lab: lab)
                }
            }
        }

        return app
            .scene("pill") { s, _ in
                s.mode = .pill
                s.pill = PillState(expanded: false, inputMode: .regions, clickCount: 1)
            }
            .scene("expanded") { s, _ in
                s.mode = .pill
                s.pill = PillState(expanded: true, inputMode: .all, clickCount: 3)
            }
            .scene("picker") { s, _ in
                s.mode = .picker
                s.picker = PickerState(
                    displayIndex: 0,
                    displayName: "Primary",
                    bounds: Vec2(460, 320),
                    underlay: false,
                    lastPointer: Vec2(210, 140),
                    selectionStart: Vec2(120, 110),
                    selectionEnd: Vec2(330, 230)
                )
            }
            .scene("underlay") { s, _ in
                s.mode = .picker
                s.picker = PickerState(
                    displayIndex: 0,
                    displayName: "Primary",
                    bounds: Vec2(460, 320),
                    underlay: true,
                    lastPointer: Vec2(240, 170)
                )
            }
            .scene("hit-only") { s, _ in
                s.mode = .pill
                s.pill = PillState(expanded: false, inputMode: .regions, clickCount: 0, offset: Vec2(18, 12))
            }
    }

    private static func startControlSocket(at path: String, lab: LabController) {
        #if canImport(Darwin)
        Thread.detachNewThread {
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            let bytes = Array(path.utf8.prefix(maxLen - 1))
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                for (i, b) in bytes.enumerated() {
                    raw[i] = b
                }
                raw[bytes.count] = 0
            }
            let bindRes = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindRes == 0, listen(fd, 8) == 0 else { return }

            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { continue }
                var buf = [UInt8](repeating: 0, count: 1024)
                let n = read(client, &buf, buf.count)
                if n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8) {
                    for line in text.split(separator: "\n") {
                        let reply = lab.handleCommand(String(line)) + "\n"
                        _ = reply.withCString { cstr in
                            write(client, cstr, strlen(cstr))
                        }
                    }
                }
                close(client)
            }
        }
        #else
        _ = path
        _ = lab
        #endif
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        try RuneApp.run(makeApp(arguments: args), arguments: args)
    }
}
