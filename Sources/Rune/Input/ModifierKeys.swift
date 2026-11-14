import Foundation

/// Tracks standalone modifier key presses and releases (`crates/rune/src/runtime/input/modifier_keys.rs`),
/// emitting side-specific `Key.modifier(_:pressed:)` events in physical queue order after `onPhysicalInput` declines them.
public struct ModifierKeysState: Sendable {
    public static let allModifiers: [ModifierKey] = [
        .shiftLeft, .shiftRight,
        .controlLeft, .controlRight,
        .altLeft, .altRight,
        .superLeft, .superRight,
        .fn,
    ]

    public var enabled: Bool = false
    /// Bit `i` set while `allModifiers[i]` is physically held.
    public var heldMask: UInt16 = 0
    /// Last seen `Mods` from `PhysicalInput.modifiers(_)` to synthesize releases when a flag turns off.
    public var lastMods: Mods = .none
    /// Whether queued modifier events are waiting to run.
    public var hasQueuedEvents: Bool = false

    #if os(windows)
    public static let altGrClearsFlagsDefault = true
    #else
    public static let altGrClearsFlagsDefault = false
    #endif

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }

    public static func modifier(for code: PhysicalKeyCode) -> ModifierKey? {
        switch code {
        case .shiftLeft: return .shiftLeft
        case .shiftRight: return .shiftRight
        case .controlLeft: return .controlLeft
        case .controlRight: return .controlRight
        case .altLeft: return .altLeft
        case .altRight: return .altRight
        case .superLeft: return .superLeft
        case .superRight: return .superRight
        case .fn: return .fn
        default: return nil
        }
    }

    public static func bit(_ m: ModifierKey) -> UInt16 {
        let idx = allModifiers.firstIndex(of: m) ?? 0
        return UInt16(1) << UInt16(idx)
    }

    public static func pair(_ m: ModifierKey) -> UInt16 {
        switch m {
        case .shiftLeft, .shiftRight: return bit(.shiftLeft) | bit(.shiftRight)
        case .controlLeft, .controlRight: return bit(.controlLeft) | bit(.controlRight)
        case .altLeft, .altRight: return bit(.altLeft) | bit(.altRight)
        case .superLeft, .superRight: return bit(.superLeft) | bit(.superRight)
        case .fn: return bit(.fn)
        }
    }

    public static func isActive(_ mods: Mods, for m: ModifierKey) -> Bool {
        switch m {
        case .shiftLeft, .shiftRight: return mods.shift
        case .controlLeft, .controlRight: return mods.ctrl
        case .altLeft, .altRight: return mods.alt
        case .superLeft, .superRight: return mods.logo
        case .fn: return false
        }
    }

    public static func withModifier(_ mods: Mods, _ m: ModifierKey, on: Bool) -> Mods {
        var copy = mods
        switch m {
        case .shiftLeft, .shiftRight:
            copy.shift = on
        case .controlLeft, .controlRight:
            copy.ctrl = on
            #if !(os(macOS) || os(iOS) || os(tvOS) || os(visionOS))
            copy.cmd = on
            #endif
        case .altLeft, .altRight:
            copy.alt = on
        case .superLeft, .superRight:
            copy.logo = on
            #if os(macOS) || os(iOS) || os(tvOS) || os(visionOS)
            copy.cmd = on
            #endif
        case .fn:
            break
        }
        return copy
    }

    private func makeEvent(_ m: ModifierKey, pressed: Bool, mods: Mods) -> KeyEvent {
        let stillHeld = (heldMask & Self.pair(m)) != 0
        return KeyEvent(
            key: .modifier(m, pressed: pressed),
            mods: Self.withModifier(mods, m, on: stillHeld)
        )
    }

    /// Computes `(pressedMask, releasedMask)` without mutating state.
    public func changes(for event: PhysicalInput, altGrClearsFlags: Bool = altGrClearsFlagsDefault) -> (UInt16, UInt16) {
        guard enabled else { return (0, 0) }
        switch event {
        case .key(let code, _, let pressed, let isRepeat):
            guard let m = Self.modifier(for: code),
                  !isRepeat,
                  ((heldMask & Self.bit(m)) != 0) != pressed else {
                return (0, 0)
            }
            return pressed ? (Self.bit(m), 0) : (0, Self.bit(m))
        case .modifiers(let now):
            let altGr = altGrClearsFlags && (heldMask & Self.bit(.altRight)) != 0
            var released: UInt16 = 0
            for m in Self.allModifiers {
                let clearedByAltGr: Bool
                switch m {
                case .controlLeft, .controlRight, .altLeft, .altRight:
                    clearedByAltGr = altGr
                default:
                    clearedByAltGr = false
                }
                if (heldMask & Self.bit(m)) != 0,
                   Self.isActive(lastMods, for: m),
                   !Self.isActive(now, for: m),
                   !clearedByAltGr {
                    released |= Self.bit(m)
                }
            }
            return (0, released)
        case .focusLost:
            return (0, heldMask)
        }
    }

    public func isPending(_ event: PhysicalInput) -> Bool {
        changes(for: event) != (0, 0)
    }

    /// Updates held state and returns `KeyEvent`s to dispatch (none if a physical handler consumed the event).
    @discardableResult
    public mutating func apply(
        _ event: PhysicalInput,
        consumed: Bool,
        altGrClearsFlags: Bool = altGrClearsFlagsDefault
    ) -> [KeyEvent] {
        let (pressed, released) = changes(for: event, altGrClearsFlags: altGrClearsFlags)
        let baseMods: Mods
        switch event {
        case .key(_, let mods, _, _):
            baseMods = mods
        case .modifiers(let now):
            lastMods = now
            baseMods = now
        case .focusLost:
            lastMods = .none
            baseMods = .none
        }
        var out: [KeyEvent] = []
        for m in Self.allModifiers {
            let b = Self.bit(m)
            if (pressed & b) != 0, !consumed {
                heldMask |= b
                out.append(makeEvent(m, pressed: true, mods: baseMods))
            } else if (released & b) != 0 {
                heldMask &= ~b
                if !consumed {
                    out.append(makeEvent(m, pressed: false, mods: baseMods))
                }
            }
        }
        return out
    }
}

