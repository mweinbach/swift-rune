import Foundation

/// Errors thrown while loading a JSON theme (`rune::theme::Theme::from_json`).
public enum ThemeError: Error, LocalizedError, Equatable, Sendable {
    case invalidUTF8
    case invalidRoot
    case missingMode(String)
    case invalidColor(token: String, value: String)
    case invalidBlend(String)

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: return "Theme JSON is not valid UTF-8"
        case .invalidRoot: return "Theme JSON root must be an object"
        case .missingMode(let mode): return "Theme JSON missing appearance '\(mode)'"
        case .invalidColor(let token, let value): return "Invalid color '\(value)' for token '\(token)'"
        case .invalidBlend(let msg): return "Invalid blend section: \(msg)"
        }
    }
}

/// Alias matching upstream `rune::theme::Theme` (`rune::Theme`).
public typealias Theme = JsonTheme

private enum BlendScopeStorage {
    @TaskLocal static var srgbBlend: Bool = true
}

extension JsonTheme {
    /// Whether the current view/runtime builds for gamma-space (`srgb`) blending.
    ///
    /// Defaults to `true` outside a runtime or `withBlend` scope, matching `rune::theme::blends_srgb()`.
    public static func blendsSrgb() -> Bool {
        BlendScopeStorage.srgbBlend
    }

    /// Runs `body` with `blendsSrgb()` set to `srgbBlend`, restoring the previous mode on exit.
    public static func withBlend<R>(_ srgbBlend: Bool, _ body: () throws -> R) rethrows -> R {
        try BlendScopeStorage.$srgbBlend.withValue(srgbBlend, operation: body)
    }

    /// Adapts `color` for compositing over opaque `bg` under the active `blendsSrgb()` mode.
    public static func forBlend(_ color: Color, over bg: Color) -> Color {
        blendsSrgb() ? color : color.srgbEquivalent(over: bg)
    }

    /// Solves for the straight-alpha linear color that reproduces sRGB blending of `color` over `bg`.
    public static func srgbEquivalent(_ color: Color, over bg: Color) -> Color {
        color.srgbEquivalent(over: bg)
    }

    /// Returns `color` at opacity `a`, re-solved when blending linearly and `blendBg` is set.
    public func alpha(_ color: Color, _ a: Float) -> Color {
        blended(color.alpha(a))
    }

    private func blended(_ color: Color) -> Color {
        if let bg = blendBg {
            return Self.forBlend(color, over: bg)
        }
        return color
    }

    /// Looks up a color token adapted for the active blend mode (`blendsSrgb()`), or `nil` if absent.
    public func tryColor(_ key: String) -> Color? {
        guard let authored = colors[key] else { return nil }
        return blended(authored)
    }

    /// Looks up a color token adapted for the active blend mode (`blendsSrgb()`), returning `.transparent` if missing.
    public func color(_ key: String) -> Color {
        tryColor(key) ?? .transparent
    }

    /// Returns the authored, unadapted color token if present.
    public func rawColor(_ key: String) -> Color? {
        colors[key]
    }
}

extension Color {
    /// Parses `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb(...)`, or `rgba(...)` CSS colors.
    public static func css(_ raw: String) -> Color? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#"), let hexColor = Color.hex(trimmed) {
            return hexColor
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("rgba(") && lower.hasSuffix(")") {
            return parseCSSRGBBody(String(trimmed.dropFirst(5).dropLast()))
        }
        if lower.hasPrefix("rgb(") && lower.hasSuffix(")") {
            return parseCSSRGBBody(String(trimmed.dropFirst(4).dropLast()))
        }
        return nil
    }

    private static func parseCSSRGBBody(_ body: String) -> Color? {
        let normalized = body.replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: ",", with: " ")
        let parts = normalized.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }

        func parseChannel(_ token: String) -> Float? {
            if token.hasSuffix("%"), let p = Float(token.dropLast()) {
                return (p / 100.0).clamped(to: 0...1)
            }
            guard let v = Float(token) else { return nil }
            return (v / 255.0).clamped(to: 0...1)
        }

        func parseAlpha(_ token: String) -> Float? {
            if token.hasSuffix("%"), let p = Float(token.dropLast()) {
                return (p / 100.0).clamped(to: 0...1)
            }
            return Float(token)?.clamped(to: 0...1)
        }

        guard let r = parseChannel(parts[0]),
              let g = parseChannel(parts[1]),
              let b = parseChannel(parts[2]) else {
            return nil
        }
        let a: Float
        if parts.count == 4 {
            guard let parsedA = parseAlpha(parts[3]) else { return nil }
            a = parsedA
        } else {
            a = 1.0
        }
        return Color.srgb(r, g, b, a)
    }
}

