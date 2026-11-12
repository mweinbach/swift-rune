import Foundation
import Rune

struct SequenceParticipant {
    var id: String
    var label: String
    var kind: Kind
    var group: Int?

    enum Kind: Equatable {
        case box
        case actor
        case boundary
        case control
        case entity
        case database
        case collections
        case queue
    }
}

struct SequenceParticipantBox {
    var title: String
    var color: Color?
}

enum SequenceTip: Equatable {
    case none
    case filled
    case open
    case cross
}

struct SequenceMessage {
    var from: Int
    var to: Int
    var text: String
    var dotted: Bool
    var tip: SequenceTip
    var both: Bool
    var activate: Bool
    var deactivate: Bool
}

enum SequenceNotePos: Equatable {
    case left(Int)
    case right(Int)
    case over(Int, Int)
}

enum SequenceEvent {
    case message(SequenceMessage)
    case note(SequenceNotePos, String)
    case activate(Int)
    case deactivate(Int)
    case create(Int)
    case destroy(Int)
    case number((UInt32, UInt32)?)
    case open(kind: String?, label: String, fill: Color?)
    case elseBranch(String)
    case end
}

struct SequenceDiagram {
    var title: String?
    var participants: [SequenceParticipant]
    var boxes: [SequenceParticipantBox]
    var events: [SequenceEvent]
    var autonumber: Bool
}

enum SequenceParser {
    private static let arrows: [(String, Bool, SequenceTip, Bool)] = [
        ("<<-->>", true, .filled, true),
        ("<<->>", false, .filled, true),
        ("-->>", true, .filled, false),
        ("->>", false, .filled, false),
        ("--x", true, .cross, false),
        ("-x", false, .cross, false),
        ("--)", true, .open, false),
        ("-)", false, .open, false),
        ("-->", true, .none, false),
        ("->", false, .none, false),
    ]

    static func parse(header: String, body: [String]) -> SequenceDiagram? {
        var p = State()
        for line in body {
            let people = p.s.participants.count
            let events = p.s.events.count
            if !p.line(line) {
                p.s.participants = Array(p.s.participants.prefix(people))
                p.s.events = Array(p.s.events.prefix(events))
                p.ids = p.ids.filter { $0.value < people }
            }
            if p.s.participants.count > 40 || p.s.events.count > MermaidLimits.maxItems || p.depth > MermaidLimits.maxDepth {
                return nil
            }
        }
        for _ in 0..<p.depth {
            p.s.events.append(.end)
        }
        return p.s.participants.isEmpty ? nil : p.s
    }

    private struct State {
        var s = SequenceDiagram(title: nil, participants: [], boxes: [], events: [], autonumber: false)
        var ids: [String: Int] = [:]
        var depth = 0
        var activeBox: Int? = nil

