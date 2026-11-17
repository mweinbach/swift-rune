import Foundation
#if os(macOS)
import AppKit
import Carbon
import CoreFoundation
#endif

// MARK: - Fn (Globe) Key Monitor (crates/rune/src/input/fn_key.rs)

/// Watches `NSEvent.flagsChanged` for the macOS Fn / Globe key (`keyCode == 0x3f`, `1 << 23`).
public final class FnKeyMonitor: @unchecked Sendable {
    public static let keyCodeFn: UInt16 = 0x3f
    public static let flagFunction: UInt = 1 << 23

    private let lock = NSLock()
    private var changes: [Bool] = []
    #if os(macOS)
    private var monitorToken: Any?
    private weak var targetWindow: NSWindow?
    #endif

    public init() {}

    /// Interprets a raw AppKit `flagsChanged` event (`keyCode`, `modifierFlags.rawValue`).
    /// Returns `Some(pressed)` if `keyCode == 0x3f`, else `nil`.
    public static func classifyFlagsChanged(keyCode: UInt16, modifierFlags: UInt) -> Bool? {
        guard keyCode == keyCodeFn else { return nil }
        return (modifierFlags & flagFunction) != 0
    }

    #if os(macOS)
    /// Installs a local `NSEvent` `.flagsChanged` monitor scoped to `window`.
    @MainActor
    public init?(window: NSWindow) {
        self.targetWindow = window
        superInitPlaceholder()
        let token = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            if event.window === self.targetWindow,
               let pressed = Self.classifyFlagsChanged(
                   keyCode: event.keyCode,
                   modifierFlags: event.modifierFlags.rawValue
               ) {
                self.record(pressed: pressed)
            }
            return event
        }
        guard let token else { return nil }
        self.monitorToken = token
    }

    private func superInitPlaceholder() {}

    /// Rebinds monitoring to a new window (e.g. after panel adoption).
    @MainActor
    public func start(on window: NSWindow) -> Bool {
        stop()
        self.targetWindow = window
        let token = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            if event.window === self.targetWindow,
               let pressed = Self.classifyFlagsChanged(
                   keyCode: event.keyCode,
                   modifierFlags: event.modifierFlags.rawValue
               ) {
                self.record(pressed: pressed)
            }
            return event
        }
        self.monitorToken = token
        return token != nil
    }

    public func stop() {
        #if os(macOS)
        let tok: Any?
        lock.lock()
        tok = monitorToken
        monitorToken = nil
        targetWindow = nil
        lock.unlock()
        if let tok {
            if Thread.isMainThread {
                MainActor.assumeIsolated { NSEvent.removeMonitor(tok) }
            } else {
                nonisolated(unsafe) let monitorObj = tok
                DispatchQueue.main.async {
                    NSEvent.removeMonitor(monitorObj)
                }
            }
        }
        #endif
    }

    deinit {
        stop()
    }
    #endif

    /// Feeds a raw `flagsChanged` event tuple (for unit testing or host integration).
    public func handleFlagsChanged(keyCode: UInt16, modifierFlags: UInt) {
        if let pressed = Self.classifyFlagsChanged(keyCode: keyCode, modifierFlags: modifierFlags) {
            record(pressed: pressed)
        }
    }

    public func record(pressed: Bool) {
        lock.lock()
        changes.append(pressed)
        lock.unlock()
    }

    /// Drains recorded `Fn` pressed/released transitions in oldest-first order (`fn_key.rs:48`).
    public func take() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        let out = changes
        changes.removeAll(keepingCapacity: true)
        return out
    }
}

// MARK: - Carbon Keyboard Layout Translation (crates/rune/src/shortcuts/layout_macos.rs)

/// Translates Carbon virtual key codes + Carbon modifiers into display labels (`UCKeyTranslate`).
public enum MacOSKeyboardLayout {
    public static let cmdKeyMask: UInt32 = 1 << 8
    public static let controlKeyMask: UInt32 = 1 << 12

    public typealias ForcedTranslator = @Sendable (UInt32, UInt32) -> String?
    private static let forcedThreadKey = "rune.shortcuts.layout_macos.forced"

    /// Overrides translation on the current thread (test hook matching `layout_macos::force`).
    public static func force(_ translator: ForcedTranslator?) {
        if let translator {
            RuneExecutionContext.locals[forcedThreadKey] = translator
        } else {
            RuneExecutionContext.locals.removeObject(forKey: forcedThreadKey)
        }
    }

    /// Translates `key` with Carbon `modifiers` (`cmdKey`, `shiftKey`, ...), honoring `force(_:)` and main-thread TIS safety.
    public static func label(key: UInt32, modifiers: UInt32) -> String? {
        if let forced = RuneExecutionContext.locals[forcedThreadKey] as? ForcedTranslator {
            return forced(key, modifiers)
        }
        #if os(macOS)
        guard Thread.isMainThread else { return nil }
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let rawProp = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let cfData = unsafeBitCast(rawProp, to: CFData.self)
        guard let bytePtr = CFDataGetBytePtr(cfData) else {
            return nil
        }
        return chordLabel(layout: UnsafeRawPointer(bytePtr), key: key, modifiers: modifiers)
        #else
        return nil
        #endif
    }

    /// Returns the menu label for `key` under Carbon `modifiers` (`cmd` & `control` only, falling back `modifiers -> modifiers & ~control -> 0`, `layout_macos.rs:66`).
    public static func chordLabel(
        layout: UnsafeRawPointer,
        key: UInt32,
        modifiers: UInt32
    ) -> String? {
        #if os(macOS)
        let masked = modifiers & (cmdKeyMask | controlKeyMask)
        for state in [masked, masked & ~controlKeyMask, 0] {
            if let s = translate(layout: layout, key: key, modifiers: state) {
                return s
            }
        }
        return nil
        #else
        _ = (layout, key, modifiers)
        return nil
        #endif
    }

    /// Calls Carbon `UCKeyTranslate` (`kUCKeyActionDisplay`, `kUCKeyTranslateNoDeadKeysMask`) and rejects control characters (`layout_macos.rs:72`).
    public static func translate(
        layout: UnsafeRawPointer,
        key: UInt32,
        modifiers: UInt32
    ) -> String? {
        #if os(macOS)
        var chars = [UniChar](repeating: 0, count: 16)
        var length: Int = 0
        var deadKeyState: UInt32 = 0
        let ucLayout = layout.assumingMemoryBound(to: UCKeyboardLayout.self)
        let status = UCKeyTranslate(
            ucLayout,
            UInt16(truncatingIfNeeded: key),
            UInt16(kUCKeyActionDisplay),
            (modifiers >> 8) & 0xff,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysMask),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0, length <= chars.count else {
            return nil
        }
        let s = String(utf16CodeUnits: chars, count: length)
        let hasControl = s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        return hasControl ? nil : s
        #else
        _ = (layout, key, modifiers)
        return nil
        #endif
    }

    /// Pure modifier fallback cascade (`modifiers -> modifiers & ~control -> 0`) usable on any layout callback (`layout_macos.rs:68`).
    public static func chordLabelCascade(
        key: UInt32,
        modifiers: UInt32,
        translateFn: (UInt32, UInt32) -> String?
    ) -> String? {
        let masked = modifiers & (cmdKeyMask | controlKeyMask)
        for state in [masked, masked & ~controlKeyMask, 0] {
            if let s = translateFn(key, state),
               !s.isEmpty,
               !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                return s
            }
        }
        return nil
    }
}
