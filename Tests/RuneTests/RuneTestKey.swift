import Rune

enum RuneTestKey {
    /// Modifier flags delivered when a user holds Command on Apple hosts or Control elsewhere.
    static func primaryMods(shift: Bool = false) -> Mods {
        let commandKey = KeyPlatform.current == .mac
        return Mods(shift: shift, ctrl: !commandKey, cmd: commandKey, logo: commandKey)
    }
}
