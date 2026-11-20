import Foundation

// MARK: - Overlay Keyboard Policy Helpers (`crates/rune/src/overlay/keys.rs`, `#1240`)

public extension OverlayKeyPolicy {
    /// Upstream `KeyPolicy::OnDemand` alias for `.nonActivating`: lets a shown overlay take
    /// keyboard focus on `requestKeys()` or click without taking focus when merely shown.
    static let onDemand: OverlayKeyPolicy = .nonActivating
}

/// Cross-platform keyboard-focus policy for overlay windows (macOS panel, layer-shell, X11, Windows)
/// matching `crates/rune/src/overlay/keys.rs` (`#1240`).
public enum OverlayKeys {
    /// Whether an overlay window with `policy` may take keyboard focus.
    ///
    /// Windows makes one that may without `WS_EX_NOACTIVATE`; X11 gives it the input focus on
    /// `requestKeys` and on a click; macOS panel becomes key on `requestKeys` or click;
    /// `.none` never takes keys.
    public static func canTakeKeys(_ policy: OverlayKeyPolicy) -> Bool {
        policy != .none
    }

    /// What an overlay with `policy` reports as `OverlayCapabilities.nonactivatingKeys`.
    /// `focuser`: whether the platform piece that focuses it is present (X11's SHAPE-capable
    /// connection, layer-shell v4 keyboard interactivity, or always `true` for macOS panel and Windows).
    public static func keysSupport(_ policy: OverlayKeyPolicy, focuser: Bool) -> OverlaySupport {
        canTakeKeys(policy) && focuser ? .supported : .unsupported
    }

    /// Mirrors `overlay/xwayland.rs::xwayland_allowed`: XWayland override-redirect windows never
    /// take keyboard focus, so any policy that may take keys refuses XWayland.
    public static func xwaylandAllowed(
        input: OverlayInput,
        keyPolicy: OverlayKeyPolicy,
        optIn: Bool
    ) -> Bool {
        !canTakeKeys(keyPolicy) && (optIn || input == .none)
    }

    /// Mirrors `platform/layer_shell_machine/keyboard.rs::supports_keys`.
    public static func layerShellSupportsKeys(
        policy: OverlayKeyPolicy,
        protocolVersion: UInt32,
        hasKeyboard: Bool
    ) -> Bool {
        canTakeKeys(policy) && protocolVersion >= 4 && hasKeyboard
    }
}

// MARK: - Windows Overlay Context-Menu Foreground Hand-Back (`popup_menu/win32.rs`, `#1240`)

/// Pure decision helper matching `crates/rune/src/popup_menu/win32.rs::hands_back`.
public enum WindowsPopupFocus {
    /// Whether the menu's `owner` gives the foreground back to `previous` once the menu closes:
    /// an overlay (whatever its `OverlayKeyPolicy`) that took the foreground only for the menu
    /// and still has it. One that had the foreground before (an `onDemand` overlay the user
    /// clicked) keeps it.
    public static func handsBack(
        isOverlay: Bool,
        previous: UInt,
        owner: UInt,
        foreground: UInt
    ) -> Bool {
        isOverlay && previous != 0 && previous != owner && foreground == owner
    }
}

// MARK: - Overlay Clipboard Receive Cadence (`overlay/input.rs::clipboard_due`, `#1249`)

/// Action taken when an overlay receives a clipboard reply (paste, `Tx.readClipboard`, or
/// secret-copy state change).
public enum OverlayClipboardDueAction: Equatable, Sendable {
    /// No clipboard reply arrived; leave the overlay untouched.
    case none
    /// Overlay is currently shown or fading out (non-frameless): mark dirty and let the next
    /// drawn frame step it once instead of advancing outside draw.
    case deferToNextFrame
    /// Overlay is hidden or occluded (frameless): mark dirty and advance immediately so the reply
    /// is delivered without waiting for a frame.
    case advanceImmediately
}

/// Cross-platform overlay clipboard receive coordinator matching `overlay/input.rs::clipboard_due` (`#1249`).
public enum OverlayClipboardSync {
    /// Decides how an overlay in `presence` handles a clipboard receive check.
    public static func action(received: Bool, presence: OverlayPresence) -> OverlayClipboardDueAction {
        guard received else { return .none }
        return presence.isFrameless ? .advanceImmediately : .deferToNextFrame
    }

    /// Delivers clipboard replies or secret-copy changes to `runtime`.
    ///
    /// A shown or fading-out (non-frameless) overlay marks `dirty = true` and leaves stepping
    /// to its next drawn frame; a hidden or occluded (frameless) overlay advances immediately.
    @discardableResult
    public static func receiveDue<State>(
        runtime: Runtime<State>,
        presence: OverlayPresence,
        dirty: inout Bool,
        at now: Double = 0,
        receive: (Runtime<State>) -> Bool,
        advance: ((Runtime<State>, Double) -> Void)? = nil
    ) -> OverlayClipboardDueAction {
        let didReceive = receive(runtime)
        let decision = action(received: didReceive, presence: presence)
        switch decision {
        case .none:
            return .none
        case .deferToNextFrame:
            dirty = true
            return .deferToNextFrame
        case .advanceImmediately:
            dirty = true
            if let advance {
                advance(runtime, now)
            } else {
                _ = runtime.frame(at: now)
            }
            return .advanceImmediately
        }
    }
}

public extension OverlayHandle {
    /// Delivers a clipboard reply (paste, `Tx.readClipboard` answer, or secret-copy change) to
    /// this overlay (`overlay/input.rs::clipboard_due`, `#1249`).
    ///
    /// When the overlay is shown or fading out (non-frameless), this marks work pending and wakes
    /// the host without advancing the runtime so the next drawn frame steps once. When hidden or
    /// occluded (frameless), it advances immediately so the reply is delivered without a frame.
    @discardableResult
    func receiveClipboardDue(
        at now: Double = Date().timeIntervalSinceReferenceDate,
        receive: (Runtime<State>) -> Bool
    ) -> OverlayClipboardDueAction {
        let (decision, wake): (OverlayClipboardDueAction, Bool) = withLockedRuntime { rt in
            let didReceive = receive(rt)
            let decision = OverlayClipboardSync.action(received: didReceive, presence: overlayPresence)
            switch decision {
            case .none:
                return (.none, false)
            case .deferToNextFrame:
                rt.markNeedsCommit(settle: false)
                return (.deferToNextFrame, true)
            case .advanceImmediately:
                _ = rt.frame(at: now)
                return (.advanceImmediately, false)
            }
        }
        if wake {
            runtime.waker.wake()
        }
        return decision
    }
}
