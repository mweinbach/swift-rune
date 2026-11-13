import Foundation
#if os(macOS)
import AppKit
#endif

/// Stored global shortcut declaration attached to an `App` (`App::global_shortcut`).
public struct AppGlobalShortcutEntry<State> {
    public var id: String
    public var accelerator: String
    public var label: String
    public var handler: @Sendable (inout State, inout Tx) -> Void

    public init(
        id: String = "",
        accelerator: String,
        label: String = "",
        handler: @escaping @Sendable (inout State, inout Tx) -> Void
    ) {
        self.id = id
        self.accelerator = accelerator
        self.label = label
        self.handler = handler
    }
}

/// Shared configuration helpers linking `App` builders, `ShortcutRegistry`, and `AppWindowSpec` runtimes.
internal enum AppRuntimeConfigurer {
    static func configureShortcuts<State>(
        runtime: Runtime<State>,
        entries: [AppGlobalShortcutEntry<State>],
        allowUnmodified: Bool,
        sharedHandle: AppHandle<State>
    ) {
        guard !entries.isEmpty || allowUnmodified else { return }
        let registry = runtime.shortcutRegistry ?? ShortcutRegistry()
        registry.allowUnmodifiedGlobal = allowUnmodified
        for (idx, entry) in entries.enumerated() {
            let entryId = entry.id.isEmpty ? "app-global-\(idx)-\(entry.accelerator)" : entry.id
            let handler = entry.handler
            _ = registry.register(
                id: entryId,
                accelerator: entry.accelerator,
                scope: .global,
                label: entry.label,
                allowUnmodified: allowUnmodified
            ) {
                sharedHandle.shared.enqueueUpdate(handler)
                sharedHandle.shared.wake()
            }
        }
        runtime.shortcutRegistry = registry
    }

    static func configure<State>(app: App<State>, into runtime: Runtime<State>) {
        runtime.windowTitle = app.title
        runtime.srgbBlend = app.srgbBlendEnabled
        runtime.fontSmoothing = app.fontSmoothingMode
        runtime.poll = app.pollHook
        runtime.onFocus = app.onFocusHook
        runtime.onModifiers = app.onModifiersHook
        runtime.onVisibility = app.onVisibilityHook
        runtime.onIme = app.onImeHook
        runtime.onClose = app.onCloseHook
        runtime.onQuit = app.onQuitHook
        runtime.turnScope = app.turnScopeHook
        runtime.onReopen = app.onReopenHook
        runtime.onOpenUrl = app.onOpenUrlHook
        runtime.tabVisitsControls = app.tabVisitsControlsEnabled
        runtime.fitHeight = app.isFitContentHeight
        configureShortcuts(
            runtime: runtime,
            entries: app.globalShortcuts,
            allowUnmodified: app.allowUnmodifiedShortcutsEnabled,
            sharedHandle: app.sharedHandle
        )
    }
}

extension App {
    /// Registers a system-wide shortcut that updates `State` via `AppHandle` (`App::global_shortcut`).
    public func globalShortcut(
        _ accelerator: String,
        label: String = "",
        handler: @escaping @Sendable (inout State, inout Tx) -> Void
    ) -> App<State> {
        var copy = self
        copy.globalShortcuts.append(AppGlobalShortcutEntry(
            accelerator: accelerator,
            label: label,
            handler: handler
        ))
        return copy
    }

    /// Convenience overload ignoring `Tx` (`App::global_shortcut`).
    public func globalShortcut(
        _ accelerator: String,
        label: String = "",
        handler: @escaping @Sendable (inout State) -> Void
    ) -> App<State> {
        globalShortcut(accelerator, label: label) { state, _ in
            handler(&state)
        }
    }

    /// Allows unmodified single-key global accelerators when registering shortcuts (`App::allow_unmodified_shortcuts`).
    public func allowUnmodifiedShortcuts(_ allow: Bool = true) -> App<State> {
        var copy = self
        copy.allowUnmodifiedShortcutsEnabled = allow
        return copy
    }

    /// Opts the web target into document flow height sizing (`App::web_document`).
    public func webDocument(_ enabled: Bool = true) -> App<State> {
        var copy = self
        copy.isWebDocument = enabled
        return copy
    }

    /// Registers a lazy web font URL to load before text renders (`App::font_url`).
    public func fontUrl(_ url: String) -> App<State> {
        var copy = self
        copy.fontURLStrings.append(url)
        return copy
    }