        mutating func line(_ raw: String) -> Bool {
            var l = raw.trimmingCharacters(in: .whitespaces)
            while l.hasSuffix(";") { l.removeLast() }
            l = l.trimmingCharacters(in: .whitespaces)
            let wordTok: String
            let rest: String
            if let ws = l.firstIndex(where: \.isWhitespace) {
                wordTok = String(l[..<ws])
                rest = String(l[ws...]).trimmingCharacters(in: .whitespaces)
            } else {
                wordTok = l
                rest = ""
            }
            let key = wordTok.hasSuffix(":") ? String(wordTok.dropLast()) : wordTok
            switch key {
            case "participant", "actor":
                return declare(rest, actor: wordTok == "actor") != nil
            case "create":
                let (kind, name): (String, String)
                if let ws = rest.firstIndex(where: \.isWhitespace) {
                    kind = String(rest[..<ws])
                    name = String(rest[ws...]).trimmingCharacters(in: .whitespaces)
                } else {
                    kind = rest
                    name = ""
                }
                guard kind == "participant" || kind == "actor", let i = declare(name, actor: kind == "actor") else {
                    return false
                }
                s.events.append(.create(i))
                return true
            case "destroy":
                guard let i = id(rest) else { return false }
                s.events.append(.destroy(i))
                return true
            case "title":
                var after = String(l.dropFirst("title".count)).trimmingCharacters(in: .whitespaces)
                if after.hasPrefix(":") { after.removeFirst() }
                let t = cleanQuoted(after)
                if !t.isEmpty { s.title = t }
                return true
            case "accTitle", "accDescr", "link", "links", "properties", "details":
                return true
            case "autonumber":
                let on: (UInt32, UInt32)?
                if rest == "off" {
                    on = nil
                } else if rest.isEmpty {
                    on = (1, 1)
                } else {
                    let parts = rest.split(whereSeparator: \.isWhitespace)
                    if parts.count == 1, let start = UInt32(parts[0]) {
                        on = (start, 1)
                    } else if parts.count >= 2, let start = UInt32(parts[0]), let step = UInt32(parts[1]) {
                        on = (start, step)
                    } else {
                        return false
                    }
                }
                if on != nil { s.autonumber = true }
                s.events.append(.number(on))
                return true
            case "activate":
                guard let i = id(rest) else { return false }
                s.events.append(.activate(i))
                return true
            case "deactivate":
                guard let i = id(rest) else { return false }
                s.events.append(.deactivate(i))
                return true
            case "Note", "note":
                return note(rest)
            case "loop", "alt", "opt", "par", "critical", "break":
                depth += 1
                s.events.append(.open(kind: key, label: clean(rest), fill: nil))
                return true
            case "rect":
                depth += 1
                s.events.append(.open(kind: nil, label: "", fill: parseColorSpec(rest)))
                return true
            case "box":
                if activeBox != nil { return false }
                let (color, title) = parseBoxHeader(rest)
                s.boxes.append(SequenceParticipantBox(title: title, color: color))
                activeBox = s.boxes.count - 1
                return true
            case "else", "and", "option":
                if depth == 0 { return false }
                s.events.append(.elseBranch(clean(rest)))
                return true
            case "end":
                if activeBox != nil {
                    activeBox = nil
                } else {
                    if depth == 0 { return false }
                    depth -= 1
                    s.events.append(.end)
                }
                return true
            default:
                return message(l)
            }
        }