extension Runtime {
    /// Enables or disables standalone `Key.modifier(_:pressed:)` delivery (`Runtime::set_modifier_keys`).
    public func setModifierKeys(_ enabled: Bool) {
        if inputMachines.modifierKeys.enabled != enabled {
            inputMachines.modifierKeys.heldMask = 0
        }
        inputMachines.modifierKeys.enabled = enabled
    }

    /// Whether standalone modifier key events are delivered (`Runtime::modifier_keys`).
    public func modifierKeys() -> Bool {
        inputMachines.modifierKeys.enabled
    }

    /// Queues a synthetic focus-lost physical input (e.g. window hidden or deactivated) (`Runtime::keys_lost`).
    @discardableResult
    public func keysLost(at now: Double? = nil) -> Bool {
        inputMachines.pendingKeysLost = true
        inputMachines.pendingKeysLostTime = now
        let queued = (inputMachines.modifierKeys.enabled && inputMachines.modifierKeys.heldMask != 0)
            || (focusedPath != nil)
        inputMachines.modifierKeys.hasQueuedEvents = queued
        return queued
    }

    internal func flushPendingKeysLost(at now: Double) {
        guard inputMachines.pendingKeysLost else { return }
        inputMachines.pendingKeysLost = false
        let t = inputMachines.pendingKeysLostTime ?? now
        inputMachines.pendingKeysLostTime = nil
        _ = physicalWithFallback(.focusLost, fallbackKey: nil, at: t)
    }

    /// Whether modifier/key events are queued for delivery (`Runtime::keys_queued`).
    public var keysQueued: Bool {
        inputMachines.modifierKeys.hasQueuedEvents
    }

    /// Action run only when no physical, focused, or global key handler consumes a key (`Unhandled::Menu`, `physical.rs:639`).
    public enum UnhandledKeyAction {
        case menu(() -> Void)
    }