    /// Registers multiple web font URLs (`App::font_url`).
    public func fontUrls(_ urls: [String]) -> App<State> {
        var copy = self
        copy.fontURLStrings.append(contentsOf: urls)
        return copy
    }

    /// Returns the resolved `WebAppConfig` reflecting `webDocument`, `fitContentHeight`, and `fontUrl`.
    public var webAppConfig: WebAppConfig {
        WebAppConfig(
            webDocument: isWebDocument,
            fitContentHeight: isFitContentHeight || isWebDocument,
            fontUrls: fontURLStrings
        )
    }
}

extension AppHandle {
    /// Computes top-left screen coordinates for `placement` on `display` and submits a `PlaceRequest`.
    public func place(
        _ display: DisplayTarget,
        _ placement: OverlayPlacement,
        windowSize: Vec2 = Vec2(560, 220)
    ) {
        let screens = systemDisplays()
        let chosen: DisplayInfo = {
            switch display {
            case .primary:
                return screens.first(where: \.primary) ?? screens.first ?? DisplayInfo()
            case .index(let idx):
                return (idx >= 0 && idx < screens.count) ? screens[idx] : (screens.first ?? DisplayInfo())
            case .named(let name):
                return screens.first(where: { $0.name == name }) ?? screens.first ?? DisplayInfo()
            case .id(let dispId):
                return screens.first(where: { $0.id == dispId }) ?? screens.first ?? DisplayInfo()
            case .native(let nativeId):
                return screens.first(where: { $0.nativeId == nativeId }) ?? screens.first ?? DisplayInfo()
            case .underPointer:
                return screens.first(where: \.primary) ?? screens.first ?? DisplayInfo()
            }
        }()
        let scale = Float(max(chosen.scale, 1.0))
        let dispW = Float(chosen.size.0) / scale
        let dispH = Float(chosen.size.1) / scale
        let dispX = Float(chosen.position.0)
        let dispY = Float(chosen.position.1)

        switch placement {
        case .fullDisplay:
            place(PlaceRequest(position: Vec2(dispX, dispY), size: Vec2(dispW, dispH), display: display))
        case .rect(let r):
            place(PlaceRequest(position: Vec2(dispX + r.x, dispY + r.y), size: Vec2(r.width, r.height), display: display))
        case .edge(let edge, let margin):
            place(display, .edgeAligned(edge, margin: margin, align: .center, inset: 0), windowSize: windowSize)
        case let .edgeAligned(edge, margin, align, inset):
            let x: Float
            switch align {
            case .start:
                x = dispX + inset
            case .center:
                x = dispX + max(0, (dispW - windowSize.x) * 0.5)
            case .end:
                x = dispX + max(0, dispW - windowSize.x - inset)
            }
            let y: Float
            switch edge {
            case .top:
                y = dispY + margin
            case .bottom:
                y = dispY + max(0, dispH - windowSize.y - margin)
            }
            place(PlaceRequest(position: Vec2(x, y), display: display))
        }
    }
}

/// Returns current connected displays in top-left global coordinates (`rune::displays`).
public func systemDisplays() -> [DisplayInfo] {
    #if os(macOS)
    let screens = NSScreen.screens
    guard !screens.isEmpty else { return [DisplayInfo()] }
    let primaryHeight = screens.first?.frame.height ?? 900.0
    var out: [DisplayInfo] = []
    out.reserveCapacity(screens.count)
    for (idx, scr) in screens.enumerated() {
        let f = scr.frame
        let scale = Double(max(scr.backingScaleFactor, 1.0))
        let topLeftY = primaryHeight - (f.origin.y + f.size.height)
        let dispId = (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map {
            RuneDisplayId(native: .macOS($0.uint32Value))
        }
        out.append(DisplayInfo(
            id: dispId,
            name: scr.localizedName,
            position: (Int32(f.origin.x.rounded()), Int32(topLeftY.rounded())),
            size: (UInt32((f.size.width * CGFloat(scale)).rounded()), UInt32((f.size.height * CGFloat(scale)).rounded())),
            scale: scale,
            primary: idx == 0
        ))
    }
    return out
    #else
    return [DisplayInfo()]
    #endif
}

/// Launches a multi-window Rune application given available display metadata (`rune::run_windows`).
@MainActor
public func runWindows(
    options: RunOptions = RunOptions(),
    arguments: [String]? = nil,
    _ makeWindows: ([DisplayInfo]) -> [AnyWindowSpec]
) throws {
    let windows = makeWindows(systemDisplays())
    try RuneMultiWindow.runWindows(windows, options: options, arguments: arguments)
}
