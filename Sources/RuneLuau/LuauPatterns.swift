import Foundation

/// Lua 5.1 / Luau pattern matching engine (`find`, `match`, `gmatch`, `gsub`).
internal enum LuauPatternEngine {
    enum Capture {
        case span(start: Int, end: Int)
        case position(Int)
    }

    struct MatchResult {
        let start: Int // 0-based byte offset
        let end: Int   // 0-based exclusive byte offset
        let captures: [String]
        let captureBytes: [[UInt8]]
        let captureSpans: [Capture]
    }

    static func find(in subject: String, pattern: String, initPos: Int = 0, plain: Bool = false) -> MatchResult? {
        find(inBytes: Array(subject.utf8), patternBytes: Array(pattern.utf8), initPos: initPos, plain: plain)
    }

    static func find(inBytes sBytes: [UInt8], patternBytes pBytes: [UInt8], initPos: Int = 0, plain: Bool = false) -> MatchResult? {
        let startIdx = max(0, min(initPos, sBytes.count))
        if plain {
            if pBytes.isEmpty {
                return MatchResult(start: startIdx, end: startIdx, captures: [], captureBytes: [], captureSpans: [])
            }
            guard startIdx + pBytes.count <= sBytes.count else { return nil }
            for i in startIdx...(sBytes.count - pBytes.count) {
                if sBytes[i..<(i + pBytes.count)].elementsEqual(pBytes) {
                    return MatchResult(start: i, end: i + pBytes.count, captures: [], captureBytes: [], captureSpans: [])
                }
            }
            return nil
        }

        let anchored = pBytes.first == UInt8(ascii: "^")
        let pStart = anchored ? 1 : 0

        var sPos = startIdx
        repeat {
            var state = MatchState(s: sBytes, p: pBytes)
            if let endPos = state.match(sPos: sPos, pPos: pStart) {
                var caps: [String] = []
                var capBytes: [[UInt8]] = []
                caps.reserveCapacity(state.captures.count)
                capBytes.reserveCapacity(state.captures.count)
                for cap in state.captures {
                    switch cap {
                    case .span(let a, let b):
                        let slice = Array(sBytes[a..<b])
                        capBytes.append(slice)
                        caps.append(String(decoding: slice, as: UTF8.self))
                    case .position(let pos):
                        let str = String(pos + 1)
                        capBytes.append(Array(str.utf8))
                        caps.append(str)
                    }
                }
                return MatchResult(start: sPos, end: endPos, captures: caps, captureBytes: capBytes, captureSpans: state.captures)
            }
            sPos += 1
        } while !anchored && sPos <= sBytes.count

        return nil
    }

    private struct MatchState {
        let s: [UInt8]
        let p: [UInt8]
        var captures: [Capture] = []
        private var openCaptures: [Int] = [] // indices into `captures` or -1 for position

        init(s: [UInt8], p: [UInt8]) {
            self.s = s
            self.p = p
        }

        mutating func match(sPos: Int, pPos: Int) -> Int? {
            var si = sPos
            var pi = pPos

            while pi < p.count {
                let ch = p[pi]
                if ch == UInt8(ascii: "(") {
                    if pi + 1 < p.count && p[pi + 1] == UInt8(ascii: ")") {
                        captures.append(.position(si))
                        let res = match(sPos: si, pPos: pi + 2)
                        if res == nil {
                            captures.removeLast()
                        }
                        return res
                    } else {
                        let capIdx = captures.count
                        captures.append(.span(start: si, end: si))
                        openCaptures.append(capIdx)
                        let res = match(sPos: si, pPos: pi + 1)
                        if res == nil {
                            captures.removeLast()
                            if openCaptures.last == capIdx {
                                openCaptures.removeLast()
                            }
                        } else if openCaptures.last == capIdx {
                            openCaptures.removeLast()
                        }
                        return res
                    }
                } else if ch == UInt8(ascii: ")") {
                    // Close most recent open span capture
                    guard let openIdx = openCaptures.last(where: {
                        if case .span = captures[$0] { return true }
                        return false
                    }) else {
                        return nil
                    }
                    let oldCap = captures[openIdx]
                    if case .span(let start, _) = oldCap {
                        captures[openIdx] = .span(start: start, end: si)
                    }
                    let savedOpen = openCaptures
                    openCaptures.removeAll { $0 == openIdx }
                    let res = match(sPos: si, pPos: pi + 1)
                    if res == nil {
                        captures[openIdx] = oldCap
                        openCaptures = savedOpen
                    }
                    return res
                } else if ch == UInt8(ascii: "$") && pi + 1 == p.count {
                    return si == s.count ? si : nil
                } else if ch == UInt8(ascii: "%") && pi + 1 < p.count && p[pi + 1] == UInt8(ascii: "b") {
                    guard pi + 3 < p.count, si < s.count, s[si] == p[pi + 2] else { return nil }
                    let open = p[pi + 2]
                    let close = p[pi + 3]
                    var count = 1
                    var cur = si + 1
                    while cur < s.count && count > 0 {
                        if s[cur] == close { count -= 1 }
                        else if s[cur] == open { count += 1 }
                        cur += 1
                    }
                    if count != 0 { return nil }
                    si = cur
                    pi += 4
                } else {
                    let nextPi = classEnd(pi)
                    let m = si < s.count && singleMatch(s[si], pStart: pi, pEnd: nextPi)
                    let quant: UInt8 = nextPi < p.count ? p[nextPi] : 0

                    if quant == UInt8(ascii: "*") || quant == UInt8(ascii: "+") || quant == UInt8(ascii: "?") {
                        if quant == UInt8(ascii: "?") {
                            if m, let res = match(sPos: si + 1, pPos: nextPi + 1) {
                                return res
                            }
                            return match(sPos: si, pPos: nextPi + 1)
                        } else {
                            let minCount = (quant == UInt8(ascii: "+")) ? 1 : 0
                            var maxCount = 0
                            while si + maxCount < s.count && singleMatch(s[si + maxCount], pStart: pi, pEnd: nextPi) {
                                maxCount += 1
                            }
                            if maxCount < minCount { return nil }
                            for k in stride(from: maxCount, through: minCount, by: -1) {
                                if let res = match(sPos: si + k, pPos: nextPi + 1) {
                                    return res
                                }
                            }
                            return nil
                        }
                    } else if quant == UInt8(ascii: "-") {
                        var cur = si
                        while true {
                            if let res = match(sPos: cur, pPos: nextPi + 1) {
                                return res
                            }
                            if cur < s.count && singleMatch(s[cur], pStart: pi, pEnd: nextPi) {
                                cur += 1
                            } else {
                                return nil
                            }
                        }
                    } else {
                        if !m { return nil }
                        si += 1
                        pi = nextPi
                    }
                }
            }
            return si
        }