    /// Dispatches physical input with optional fallback key and `UnhandledKeyAction` menu fallback (`Runtime::physical_then`).
    @discardableResult
    public func physicalThen(
        _ event: PhysicalInput,
        fallbackKey: KeyEvent? = nil,
        unhandled: UnhandledKeyAction? = nil,
        at now: Double = 0
    ) -> Bool {
        let took = physicalWithFallback(event, fallbackKey: fallbackKey, at: now)
        if !took, case .menu(let run)? = unhandled {
            run()
            return true
        }
        return took
    }

    /// Dispatches physical input, standalone modifier events, and optional logical key fallback (`Runtime::physical_with_fallback`).
    @discardableResult
    public func physicalWithFallback(
        _ event: PhysicalInput,
        fallbackKey: KeyEvent? = nil,
        at now: Double = 0
    ) -> Bool {
        currentTime = now
        if case .focusLost = event, flatNodes.isEmpty {
            inputMachines.currentMods = .none
            inputMachines.focusMachine.suppressedRepeatPhysicalKeys.removeAll()
            inputMachines.focusMachine.pendingPhysicalFocusCheck = nil
            dirChord = .idle
            _ = inputMachines.modifierKeys.apply(.focusLost, consumed: true)
            inputMachines.modifierKeys.hasQueuedEvents = false
            return false
        }
        flushPendingCommitIfNeeded(at: now)
        var pressFocusBefore: String? = nil
        var isNewKeyPressCode: PhysicalKeyCode? = nil
        switch event {
        case .modifiers(let mods):
            inputMachines.currentMods = mods
        case .key(let code, let mods, let pressed, let isRepeat):
            inputMachines.currentMods = mods
            if !pressed {
                inputMachines.focusMachine.suppressedRepeatPhysicalKeys.remove(code)
                if inputMachines.physicalLogicalKeys[code] == inputMachines.focusMachine.suppressedRepeatKey {
                    inputMachines.focusMachine.suppressedRepeatKey = nil
                }
                if inputMachines.focusMachine.pendingPhysicalFocusCheck?.code == code {
                    inputMachines.focusMachine.pendingPhysicalFocusCheck = nil
                }
            } else if isRepeat {
                if inputMachines.focusMachine.suppressedRepeatPhysicalKeys.contains(code) {
                    return true
                }
            } else {
                inputMachines.focusMachine.suppressedRepeatPhysicalKeys.remove(code)
                pressFocusBefore = focusedPath
                isNewKeyPressCode = code
            }
        case .focusLost:
            inputMachines.currentMods = .none
            inputMachines.focusMachine.suppressedRepeatPhysicalKeys.removeAll()
            inputMachines.focusMachine.pendingPhysicalFocusCheck = nil
        }
        let handledByPhysical = dispatchPhysicalInputOnly(event, at: now)
        let modEvents = inputMachines.modifierKeys.apply(event, consumed: handledByPhysical)
        var modHandled = false
        for ev in modEvents {
            if routeModifierKey(ev, at: now) {
                modHandled = true
            }
        }
        inputMachines.modifierKeys.hasQueuedEvents = false

        let recordFocusShiftSuppression: () -> Void = {
            if let code = isNewKeyPressCode {
                if self.focusedPath != pressFocusBefore {
                    self.inputMachines.focusMachine.suppressedRepeatPhysicalKeys.insert(code)
                } else if self.needsCommit {
                    self.inputMachines.focusMachine.pendingPhysicalFocusCheck = PendingPhysicalFocusCheck(
                        code: code,
                        key: fallbackKey?.key,
                        beforeFocus: pressFocusBefore
                    )
                }
            }
        }

        if handledByPhysical {
            if case .key(let code, _, let pressed, _) = event,
               !pressed,
               ModifierKeysState.modifier(for: code) == nil {
                // Even if consumed or ignored above, clear stale mapping on release.
                inputMachines.physicalLogicalKeys.removeValue(forKey: code)
            }
            recordFocusShiftSuppression()
            return true
        }

        // Physical direction chord (Ctrl+LeftShift / Ctrl+RightShift)
        if case .key(let physCode, let mods, let pressed, let isRepeat) = event, !isRepeat {
            if let modKey = ModifierKeysState.modifier(for: physCode) {
                let (nextChord, flow) = stepDirChord(
                    dirChord,
                    modifier: modKey,
                    pressed: pressed,
                    ctrl: mods.ctrl,
                    shift: mods.shift
                )
                dirChord = nextChord
                if let flow,
                   let fPath = focusedPath,
                   let fIdx = nodeByPath[fPath],
                   let editLens = flatNodes[fIdx].el.handlers.editLens {
                    var edit = editLens.get(state)
                    edit.forceDir(flow)
                    editLens.set(&state, edit)
                    dirtyCommit(at: now)
                    recordFocusShiftSuppression()
                    return true
                }
            } else if pressed {
                dirChord = .idle
            }
        }

        // Handle physical key release routing via KeyReleases (`gesture.rs:313`).
        if case .key(let code, _, let pressed, let isRepeat) = event {
            if pressed {
                if let fallbackKey, !isRepeat {
                    inputMachines.physicalLogicalKeys[code] = fallbackKey.key
                }
                if let fallbackKey {
                    let prevPhys = inputMachines.activePhysicalKey
                    inputMachines.activePhysicalKey = code
                    defer { inputMachines.activePhysicalKey = prevPhys }
                    let took = keyDown(fallbackKey, isRepeat: isRepeat, at: now)
                    recordFocusShiftSuppression()
                    return took
                }
                recordFocusShiftSuppression()
                return modHandled || !modEvents.isEmpty
            } else {
                inputMachines.physicalLogicalKeys.removeValue(forKey: code)
                if let logical = fallbackKey {
                    if inputMachines.keyReleases.eat(composing: isAnyImeComposing) {
                        return false
                    }
                    let prevPhys = inputMachines.activePhysicalKey
                    inputMachines.activePhysicalKey = code
                    defer { inputMachines.activePhysicalKey = prevPhys }
                    return keyUp(logical, fromPhysicalRelease: true, at: now)
                }
                return modHandled || !modEvents.isEmpty
            }
        }

        if let fallbackKey {
            return keyDown(fallbackKey, at: now)
        }
        return modHandled || !modEvents.isEmpty
    }

