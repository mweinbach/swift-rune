import Rune

enum RuneKitTestKey {
    static func primaryMods(shift: Bool = false) -> Mods {
        let command = KeyPlatform.current == .mac
        return Mods(shift: shift, ctrl: !command, cmd: command, logo: command)
    }
}
