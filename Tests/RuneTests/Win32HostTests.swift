import Testing
import RuneMotion
@testable import Rune

@Suite("Win32 native input routing")
@MainActor
struct Win32HostTests {
    struct Keys {
        var down: [KeyEvent] = []
        var up: [KeyEvent] = []
    }

    @Test func nativePopupShortcutsUseLayoutGlyphsAndNamedVirtualKeys() throws {
        let mods = Win32KeyMap.modifiers(1 | 2)
        let plus = try #require(Win32KeyMap.shortcutKey(virtualKey: 0xbb, scalar: "+", mods: mods))
        #expect(try Chord.parse("mod++").matches(KeyEvent(key: plus, mods: mods), on: .windows))
        #expect(Win32KeyMap.shortcutKey(virtualKey: 0x41, scalar: "q", mods: .none) == .text("q"))
        #expect(Win32KeyMap.shortcutKey(virtualKey: 0x28, scalar: nil, mods: .none) == .arrowDown)
        #expect(Win32KeyMap.shortcutKey(virtualKey: 0x09, scalar: "\t", mods: .none) == .tab)
    }

    private func keyboardRuntime() -> Runtime<Keys> {
        let runtime = Runtime(state: Keys(), viewport: Vec2(200, 100), pixelScale: 1, onKey: { state, key, _ in
            state.down.append(key)
            return true
        }) { _, _ in
            col().size(200, 100).onKeyUp { state, key, _ in
                state.up.append(key)
                return true
            }
        }
        _ = runtime.frame(at: 0)
        return runtime
    }

    @Test func printableKeysComeFromTheActiveLayoutAndReleaseTheSameKey() {
        let keyboard = Win32Keyboard()
        let runtime = keyboardRuntime()
        // A French layout sends VK_A for the switch at the US Q position (scan 0x10).
        #expect(!keyboard.key(vk: 0x41, scan: 0x10, down: true, repeated: false,
                              mods: .none, altGr: false, to: runtime, at: 0.1))
        #expect(runtime.state.down.isEmpty)
        #expect(keyboard.character(0x61, scan: 0x10, mods: .none, altGr: false,
                                   repeated: false, to: runtime, at: 0.11))
        #expect(keyboard.key(vk: 0x41, scan: 0x10, down: false, repeated: false,
                             mods: .none, altGr: false, to: runtime, at: 0.12))
        #expect(runtime.state.down.map(\.key) == [.text("a")])
        #expect(runtime.state.up.map(\.key) == [.text("a")])
    }

    @Test func shortcutsAltGrAndSurrogatePairsDoNotDuplicateText() {
        let runtime = keyboardRuntime()
        let keyboard = Win32Keyboard()
        let ctrl = Mods(ctrl: true)
        #expect(keyboard.key(vk: 0x4b, scan: 0x25, down: true, repeated: false,
                             mods: ctrl, altGr: false, to: runtime, at: 0.1))
        #expect(!keyboard.character(11, scan: 0x25, mods: ctrl, altGr: false,
                                    repeated: false, to: runtime, at: 0.11))
        // VK_OEM_2 is layout-dependent; the keyboard driver resolves its shortcut character.
        #expect(keyboard.key(vk: 0xbf, scan: 0x35, down: true, repeated: false,
                             mods: ctrl, altGr: false, layoutCharacter: "/", to: runtime, at: 0.15))
        let altGr = Mods(ctrl: true, alt: true)
        #expect(!keyboard.key(vk: 0x45, scan: 0x12, down: true, repeated: false,
                              mods: altGr, altGr: true, to: runtime, at: 0.2))
        #expect(keyboard.character(0x20ac, scan: 0x12, mods: altGr, altGr: true,
                                   repeated: false, to: runtime, at: 0.21))
        for unit in "🚀".utf16 {
            #expect(keyboard.character(unit, scan: 0, mods: .none, altGr: false,
                                       repeated: false, to: runtime, at: 0.3))
        }
        #expect(runtime.state.down == [
            KeyEvent(key: .command("k"), mods: ctrl),
            KeyEvent(key: .command("/"), mods: ctrl),
            KeyEvent(key: .text("€")),
            KeyEvent(key: .text("🚀"))
        ])
    }

    @Test func ctrlPlusUsesTheShiftedGlyphAndAltGrBypassesMenuShortcuts() throws {
        let keyboard = Win32Keyboard()
        let runtime = keyboardRuntime()
        let mods = Mods(shift: true, ctrl: true)
        // US Ctrl+Shift+= produces no printable WM_CHAR. Rune and keysFirst menus must
        // both see the "+" at WM_KEYDOWN while physical input retains its "=" base.
        #expect(keyboard.key(vk: 0xbb, scan: 0x0d, down: true, repeated: false,
                             mods: mods, altGr: false, layoutCharacter: "=", shortcutCharacter: "+",
                             to: runtime, at: 0.1))
        let event = try #require(runtime.state.down.last)
        #expect(event == KeyEvent(key: .command("+"), mods: mods))
        #expect(try Chord.parse("mod++").matches(event, on: .windows))

        var offeredToMenu = false
        #expect(keyboard.character(0x20ac, scan: 0x12, mods: Mods(ctrl: true, alt: true), altGr: true,
                                   repeated: false, to: runtime, at: 0.2) { _, _ in
            offeredToMenu = true
            return true
        })
        #expect(!offeredToMenu)
        #expect(runtime.state.down.last == KeyEvent(key: .text("€")))
    }
}
