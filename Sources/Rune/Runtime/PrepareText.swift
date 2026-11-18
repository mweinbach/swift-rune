import Foundation
import RuneMotion

/// The latest request on this event thread, shared by transactions but consumed only
/// by a runtime with the requested state type. WASI uses the reactor's local store.
private final class PreparedTextRequest<State> {
    let view: Runtime<State>.ViewFn
    let size: Vec2?

    init(view: @escaping Runtime<State>.ViewFn, size: Vec2?) {
        self.view = view
        self.size = size
    }
}

/// Windows own captured views. The event thread keeps only a weak reference so closing
/// a window releases an unserved request even when no other event ever arrives.
internal final class WindowTextPreparation {
    fileprivate final class Reference: @unchecked Sendable {
        weak var window: WindowTextPreparation?
        init(_ window: WindowTextPreparation) { self.window = window }
    }

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var windows: [UInt64: Reference] = [:]
    private let id: UInt64
    fileprivate let stateType: ObjectIdentifier
    fileprivate var request: Any?

    init(id: UInt64, stateType: Any.Type) {
        self.id = id
        self.stateType = ObjectIdentifier(stateType)
        Self.registryLock.withLock { Self.windows[id] = Reference(self) }
    }

    deinit {
        _ = Self.registryLock.withLock { Self.windows.removeValue(forKey: id) }
    }

    fileprivate static func window(id: UInt64) -> WindowTextPreparation? {
        registryLock.withLock { windows[id]?.window }
    }
}

private enum TextPreparationTicket {
    case window(WindowTextPreparation.Reference)
    case unbound(AnyObject)

    static let key = "rune.tx.preparedText"

    static var current: Self? {
        get { RuneExecutionContext.locals[key] as? Self }
        set {
            if let newValue { RuneExecutionContext.locals[key] = newValue }
            else { RuneExecutionContext.locals.removeObject(forKey: key) }
        }
    }

    func request<S>(for runtime: Runtime<S>) -> PreparedTextRequest<S>? {
        switch self {
        case .window(let ref):
            guard let owner = ref.window else { return nil }
            // A request for its origin's own state belongs to that exact window. A view for a
            // different state can run in the first matching window while the origin is alive.
            if owner.stateType == ObjectIdentifier(S.self), owner !== runtime.textPreparation { return nil }
            return owner.request as? PreparedTextRequest<S>
        case .unbound(let request):
            return request as? PreparedTextRequest<S>
        }
    }
}

extension Tx {
    /// Lays out a view's text in the window's next idle turn without mounting its elements.
    /// The most recent request wins. Size is in points and defaults to the window viewport.
    /// The cache keeps about one MiB of layouts prepared for unmounted views until the window rests.
    public mutating func prepareText<S>(_ view: @escaping Runtime<S>.ViewFn, size: Vec2? = nil) {
        let windowID = preparationWindowID ?? currentRuntimeId()
        let owner = windowID.flatMap(WindowTextPreparation.window(id:))
        guard windowID == nil || owner != nil else { return }
        if case .window(let previous) = TextPreparationTicket.current { previous.window?.request = nil }
        let request = PreparedTextRequest(view: view, size: size)
        if let owner {
            owner.request = request
            TextPreparationTicket.current = .window(.init(owner))
        } else {
            unboundPreparation = request
            TextPreparationTicket.current = .unbound(request)
        }
    }
}

extension Runtime {
    internal var textIdleOwed: Bool {
        TextPreparationTicket.current?.request(for: self) != nil
    }

    /// Some native callbacks receive a plain Tx and attach it to a window on return.
    internal func claimPreparedText(from tx: Tx) {
        guard let request = tx.unboundPreparation,
              case .unbound(let pending) = TextPreparationTicket.current,
              pending === request, let owner = textPreparation else { return }
        owner.request = request
        TextPreparationTicket.current = .window(.init(owner))
    }

    /// Releases any work still owned by a closing window, including a view capturing its owner.
    internal func cancelPreparedText() {
        textPreparation?.request = nil
    }

    /// Consumes one matching request. A view may queue another while it is measured.
    @discardableResult
    internal func textIdleTurn() -> Bool {
        guard let ticket = TextPreparationTicket.current, let request = ticket.request(for: self) else { return false }
        TextPreparationTicket.current = nil
        if case .window(let origin) = ticket { origin.window?.request = nil }
        prepareText(request.view, size: request.size ?? viewport)
        return textIdleOwed
    }

    @discardableResult
    internal func prepareText(_ view: @escaping ViewFn, size: Vec2) -> Int {
        textSystem.prepareLayouts {
            // A normal measurement expands virtual rows and computes the same width-dependent
            // text layouts. The retained tree, memo, layout reads and waker belong to this pass.
            let scratch = Runtime(state: state, viewport: size, pixelScale: pixelScale,
                                  systemDark: systemDark, reducedMotion: reducedMotion,
                                  textSystem: textSystem, waker: Waker(), onKey: nil,
                                  runtimeId: runtimeId, view: view)
            scratch.srgbBlend = srgbBlend
            scratch.cxSettings = cxSettings
            scratch.windowFocused = windowFocused
            scratch.layoutSeen.rects = layoutSeen.rects
            RuntimeIdScope.$current.withValue(runtimeId) {
                _ = scratch.measurePass(at: cxSettings.lastHostTime, cut: false, commitKind: .animate,
                                        commitMotion: nil, commitColorSpring: nil, commitCut: false,
                                        prevMountedIds: [NodeId: Int]().keys, focusedCaret: nil, allowZoomSettle: false,
                                        preparingFor: self)
            }
        }
    }
}