        mutating func declare(_ rawRest: String, actor: Bool) -> Int? {
            let rest: String
            let meta: String
            if let r = rawRest.range(of: "@{") {
                rest = String(rawRest[..<r.lowerBound])
                meta = String(rawRest[r.upperBound...])
            } else {
                rest = rawRest
                meta = ""
            }
            let kind: SequenceParticipant.Kind = actor ? .actor : metaKind(meta)
            let pId: String
            let label: String
            if let asRange = rest.range(of: " as ") {
                pId = String(rest[..<asRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                label = cleanQuoted(String(rest[asRange.upperBound...]))
            } else {
                pId = rest.trimmingCharacters(in: .whitespaces)
                label = cleanQuoted(rest)
            }
            guard let i = id(pId) else { return nil }
            s.participants[i].label = label
            s.participants[i].kind = kind
            if s.participants[i].group == nil {
                s.participants[i].group = activeBox
            }
            return i
        }

        mutating func id(_ raw: String) -> Int? {
            let name = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if name.isEmpty || name.contains(":") || name.contains(",") { return nil }
            if let existing = ids[name] { return existing }
            let idx = s.participants.count
            s.participants.append(SequenceParticipant(id: name, label: clean(name), kind: .box, group: activeBox))
            ids[name] = idx
            return idx
        }

        mutating func note(_ rest: String) -> Bool {
            guard let colon = rest.firstIndex(of: ":") else { return false }
            let place = rest[..<colon].trimmingCharacters(in: .whitespaces)
            let text = String(rest[rest.index(after: colon)...])
            let lower = place.lowercased()
            let pos: SequenceNotePos
            if lower.hasPrefix("left of ") {
                guard let a = id(String(place.dropFirst("left of ".count))) else { return false }
                pos = .left(a)
            } else if lower.hasPrefix("right of ") {
                guard let a = id(String(place.dropFirst("right of ".count))) else { return false }
                pos = .right(a)
            } else if lower.hasPrefix("over ") {
                let who = String(place.dropFirst("over ".count))
                if let comma = who.firstIndex(of: ",") {
                    guard let a = id(String(who[..<comma])),
                          let b = id(String(who[who.index(after: comma)...])) else { return false }
                    pos = .over(min(a, b), max(a, b))
                } else {
                    guard let a = id(who) else { return false }
                    pos = .over(a, a)
                }
            } else {
                return false
            }
            s.events.append(.note(pos, cleanQuoted(text)))
            return true
        }

        mutating func message(_ l: String) -> Bool {
            let lhs: Substring
            let text: String
            if let colon = l.firstIndex(of: ":") {
                lhs = l[..<colon]
                text = String(l[l.index(after: colon)...])
            } else {
                lhs = l[...]
                text = ""
            }
            var found: (String.Index, (String, Bool, SequenceTip, Bool))? = nil
            var idx = lhs.startIndex
            while idx < lhs.endIndex {
                let ch = lhs[idx]
                if ch == "-" || ch == "<" {
                    let sub = lhs[idx...]
                    if let arrow = SequenceParser.arrows.first(where: { sub.hasPrefix($0.0) }) {
                        found = (idx, arrow)
                        break
                    }
                }
                idx = lhs.index(after: idx)
            }
            guard let (at, (tok, dotted, tip, both)) = found else { return false }
            let fromRaw = String(lhs[..<at]).trimmingCharacters(in: .whitespaces)
            let afterTok = lhs.index(at, offsetBy: tok.count)
            let rest = String(lhs[afterTok...]).trimmingCharacters(in: .whitespaces)
            let activate: Bool
            let deactivate: Bool
            let toRaw: String
            if rest.hasPrefix("+") {
                activate = true
                deactivate = false
                toRaw = String(rest.dropFirst())
            } else if rest.hasPrefix("-") {
                activate = false
                deactivate = true
                toRaw = String(rest.dropFirst())
            } else {
                activate = false
                deactivate = false
                toRaw = rest
            }
            guard let from = id(fromRaw), let to = id(toRaw) else { return false }
            s.events.append(.message(SequenceMessage(
                from: from,
                to: to,
                text: clean(text),
                dotted: dotted,
                tip: tip,
                both: both,
                activate: activate,
                deactivate: deactivate
            )))
            return true
        }
    }

    private static func metaKind(_ meta: String) -> SequenceParticipant.Kind {
        guard let range = meta.range(of: "type") else { return .box }
        let after = meta[range.upperBound...].drop(while: { $0 == "\"" || $0 == ":" || $0.isWhitespace })
        let name = String(after.prefix(while: { $0.isASCII && $0.isLetter }))
        switch name {
        case "actor": return .actor
        case "boundary": return .boundary
        case "control": return .control
        case "entity": return .entity
        case "database": return .database
        case "collections": return .collections
        case "queue": return .queue
        default: return .box
        }
    }

    private static func parseBoxHeader(_ raw: String) -> (Color?, String) {
        let rest = raw.trimmingCharacters(in: .whitespaces)
        if rest.isEmpty { return (nil, "") }
        if rest.hasPrefix("rgb(") || rest.hasPrefix("rgba("), let end = rest.firstIndex(of: ")") {
            let colStr = String(rest[...end])
            let tail = String(rest[rest.index(after: end)...])
            return (parseColorSpec(colStr), cleanQuoted(tail))
        }
        let first: String
        let tail: String
        if let ws = rest.firstIndex(where: \.isWhitespace) {
            first = String(rest[..<ws])
            tail = String(rest[ws...])
        } else {
            first = rest
            tail = ""
        }
        if first.lowercased() == "transparent" {
            return (nil, cleanQuoted(tail))
        }
        if let c = parseColorSpec(first) {
            return (c, cleanQuoted(tail))
        }
        return (nil, cleanQuoted(rest))
    }
}
