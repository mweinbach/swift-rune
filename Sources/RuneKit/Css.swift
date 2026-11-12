import Foundation
import Rune

/// Helpers for parsing web-authored CSS values (`rune_kit::css`).
public enum KitCSS {
    /// Parses a computed CSS `box-shadow` list (`#rrggbbaa 0px 1px 1.5px 0px [inset], ...`).
    /// Colors are passed through `colorTransform`; fully transparent layers are dropped.
    public static func boxShadows(
        _ source: String,
        colorTransform: (Color) -> Color = { $0 }
    ) -> [Shadow] {
        var result: [Shadow] = []
        for layer in splitLayers(source) {
            guard !layer.isEmpty else { continue }
            var parsedColor: Color?
            var numbers: [Float] = []
            var inset = false

            for token in layer.split(whereSeparator: \.isWhitespace) {
                let tok = String(token)
                if tok == "inset" {
                    inset = true
                } else if tok.hasPrefix("#") {
                    parsedColor = Color.hex(tok)
                } else {
                    let numericStr = tok.hasSuffix("px") ? String(tok.dropLast(2)) : tok
                    if let val = Float(numericStr) {
                        numbers.append(val)
                    }
                }
            }

            guard let c = parsedColor, c.a > 0.0 else { continue }
            let x: Float = numbers.count > 0 ? numbers[0] : 0
            let y: Float = numbers.count > 1 ? numbers[1] : 0
            let blur: Float = numbers.count > 2 ? numbers[2] : 0
            let spread: Float = numbers.count > 3 ? numbers[3] : 0
            result.append(Shadow(x: x, y: y, blur: blur, spread: spread, color: colorTransform(c), inset: inset))
        }
        return result
    }

    /// Parses a CSS length value in `px` or unitless float.
    public static func px(_ token: String) -> Float? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("px") {
            return Float(trimmed.dropLast(2))
        }
        return Float(trimmed)
    }

    private static func splitLayers(_ source: String) -> [String] {
        var depth = 0
        var start = source.startIndex
        var out: [String] = []
        for idx in source.indices {
            switch source[idx] {
            case "(":
                depth += 1
            case ")":
                depth = max(0, depth - 1)
            case "," where depth == 0:
                out.append(String(source[start..<idx]).trimmingCharacters(in: .whitespacesAndNewlines))
                start = source.index(after: idx)
            default:
                break
            }
        }
        out.append(String(source[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        return out
    }
}
