import Foundation

/// The words an element contributes to a related label or a default button's name.
internal struct AccessibilityNameSource {
    let label: String?
    let text: String?
    let secure: Bool
    let hidden: Bool

    init<State>(_ el: El<State>, securePath: Bool = false) {
        label = el.a11yLabel
        text = el.handlers.editLens == nil ? el.plainText ?? el.richSpans?.map(\.text).joined() : nil
        secure = el.isSecure || securePath
        hidden = el.isA11yHidden || el.opacity <= 0.01
    }

    init(_ info: ElementInfo, securePaths: Set<String>) {
        label = info.label
        text = info.a11yInput?.isInput == true ? nil : info.text
        secure = info.secure || securePaths.contains(info.path)
        hidden = info.a11yHidden || info.opacity <= 0.01
    }

    static func nonblank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static func words<Node>(
        of node: Node, source: (Node) -> Self, children: (Node) -> [Node]
    ) -> String? {
        let root = source(node)
        guard !root.secure else { return nil }
        if let label = nonblank(root.label) { return label }
        if let text = root.text { return nonblank(text.trimmingCharacters(in: .whitespacesAndNewlines)) }

        // Upstream caps a composite name at 400 UTF-8 bytes, on a scalar boundary.
        var name = ""
        func append(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !name.isEmpty { name.append(" ") }
            for scalar in trimmed.unicodeScalars {
                guard name.utf8.count + scalar.utf8.count <= 400 else { break }
                name.unicodeScalars.append(scalar)
            }
        }
        func visit(_ parent: Node) {
            for child in children(parent) {
                guard name.utf8.count < 400 else { return }
                let part = source(child)
                guard !part.secure, !part.hidden else { continue }
                if let label = nonblank(part.label) {
                    append(label)
                } else {
                    if let text = part.text { append(text) }
                    visit(child)
                }
            }
        }
        visit(node)
        return nonblank(name)
    }

    /// Look for a referenced key inside the nearest common ancestor first.
    static func relatedIndex(
        _ key: String, from index: Int, parent: (Int) -> Int?, children: (Int) -> [Int], keyAt: (Int) -> String?
    ) -> Int? {
        func find(in scope: Int) -> Int? {
            for child in children(scope) {
                if child != index, matchesAuthoredKey(keyAt(child), key) { return child }
                if let found = find(in: child) { return found }
            }
            return nil
        }
        var scope = parent(index)
        while let ancestor = scope {
            if let found = find(in: ancestor) { return found }
            scope = parent(ancestor)
        }
        return nil
    }
}
