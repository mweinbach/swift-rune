import Testing
@testable import Rune

struct LinuxDesktopKeyTests {
    @Test func scancodesAndLayoutKeysRemainIndependent() {
        // Physical Q on AZERTY reports "a", and Rune must retain both identities.
        #expect(LinuxDesktopKey.physical(20) == .keyQ)
        #expect(LinuxDesktopKey.logical(97, mods: .none) == .text("a"))
        #expect(LinuxDesktopKey.logical(97, mods: Mods(ctrl: true)) == .command("a"))
        #expect(LinuxDesktopKey.physical(230) == .altRight)
        #expect(LinuxDesktopKey.logical(0x40000058, mods: .none) == .enter)
        #expect(LinuxDesktopKey.physical(88) == .numpadEnter)
        #expect(LinuxDesktopKey.logical(0x40000073, mods: .none) == .f(24))
        #expect(LinuxDesktopKey.logical(0x400000e6, mods: .none) == nil)
    }

    @Test func compositionSelectionUsesRuneByteOffsets() {
        #expect(LinuxDesktopKey.preeditSelection(in: "é界😄", start: 1, length: 2) == 2..<9)
        #expect(LinuxDesktopKey.preeditSelection(in: "é界😄", start: 20, length: 4) == 9..<9)
        #expect(LinuxDesktopKey.preeditSelection(in: "é界😄", start: -1, length: 0) == nil)
        #expect(LinuxDesktopKey.preeditSelection(in: "स्ते", start: 4, length: -1) == 12..<12)
    }
}
