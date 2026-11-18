import RuneMotion

extension Runtime {
    /// The diff constructor admits only fixed, unwrapped unified lines at whole-pixel
    /// scales. Gutter and code route all intrinsic width variation into already sized
    /// columns. Every text leaf still needs its own layout for drawing and hit tests.
    func adoptFixedUnifiedLine(
        _ el: borrowing El<State>, reference: borrowing El<State>, geometry: LayoutEngine.ResultNode,
        nodeId: NodeId, rowWidth: Float, textFlow: TextFlow?, count: inout Int,
        boxes: inout [(NodeId, RetainedLayoutCoordinator.TextLayoutRecord)]
    ) -> Bool {
        guard el.layout == reference.layout, el.children.count == reference.children.count,
              el.children.count == geometry.children.count, el.explicitDir == nil, !el.isUnmirrored,
              el.anchor == nil, !el.hasEditLens, !el.isSecure, el.liveText == nil,
              el.liveBindings.isEmpty, el.outsideListDiscFont == nil, el.advanceInRun == nil,
              el.iconPayload?.1 == reference.iconPayload?.1, el.imagePayload == nil, el.pixelsPayload == nil,
              el.layoutAnim?.travel != .screen,
              geometry.layout.localSize == geometry.layout.contentSize else { return false }
        count += 1
        let hasText = el.plainText != nil || el.richSpans != nil
        guard hasText == (reference.plainText != nil || reference.richSpans != nil) else { return false }
        if hasText {
            let resolved = ElDisplayResolver.resolveText(el: copy el, rawText: el.plainText, isSecure: false,
                                                        fallbackDirection: el.textDirByParagraph ? nil : textFlow)
            guard el.children.isEmpty, !resolved.displayedText.isEmpty, resolved.advanceRun == nil,
                  resolved.style.wrap == .noWrap, resolved.style.maxLines == 0, !resolved.truncateFade,
                  resolved.pills.isEmpty else { return false }
            let spans = resolved.spans
            let box = textSystem.layoutKeyed(text: spans?.isEmpty == false ? "" : resolved.displayedText,
                                             spans: spans, pills: resolved.pills, style: resolved.style,
                                             maxWidth: nil, pixelScale: pixelScale, emitGlyphs: false,
                                             keep: .cached, countAsRebreak: true, pretty: resolved.pretty)
            let size = box.shaped.size
            let padding = el.layout.padding
            guard size.x.isFinite, size.x >= 0, size.y > 0,
                  size.x + padding.left + padding.right <= geometry.layout.localSize.x,
                  size.y + padding.top + padding.bottom == geometry.layout.localSize.y else { return false }
            boxes.append((nodeId, .init(box: box, isInput: false)))
        }
        for i in el.children.indices {
            let child = el.children[i]
            let segment = child.storageKeyId.map { "@" + $0 } ?? String(i)
            guard adoptFixedUnifiedLine(child, reference: reference.children[i], geometry: geometry.children[i],
                                        nodeId: nodeId.child(segment), rowWidth: rowWidth, textFlow: textFlow,
                                        count: &count, boxes: &boxes) else { return false }
        }
        if el.layout.flexGrow == 1 {
            // The constructor gives the code column a single stretched text child.
            // Its sibling is the fixed gutter. Validate the same flex arithmetic as Taffy.
            guard el.children.count == 1, let text = boxes.last, el.children[0].richSpans != nil else { return false }
            let inset = el.layout.padding.left + el.layout.padding.right
            let basis = text.1.box.shaped.size.x + inset
            let available = rowWidth - (geometry.layout.localRect.x + basis)
            guard available >= 0, basis + available == geometry.layout.localSize.x else { return false }
        }
        return true
    }

    /// The layout solver sees a fixed-height placeholder for each consecutive run of
    /// unchanged rows. Restore the actual children before virtual measurement and flattening.
    struct FixedVirtualRowLayout {
        // Float represents every integral coordinate through 2^24 exactly.
        static var maximumExactHeight: Float { 16_777_216 }

        let source: El<State>
        let listIndices: [Int]
        let groups: [(position: Int, saved: [LayoutEngine.ResultNode])]
        let boxes: [NodeId: RetainedLayoutCoordinator.TextLayoutRecord]
        let width: Float
        let additionalNodeCount: Int

        func restore(_ solved: inout LayoutEngine.ResultNode) -> Bool {
            var ancestors: [LayoutEngine.ResultNode] = []
            var list = solved
            for index in listIndices {
                guard list.children.indices.contains(index) else { return false }
                ancestors.append(list)
                list = list.children[index]
            }
            guard list.layout.localSize.x == width else { return false }
            let compact = list.children
            var children: [LayoutEngine.ResultNode] = []
            var group = 0
            for (i, result) in compact.enumerated() {
                guard group < groups.count, groups[group].position == i else {
                    children.append(result)
                    continue
                }
                let box = result.layout.localRect
                guard box.x == 0, box.width == width, box.y >= 0, box.y.rounded() == box.y,
                      box.bottom <= Self.maximumExactHeight else { return false }
                var y = box.y
                for var row in groups[group].saved {
                    let size = row.layout.localSize
                    row.layout.localRect = .fromXYWH(box.x, y, size.x, size.y)
                    children.append(row)
                    y += size.y
                }
                guard y == box.bottom else { return false }
                group += 1
            }
            guard group == groups.count else { return false }
            list.children = children
            for (ancestor, index) in zip(ancestors, listIndices).reversed() {
                var parent = ancestor
                parent.children[index] = list
                list = parent
            }
            solved = list
            return true
        }
    }
}
