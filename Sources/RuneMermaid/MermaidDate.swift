import Foundation

/// Calendar arithmetic for gantt charts, with no time zones: times are milliseconds from
/// 1970-01-01 00:00. Dates read with a dayjs-style `dateFormat` and print with a d3-style
/// `axisFormat` (`rune_mermaid::date`).
enum MermaidDate {
    static let sec: Double = 1000.0
    static let min: Double = 60.0 * sec
    static let hour: Double = 60.0 * min
    static let day: Double = 24.0 * hour

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        let r = a % b
        return (r != 0 && ((r < 0) != (b < 0))) ? q - 1 : q
    }

    static func remEuclid(_ a: Int64, _ b: Int64) -> Int64 {
        let r = a % b
        return r < 0 ? r + abs(b) : r
    }

    /// Days from 1970-01-01 to `y-m-d` (proleptic Gregorian).
    static func daysFromCivil(_ y: Int64, _ m: Int, _ d: Int) -> Int64 {
        let yAdj = m <= 2 ? y - 1 : y
        let era = floorDiv(yAdj, 400)
        let yoe = yAdj - era * 400
        let mp = Int64((m + 9) % 12)
        let doy = (153 * mp + 2) / 5 + Int64(d) - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civilFromDays(_ zIn: Int64) -> (Int64, Int, Int) {
        let z = zIn + 719_468
        let era = floorDiv(z, 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = Int(doy - (153 * mp + 2) / 5 + 1)
        let m = Int(mp < 10 ? mp + 3 : mp - 9)
        let y = m <= 2 ? (yoe + era * 400 + 1) : (yoe + era * 400)
        return (y, m, d)
    }

    private static func daysInMonth(_ y: Int64, _ m: Int) -> Int {
        switch m {
        case 2 where (y % 4 == 0 && y % 100 != 0) || y % 400 == 0:
            return 29
        case 2:
            return 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    struct Fields {
        var y: Int64
        var mo: Int
        var d: Int
        var h: Int
        var mi: Int
        var s: Int
        var ms: Int
        var wd: Int // 0 = Sunday
    }

    static func fields(_ t: Double) -> Fields {
        let dayNum = floor(t / day)
        let (y, mo, d) = civilFromDays(Int64(dayNum))
        let rest = UInt64(max(t - dayNum * day, 0.0))
        return Fields(
            y: y,
            mo: mo,
            d: d,
            h: Int(rest / UInt64(hour)),
            mi: Int((rest / UInt64(min)) % 60),
            s: Int((rest / UInt64(sec)) % 60),
            ms: Int(rest % 1000),
            wd: Int(remEuclid(Int64(dayNum) + 4, 7))
        )
    }

    private static func at(_ y: Int64, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int, _ ms: Int) -> Double? {
        let ok = (1...12).contains(mo)
            && d >= 1
            && d <= daysInMonth(y, mo)
            && h >= 0 && h < 24
            && mi >= 0 && mi < 60
            && s >= 0 && s < 60
            && (-9999...9999).contains(y)
        guard ok else { return nil }
        return Double(daysFromCivil(y, mo, d)) * day
            + Double(h) * hour
            + Double(mi) * min
            + Double(s) * sec
            + Double(ms)
    }

    private static func addMonths(_ t: Double, _ n: Int64) -> Double {
        let f = fields(t)
        let m0 = f.y * 12 + Int64(f.mo) - 1 + n
        let y = floorDiv(m0, 12)
        let mo = Int(remEuclid(m0, 12)) + 1
        let d = Swift.min(f.d, daysInMonth(y, mo))
        return at(y, mo, d, f.h, f.mi, f.s, f.ms) ?? t
    }

    private static let months = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
    ]
    private static let days = [
        "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
    ]

    static func parse(_ s: String, format: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let v = withFormat(trimmed, format: format) { return v }
        let fallbacks = [
            "YYYY-MM-DDTHH:mm:ss",
            "YYYY-MM-DD HH:mm:ss",
            "YYYY-MM-DDTHH:mm",
            "YYYY-MM-DD HH:mm",
            "YYYY-MM-DD",
        ]
        for f in fallbacks {
            if let v = withFormat(trimmed, format: f) { return v }
        }
        return nil
    }

    private static func withFormat(_ s: String, format: String) -> Double? {
        var y: Int64 = 1970
        var mo = 1
        var d = 1
        var h = 0
        var mi = 0
        var sSec = 0
        var ms = 0
        var pm: Bool? = nil

        var rest = s[...]
        var fIdx = format.startIndex
        let tokens = [
            "YYYY", "MMMM", "MMM", "SSS", "YY", "MM", "DD", "HH", "hh", "mm",
            "ss", "Do", "M", "D", "H", "h", "m", "s", "A", "a",
        ]

        func takeNumber(maxDigits: Int) -> Int64? {
            var count = 0
            var idx = rest.startIndex
            while idx < rest.endIndex && count < maxDigits && rest[idx].isASCII && rest[idx].isNumber {
                count += 1
                idx = rest.index(after: idx)
            }
            guard count > 0, let v = Int64(rest[..<idx]) else { return nil }
            rest = rest[idx...]
            return v
        }

        while fIdx < format.endIndex {
            let ch = format[fIdx]
            if ch == "[" {
                let afterOpen = format.index(after: fIdx)
                let end = format[afterOpen...].firstIndex(of: "]") ?? format.endIndex
                let literal = format[afterOpen..<end]
                guard rest.hasPrefix(literal) else { return nil }
                rest = rest.dropFirst(literal.count)
                fIdx = end < format.endIndex ? format.index(after: end) : format.endIndex
                continue
            }
            if ch == "X" || ch == "x" {
                let neg = rest.hasPrefix("-")
                var digits = neg ? rest.dropFirst() : rest
                if digits.hasPrefix("-") {
                    digits = digits.drop(while: { $0 == "-" })
                }
                var end = digits.startIndex
                while end < digits.endIndex && ((digits[end].isASCII && digits[end].isNumber) || digits[end] == ".") {
                    end = digits.index(after: end)
                }
                guard let raw = Double(digits[..<end]) else { return nil }
                let val = (neg ? -raw : raw) * (ch == "X" ? sec : 1.0)
                let tail = digits[end...].trimmingCharacters(in: .whitespaces)
                return (tail.isEmpty && abs(val) < 2.5e14) ? val : nil
            }

            let fmtTail = format[fIdx...]
            guard let tok = tokens.first(where: { fmtTail.hasPrefix($0) }) else {
                guard rest.first == ch else { return nil }
                rest = rest.dropFirst()
                fIdx = format.index(after: fIdx)
                continue
            }

            switch tok {
            case "YYYY":
                guard let v = takeNumber(maxDigits: 4) else { return nil }
                y = v
            case "YY":
                guard let v = takeNumber(maxDigits: 2) else { return nil }
                y = 2000 + v
            case "MMMM", "MMM":
                let lower = rest.lowercased()
                var matched: (Int, Int)? = nil
                for (k, name) in months.enumerated() {
                    let ln = name.lowercased()
                    if lower.hasPrefix(ln) {
                        matched = (k, ln.count)
                        break
                    } else if lower.hasPrefix(String(ln.prefix(3))) {
                        matched = (k, 3)
                        break
                    }
                }
                guard let (mIdx, len) = matched else { return nil }
                mo = mIdx + 1
                rest = rest.dropFirst(len)
            case "MM", "M":
                guard let v = takeNumber(maxDigits: 2) else { return nil }
                mo = Int(v)
            case "DD", "D":
                guard let v = takeNumber(maxDigits: 2) else { return nil }
                d = Int(v)
            case "Do":
                guard let v = takeNumber(maxDigits: 2) else { return nil }
                d = Int(v)
                guard rest.count >= 2, rest.first?.isLetter == true else { return nil }
                rest = rest.dropFirst(2)
            case "HH", "H", "hh", "h":
                guard let v = takeNumber(maxDigits: 2) else { return nil }
                h = Int(v)
            case "mm", "m":
                guard let v = takeNumber(maxDigits: 2) else { return nil }
                mi = Int(v)
            case "ss", "s":
                guard let v = takeNumber(maxDigits: 2) else { return nil }
                sSec = Int(v)
            case "SSS":
                guard let v = takeNumber(maxDigits: 3) else { return nil }
                ms = Int(v)
            default:
                guard rest.count >= 2 else { return nil }
                let sub = rest.prefix(2).lowercased()
                if sub == "am" { pm = false }
                else if sub == "pm" { pm = true }
                else { return nil }
                rest = rest.dropFirst(2)
            }
            fIdx = format.index(fIdx, offsetBy: tok.count)
        }

        if !rest.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
        if let pm {
            h = (h % 12) + (pm ? 12 : 0)
        }
        return at(y, mo, d, h, mi, sSec, ms)
    }

    enum Span: Equatable, Sendable {
        case ms(Double)
        case months(Double)

        func after(_ t: Double) -> Double {
            switch self {
            case let .ms(ms):
                return t + ms
            case let .months(n):
                let whole = trunc(n)
                return MermaidDate.addMonths(t, Int64(whole)) + (n - whole) * 30.0 * MermaidDate.day
            }
        }
    }

    static func parseSpan(_ s: String) -> Span? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex && ((trimmed[idx].isASCII && trimmed[idx].isNumber) || trimmed[idx] == ".") {
            idx = trimmed.index(after: idx)
        }
        guard idx > trimmed.startIndex, let v = Double(trimmed[..<idx]), v.isFinite, v <= 1e6 else { return nil }
        let unit = trimmed[idx...].trimmingCharacters(in: .whitespaces)
        switch unit {
        case "ms": return .ms(v)
        case "s": return .ms(v * sec)
        case "m": return .ms(v * min)
        case "h": return .ms(v * hour)
        case "d": return .ms(v * day)
        case "w": return .ms(v * 7.0 * day)
        case "M": return .months(v)
        case "y": return .months(v * 12.0)
        default: return nil
        }
    }

    static func format(_ t: Double, fmt: String) -> String {
        let f = fields(t)
        var out = ""
        var idx = fmt.startIndex
        while idx < fmt.endIndex {
            let c = fmt[idx]
            idx = fmt.index(after: idx)
            if c != "%" {
                out.append(c)
                continue
            }
            var code: Character = "%"
            if idx < fmt.endIndex {
                code = fmt[idx]
                idx = fmt.index(after: idx)
            }
            var pad: Character? = nil
            if code == "-" || code == "_" || code == "0" {
                pad = code
                if idx < fmt.endIndex {
                    code = fmt[idx]
                    idx = fmt.index(after: idx)
                } else {
                    code = "%"
                }
            }
            func pushNum(_ v: Int64, width: Int, defaultPad: Character) {
                let p = pad ?? defaultPad
                let s = String(v)
                if p == "-" || s.count >= width {
                    out.append(s)
                } else {
                    let fill = String(repeating: p == "_" ? " " : "0", count: width - s.count)
                    out.append(fill)
                    out.append(s)
                }
            }
            let doy = daysFromCivil(f.y, f.mo, f.d) - daysFromCivil(f.y, 1, 1) + 1
            switch code {
            case "Y": pushNum(f.y, width: 4, defaultPad: "0")
            case "y": pushNum(remEuclid(f.y, 100), width: 2, defaultPad: "0")
            case "m": pushNum(Int64(f.mo), width: 2, defaultPad: "0")
            case "d": pushNum(Int64(f.d), width: 2, defaultPad: "0")
            case "e": pushNum(Int64(f.d), width: 2, defaultPad: "_")
            case "H": pushNum(Int64(f.h), width: 2, defaultPad: "0")
            case "I": pushNum(Int64((f.h + 11) % 12 + 1), width: 2, defaultPad: "0")
            case "M": pushNum(Int64(f.mi), width: 2, defaultPad: "0")
            case "S": pushNum(Int64(f.s), width: 2, defaultPad: "0")
            case "L": pushNum(Int64(f.ms), width: 3, defaultPad: "0")
            case "j": pushNum(doy, width: 3, defaultPad: "0")
            case "p": out.append(f.h < 12 ? "AM" : "PM")
            case "b": out.append(String(months[f.mo - 1].prefix(3)))
            case "B": out.append(months[f.mo - 1])
            case "a": out.append(String(days[f.wd].prefix(3)))
            case "A": out.append(days[f.wd])
            default: out.append(code)
            }
        }
        return out
    }

    enum Step: Equatable, Sendable {
        case ms(Double)
        case days(UInt32)
        case weeks(UInt32)
        case months(UInt32)

        var length: Double {
            switch self {
            case let .ms(ms): return ms
            case let .days(n): return Double(n) * MermaidDate.day
            case let .weeks(n): return Double(n) * 7.0 * MermaidDate.day
            case let .months(n): return Double(n) * 30.44 * MermaidDate.day
            }
        }

        static func parse(_ s: String) -> Step? {
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            var idx = trimmed.startIndex
            while idx < trimmed.endIndex && trimmed[idx].isASCII && trimmed[idx].isNumber {
                idx = trimmed.index(after: idx)
            }
            guard idx > trimmed.startIndex, let v = UInt32(trimmed[..<idx]), (1...1000).contains(v) else { return nil }
            let unit = trimmed[idx...].trimmingCharacters(in: .whitespaces)
            switch unit {
            case "millisecond": return .ms(Double(v))
            case "second": return .ms(Double(v) * sec)
            case "minute": return .ms(Double(v) * min)
            case "hour": return .ms(Double(v) * hour)
            case "day": return .days(v)
            case "week": return .weeks(v)
            case "month": return .months(v)
            default: return nil
            }
        }

        static let ladder: [Step] = [
            .ms(sec),
            .ms(5.0 * sec),
            .ms(15.0 * sec),
            .ms(30.0 * sec),
            .ms(min),
            .ms(5.0 * min),
            .ms(15.0 * min),
            .ms(30.0 * min),
            .ms(hour),
            .ms(3.0 * hour),
            .ms(6.0 * hour),
            .ms(12.0 * hour),
            .days(1),
            .days(2),
            .weeks(1),
            .weeks(2),
            .months(1),
            .months(3),
            .months(6),
            .months(12),
            .months(60),
        ]

        func ticks(lo: Double, hi: Double, max: Int) -> [Double] {
            var t: Double
            switch self {
            case let .ms(ms):
                t = ceil(lo / ms) * ms
            case let .days(n):
                var dayNum = Int64(ceil(lo / MermaidDate.day))
                while (civilFromDays(dayNum).2 - 1) % Int(n) != 0 {
                    dayNum += 1
                }
                t = Double(dayNum) * MermaidDate.day
            case .weeks:
                let dayNum = Int64(ceil(lo / MermaidDate.day))
                let offset = (7 - Int(remEuclid(dayNum + 4, 7))) % 7
                t = Double(dayNum + Int64(offset)) * MermaidDate.day
            case let .months(n):
                let f = fields(lo)
                var m0 = f.y * 12 + Int64(f.mo) - 1
                if let first = at(f.y, f.mo, 1, 0, 0, 0, 0), first < lo {
                    m0 += 1
                }
                while remEuclid(m0, Int64(n)) != 0 {
                    m0 += 1
                }
                t = at(floorDiv(m0, 12), Int(remEuclid(m0, 12)) + 1, 1, 0, 0, 0, 0) ?? lo
            }

            var out: [Double] = []
            while t <= hi + 1e-6 && out.count < max {
                out.append(t)
                switch self {
                case let .ms(ms):
                    t += ms
                case let .weeks(n):
                    t += Double(n) * 7.0 * MermaidDate.day
                case let .days(n):
                    let next = t + Double(n) * MermaidDate.day
                    let f = fields(t)
                    let g = fields(next)
                    if g.mo != f.mo && g.d > 1 {
                        t = at(g.y, g.mo, 1, 0, 0, 0, 0) ?? next
                    } else {
                        t = next
                    }
                case let .months(n):
                    t = addMonths(t, Int64(n))
                }
            }
            return out
        }
    }
}
