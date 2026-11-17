import Foundation

/// The notification center stores tags in UTF-16 and accepts up to five actions per toast.
enum WindowsToastContent {
    private static let identifierKey = "rune.id"
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func tag(for id: String) -> String {
        if !id.isEmpty, id.utf16.count <= 64, !id.utf8.contains(0) { return id }
        let hash = id.utf8.reduce(UInt64(0xcbf29ce484222325)) { ($0 ^ UInt64($1)) &* 0x100000001b3 }
        return String(format: "%016llx", hash)
    }

    static func validScheme(_ scheme: String) -> String? {
        guard (2...255).contains(scheme.utf8.count), let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return nil }
        return scheme.lowercased()
    }

    static func xml(_ notification: Notification, scheme: String?, background: Bool) -> String {
        let userInfo = notification.info.filter { $0.0 != identifierKey && $0.0 != RuneNotifyConstants.actionKey }
        let info = [(identifierKey, notification.id)] + userInfo
        var attributes = "launch=\"\(escape(query(info)))\""
        if let scheme {
            let url = "\(scheme)://notification/\(percent(notification.id))?\(query(userInfo))"
            attributes = "activationType=\"protocol\" launch=\"\(escape(url))\""
        }
        var result = "<toast \(attributes)><visual><binding template=\"ToastGeneric\">"
        for text in [notification.title, notification.subtitle, notification.body].compactMap({ $0 }) where !text.isEmpty {
            result += "<text>\(escape(text))</text>"
        }
        result += "</binding></visual>"
        var inputs = "", buttons = ""
        for action in notification.actions.prefix(5) {
            let label: String
            var hint = ""
            switch action {
            case .button(_, let name):
                label = name
            case .reply(let id, let placeholder, let name):
                label = name
                inputs += "<input id=\"\(escape(id))\" type=\"text\" placeHolderContent=\"\(escape(placeholder))\"/>"
                hint = " hint-inputId=\"\(escape(id))\""
            }
            let arguments = escape(query(info + [(RuneNotifyConstants.actionKey, action.id)]))
            let mode = background ? "background" : "foreground"
            buttons += "<action content=\"\(escape(label))\" arguments=\"\(arguments)\" activationType=\"\(mode)\"\(hint)/>"
        }
        if !buttons.isEmpty { result += "<actions>\(inputs)\(buttons)</actions>" }
        switch notification.sound {
        case .none: result += "<audio silent=\"true\"/>"
        case .default: break
        case .named(let sound): result += "<audio src=\"\(escape(sound))\"/>"
        }
        return result + "</toast>"
    }

    static func click(arguments: String, inputs: [(String, String)]) -> NotificationClick? {
        // Protocol activation is delivered by the Windows shell via clickFromURL.
        var info = parseQuery(arguments)
        guard let index = info.firstIndex(where: { $0.0 == identifierKey }) else { return nil }
        let id = info.remove(at: index).1
        for (key, value) in inputs { info.append((RuneNotifyConstants.inputPrefix + key, value)) }
        return NotificationClick(id: id, info: info)
    }

    static func click(url: String, scheme: String?) -> NotificationClick? {
        guard let scheme else { return nil }
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let split = text.range(of: "://"), text[..<split.lowerBound].lowercased() == scheme else { return nil }
        let remainder = text[split.upperBound...]
        guard remainder.hasPrefix("notification/") else { return nil }
        let path = remainder.dropFirst("notification/".count)
        let separator = path.firstIndex(of: "?") ?? path.endIndex
        let raw = String(path[..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let info = separator == path.endIndex ? [] : parseQuery(String(path[path.index(after: separator)...]))
        return NotificationClick(id: raw.removingPercentEncoding ?? raw, info: info)
    }

    private static func query(_ pairs: [(String, String)]) -> String {
        pairs.map { percent($0.0) + "=" + percent($0.1) }.joined(separator: "&")
    }

    private static func parseQuery(_ query: String) -> [(String, String)] {
        func decode(_ value: Substring) -> String {
            let text = String(value).replacingOccurrences(of: "+", with: " ")
            return text.removingPercentEncoding ?? text
        }
        return query.split(separator: "&").map {
            let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (decode(pair[0]), pair.count > 1 ? decode(pair[1]) : "")
        }
    }

    private static func percent(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func escape(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": output += "&amp;"
            case "<": output += "&lt;"
            case ">": output += "&gt;"
            case "\"": output += "&quot;"
            case "'": output += "&apos;"
            case "\n", "\r", "\t": output.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20 && scalar.value != 0xfffe && scalar.value != 0xffff {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output
    }
}
