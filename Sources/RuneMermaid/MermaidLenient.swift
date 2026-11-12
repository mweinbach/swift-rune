import Foundation

protocol LenientParser {
    associatedtype Mark
    func mark() -> Mark
    mutating func undo(_ mark: Mark)
    mutating func readStatement(_ s: String) -> Bool
    func isOverLimit() -> Bool
}

struct LenientReader {
    private var skipping: Int = 0

    mutating func read<P: LenientParser>(_ parser: inout P, statement s: String) -> Bool {
        if skipping > 0 {
            if s == "}" {
                skipping -= 1
            } else if s.hasSuffix("{") {
                skipping += 1
            }
            return true
        }
        let m = parser.mark()
        if !parser.readStatement(s) {
            if parser.isOverLimit() {
                return false
            }
            parser.undo(m)
            if s.hasSuffix("{") {
                skipping = 1
            }
        }
        return true
    }
}