    internal func routeModifierKey(_ ev: KeyEvent, at now: Double) -> Bool {
        guard inputMachines.modifierKeys.enabled else { return false }
        let appFirst = (focusedPath == nil)
        if appFirst, activeModalPath == nil, let hook = globalOnKey {
            var tx = makeTx(at: now)
            if Tx.took(hook(&state, ev, &tx), &tx) {
                applyTx(tx, at: now)
                return true
            }
        }
        if let fPath = focusedPath, let fIdx = nodeByPath[fPath] {
            var walkIdx: Int? = fIdx
            while let curIdx = walkIdx {
                if flatNodes[curIdx].effectiveInert { break }
                if let elOnKey = flatNodes[curIdx].el.handlers.onKey {
                    var tx = makeTx(at: now)
                    if elOnKey(&state, ev, &tx) {
                        applyTx(tx, at: now)
                        return true
                    }
                }
                if flatNodes[curIdx].el.isModal { break }
                walkIdx = flatNodes[curIdx].parentIndex
            }
            if let onInputKey = flatNodes[fIdx].el.handlers.onInputKey {
                var tx = makeTx(at: now)
                if Tx.took(onInputKey(&state, ev, &tx), &tx) {
                    applyTx(tx, at: now)
                    return true
                }
            }
        }
        if !appFirst, activeModalPath == nil, let hook = globalOnKey {
            var tx = makeTx(at: now)
            if Tx.took(hook(&state, ev, &tx), &tx) {
                applyTx(tx, at: now)
                return true
            }
        }
        if case .modifier(_, pressed: false) = ev.key {
            return keyUp(ev, at: now)
        }
        return false
    }
}
