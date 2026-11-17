import RuneMotion

/// A document exposes each line of adjacent code tokens and each wrapped word paragraph as a
/// single native text run. Link children keep the paths that dispatch to their original owners.
enum WebDocumentInlineFlow {
    private struct Token {
        let text: String
        let parent: Int?
        let flow: Int?
        let target: MotionRect
        let style: TextStyle
        let selectable: Bool
    }

    private struct Run {
        var node: AccessibilityNode
        let first: Token
        var right: Float
        var text: String
        var utf16Count: Int
        var merged = false

        init(_ node: AccessibilityNode, _ first: Token) {
            self.node = node
            self.first = first
            right = first.target.right
            text = first.text
            utf16Count = first.text.utf16.count
        }

        /// Rust's Inline::gap accepts overlapping baselines and at most 0.6 em between tokens.
        func separator(before next: Token) -> Bool? {
            guard first.selectable == next.selectable else { return nil }
            if let flow = first.flow {
                guard flow == next.flow else { return nil }
                return next.text.unicodeScalars.first.map { !")].,;:".unicodeScalars.contains($0) } ?? false
            }
            let a = first.style, b = next.style
            guard next.flow == nil, first.parent == next.parent, a.family == b.family, a.size == b.size,
                  a.weight == b.weight, a.letterSpacing == b.letterSpacing else { return nil }
            let height = min(first.target.height, next.target.height)
            let overlap = min(first.target.bottom, next.target.bottom) - max(first.target.top, next.target.top)
            let gap = next.target.left - right
            guard height > 0, overlap >= height * 0.5, gap >= -0.5, gap <= b.size * 0.6 else { return nil }
            return gap > b.size * 0.15
        }

        mutating func append(_ next: AccessibilityNode, token: Token, space: Bool) {
            if space, text.unicodeScalars.last?.properties.isWhitespace == false,
               token.text.unicodeScalars.first?.properties.isWhitespace == false {
                text.append(" ")
                utf16Count += 1
            }
            for var link in next.children {
                if let range = link.webDocument?.inlineRange {
                    link.webDocument?.inlineRange = (range.lowerBound + utf16Count)..<(range.upperBound + utf16Count)
                }
                node.children.append(link)
            }
            text.append(contentsOf: token.text)
            utf16Count += token.text.utf16.count
            right = token.target.right
            node.frame = node.frame.union(next.frame)
            merged = true
        }

        mutating func finish() -> AccessibilityNode {
            if merged {
                node.label = text
                node.value = text
                node.webDocument?.text = nil
                // The real inline anchors provide the tab stops, including when the first token
                // itself owns a link. Another focus stop on the merged paragraph duplicates them.
                node.actions.removeAll { $0 == .focus }
            }
            return node
        }
    }

    static func project<State>(_ root: inout AccessibilityNode, runtime: Runtime<State>) {
        var referencedKeys: Set<String> = []
        for model in runtime.flatNodes {
            let el = model.el
            if let key = el.a11yLabelledBy { referencedKeys.insert(key) }
            if let key = el.a11yDescribedBy { referencedKeys.insert(key) }
            if let key = el.a11yActiveDescendant { referencedKeys.insert(key) }
        }

        func plainModel(_ node: AccessibilityNode) -> Runtime<State>.FlatNode? {
            guard let path = node.runtimePath, let index = runtime.nodeByPath[path] else { return nil }
            let model = runtime.flatNodes[index], el = model.el
            guard !node.isFocused, !node.isFocusable, !node.isDisabled, !node.isSecure, !node.isBusy,
                  !node.isInvalid, !node.isReadOnly, !node.isSelected, !node.isModal, !node.clipsChildren,
                  node.help == nil, node.placeholder == nil, node.range == nil, node.toggled == nil,
                  node.isExpanded == nil, node.level == nil, node.positionInSet == nil, node.sizeOfSet == nil,
                  node.keyboardShortcut == nil, node.url == nil, node.activeDescendant == nil,
                  node.sortAscending == nil, node.selectedState == nil, node.liveRegion == nil,
                  node.scrollY == nil, node.webDocument?.anchor == nil, el.a11yLabel == nil,
                  el.a11yLabelledBy == nil, el.a11yDescribedBy == nil, el.a11yValue == nil,
                  el.a11ySelected == nil, el.runtimeExtras["htmlRole"] == nil,
                  model.key.map({ !referencedKeys.contains($0) }) ?? true,
                  node.actions.allSatisfy({ $0 == .scrollIntoView || ($0 == .focus && !node.children.isEmpty && !el.textLinks.isEmpty) })
            else { return nil }
            return model
        }

        func token(_ node: AccessibilityNode) -> Token? {
            guard node.role == .text, let doc = node.webDocument, doc.font != nil,
                  let words = doc.text ?? node.label, !words.isEmpty,
                  node.frame.width > 0, node.frame.height > 0,
                  node.children.allSatisfy({ $0.webDocument?.inlineRange != nil }),
                  let model = plainModel(node), model.el.textLinks.count == node.children.count else { return nil }
            let parent = model.parentIndex
            var flow: Int?
            if let p = parent, model.key?.hasPrefix("flow-") == true {
                let owner = runtime.flatNodes[p]
                flow = owner.key == nil ? owner.parentIndex ?? p : p
            }
            return Token(text: words, parent: parent, flow: flow, target: model.unscrolledRect,
                         style: model.el.textStyle, selectable: doc.selectable)
        }

        func rewrite(_ parent: inout AccessibilityNode) {
            guard !parent.children.isEmpty else { return }
            if parent.children.count == 1 {
                rewrite(&parent.children[0])
                return
            }
            var result: [AccessibilityNode] = []
            result.reserveCapacity(parent.children.count)
            var run: Run?
            func flush() {
                if let completed = run?.finish() { result.append(completed) }
                run = nil
            }
            func consume(_ child: AccessibilityNode) {
                if let next = token(child) {
                    if let space = run?.separator(before: next) {
                        run?.append(child, token: next, space: space)
                    } else {
                        flush()
                        run = Run(child, next)
                    }
                } else {
                    flush()
                    var kept = child
                    rewrite(&kept)
                    result.append(kept)
                }
            }
            for child in parent.children {
                // Word wrappers in an authored flow have no semantic identity. Bring their words
                // into sibling order, leaving named groups, links, controls and scroll boxes intact.
                if child.role == .group, let model = plainModel(child), model.key == nil,
                   !model.el.a11yHasPrimaryHandler, model.el.handlers.onKey == nil,
                   child.label == nil, !child.children.isEmpty,
                   child.children.allSatisfy({ token($0)?.flow == model.parentIndex && model.parentIndex != nil }) {
                    for word in child.children { consume(word) }
                } else {
                    consume(child)
                }
            }
            flush()
            parent.children = result
        }
        rewrite(&root)
    }
}