        private func classEnd(_ pi: Int) -> Int {
            let ch = p[pi]
            if ch == UInt8(ascii: "%") {
                return min(pi + 2, p.count)
            } else if ch == UInt8(ascii: "[") {
                var i = pi + 1
                if i < p.count && p[i] == UInt8(ascii: "^") { i += 1 }
                if i < p.count && p[i] == UInt8(ascii: "]") { i += 1 }
                while i < p.count && p[i] != UInt8(ascii: "]") {
                    if p[i] == UInt8(ascii: "%") && i + 1 < p.count {
                        i += 2
                    } else {
                        i += 1
                    }
                }
                return i < p.count ? i + 1 : p.count
            }
            return pi + 1
        }

        private func singleMatch(_ c: UInt8, pStart: Int, pEnd: Int) -> Bool {
            let ch = p[pStart]
            if ch == UInt8(ascii: ".") { return true }
            if ch == UInt8(ascii: "%") && pStart + 1 < pEnd {
                return matchClass(c, cls: p[pStart + 1])
            }
            if ch == UInt8(ascii: "[") {
                return matchBracketClass(c, pStart: pStart, pEnd: pEnd)
            }
            return c == ch
        }

        private func matchBracketClass(_ c: UInt8, pStart: Int, pEnd: Int) -> Bool {
            var sig = true
            var i = pStart + 1
            if i < pEnd && p[i] == UInt8(ascii: "^") {
                sig = false
                i += 1
            }
            let limit = pEnd - 1
            var matched = false
            while i < limit {
                if p[i] == UInt8(ascii: "%") && i + 1 < limit {
                    i += 1
                    if matchClass(c, cls: p[i]) { matched = true }
                } else if i + 2 < limit && p[i + 1] == UInt8(ascii: "-") {
                    if p[i] <= c && c <= p[i + 2] { matched = true }
                    i += 2
                } else if p[i] == c {
                    matched = true
                }
                i += 1
            }
            return sig ? matched : !matched
        }

        private func matchClass(_ c: UInt8, cls: UInt8) -> Bool {
            let lower = cls | 0x20
            let res: Bool
            switch lower {
            case UInt8(ascii: "a"): res = (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
            case UInt8(ascii: "c"): res = c < 32 || c == 127
            case UInt8(ascii: "d"): res = c >= 48 && c <= 57
            case UInt8(ascii: "l"): res = c >= 97 && c <= 122
            case UInt8(ascii: "p"): res = (c >= 33 && c <= 47) || (c >= 58 && c <= 64) || (c >= 91 && c <= 96) || (c >= 123 && c <= 126)
            case UInt8(ascii: "s"): res = c == 32 || c == 9 || c == 10 || c == 11 || c == 12 || c == 13
            case UInt8(ascii: "u"): res = c >= 65 && c <= 90
            case UInt8(ascii: "w"): res = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122)
            case UInt8(ascii: "x"): res = (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102)
            case UInt8(ascii: "z"): res = c == 0
            default: return c == cls
            }
            return (cls >= 65 && cls <= 90) ? !res : res
        }
    }
}