enum JsonThemeParser {
    static func parse(data: Data, dark: Bool) throws -> JsonTheme {
        let raw = try JSONSerialization.jsonObject(with: data, options: [])
        guard let root = raw as? [String: Any] else {
            throw ThemeError.invalidRoot
        }

        let name = (root["name"] as? String) ?? "custom"
        let palette = (root["palette"] as? [String: Any]) ?? [:]
        let defs = (root["defs"] as? [String: Any]) ?? [:]

        // Support both upstream `"light"` / `"dark"` top-level schema and `"theme"` + `"defs"` schema.
        let modeDict: [String: Any]
        if root["dark"] != nil || root["light"] != nil {
            let modeKey = dark ? "dark" : "light"
            if let d = root[modeKey] as? [String: Any] {
                modeDict = d
            } else if let fallback = root[dark ? "light" : "dark"] as? [String: Any] {
                modeDict = fallback
            } else {
                throw ThemeError.missingMode(modeKey)
            }
        } else if let t = root["theme"] as? [String: Any] {
            modeDict = t
        } else {
            modeDict = root
        }

        func resolve(
            _ value: Any?,
            visited: inout Set<String>,
            depth: Int = 0
        ) -> Color? {
            guard depth < 16 else { return nil }
            if let str = value as? String {
                if let literal = Color.css(str) {
                    return literal
                }
                let refKey = str.hasPrefix("$") ? String(str.dropFirst()) : str

                if let palVal = palette[refKey], !visited.contains("pal:\(refKey)") {
                    visited.insert("pal:\(refKey)")
                    defer { visited.remove("pal:\(refKey)") }
                    if let c = resolve(palVal, visited: &visited, depth: depth + 1) {
                        return c
                    }
                }
                if let defVal = defs[refKey], !visited.contains("def:\(refKey)") {
                    visited.insert("def:\(refKey)")
                    defer { visited.remove("def:\(refKey)") }
                    if let c = resolve(defVal, visited: &visited, depth: depth + 1) {
                        return c
                    }
                }
                if let modeVal = modeDict[refKey], !visited.contains("mode:\(refKey)") {
                    visited.insert("mode:\(refKey)")
                    defer { visited.remove("mode:\(refKey)") }
                    if let c = resolve(modeVal, visited: &visited, depth: depth + 1) {
                        return c
                    }
                }
                return nil
            } else if let variants = value as? [String: Any] {
                let picked = dark ? (variants["dark"] ?? variants["light"]) : (variants["light"] ?? variants["dark"])
                return resolve(picked, visited: &visited, depth: depth + 1)
            }
            return nil
        }

        var resolved: [String: Color] = [:]
        var resolvedNums: [String: Float] = [:]

        if let numbers = root["numbers"] as? [String: Any] {
            for (k, v) in numbers {
                if let n = v as? NSNumber, !(v is Bool) {
                    resolvedNums[k] = n.floatValue
                }
            }
        }

        let skippedRootKeys: Set<String> = ["defs", "palette", "numbers", "blend", "$schema", "name"]
        for (k, v) in modeDict {
            if skippedRootKeys.contains(k) { continue }
            if let n = v as? NSNumber, !(v is Bool) {
                resolvedNums[k] = n.floatValue
            } else if v is String || v is [String: Any] {
                var visited: Set<String> = ["mode:\(k)"]
                guard let c = resolve(v, visited: &visited) else {
                    let rawDesc = (v as? String) ?? String(describing: v)
                    throw ThemeError.invalidColor(token: k, value: rawDesc)
                }
                resolved[k] = c
            }
        }

        // Insert palette entries not shadowed by mode-specific tokens (theme.rs:124-130).
        for (k, v) in palette where resolved[k] == nil {
            if let s = v as? String, let c = Color.css(s) {
                resolved[k] = c
            }
        }

        var blendBg: Color? = nil
        if let blend = root["blend"] as? [String: Any] {
            let mode = (blend["mode"] as? String)?.lowercased() ?? "srgb"
            if mode == "srgb", let over = blend["over"] as? String {
                if let tok = resolved[over] {
                    blendBg = tok
                } else {
                    var visited: Set<String> = []
                    blendBg = resolve(over, visited: &visited)
                }
            } else if mode != "srgb" && mode != "linear" {
                throw ThemeError.invalidBlend("Unsupported blend mode '\(mode)'")
            }
        }

        return JsonTheme(name: name, dark: dark, colors: resolved, numbers: resolvedNums, blendBg: blendBg)
    }
}
