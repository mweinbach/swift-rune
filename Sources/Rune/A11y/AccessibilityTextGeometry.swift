import RuneMotion

/// Grapheme extents from Rune's shaped lines. Fully clipped cells retain their line and offsets.
internal struct AccessibilityTextCell {
    let start, end, line: Int32
    let x, y, width, height: Double
    let hitMidpoint: Double
    let rtl: Bool
}

internal enum AccessibilityTextGeometry {
    enum OffsetUnit {
        case utf16, unicodeScalars
    }
    static let byteLimit = 64 * 1024

    static func cells(for text: String, shaped: ShapedText, origin: Vec2, scale: Vec2,
                      pixelScale: Float, clip: MotionRect, unit: OffsetUnit = .utf16) -> [AccessibilityTextCell]? {
        guard text.utf8.count <= byteLimit, !shaped.wasTruncated, shaped.elided == nil,
              shaped.portableLines.first?.utf8Start == 0,
              !shaped.paragraphSpans.contains(where: { !$0.shaped && !$0.isBlank }),
              origin.x.isFinite, origin.y.isFinite, scale.x.isFinite, scale.y.isFinite,
              scale.x > 0, scale.y > 0, pixelScale.isFinite, pixelScale > 0 else { return nil }

        let bytes = Array(text.utf8)
        var units = [Int32](repeating: -1, count: bytes.count + 1)
        var byte = 0
        units[0] = 0
        for ch in text {
            let end = byte + ch.utf8.count
            let length = unit == .utf16 ? ch.utf16.count : ch.unicodeScalars.count
            units[end] = units[byte] + Int32(length)
            byte = end
        }
        let lines = shaped.portableLines
        var cells = [AccessibilityTextCell]()
        for (index, line) in lines.enumerated() {
            let start = line.utf8Start
            let next = index + 1 < lines.count ? lines[index + 1].utf8Start : bytes.count
            guard start >= 0, next >= start, next <= bytes.count,
                  line.text.utf8.count <= next - start else { return nil }
            let end = start + line.text.utf8.count
            guard units[start] >= 0, units[end] >= 0, units[next] >= 0,
                  bytes[start..<end].elementsEqual(line.text.utf8) else { return nil }
            let visual = shaped.visualCells(on: index)
            guard visual.count == line.text.count else { return nil }
            let h = shaped.lineBoxHeightPt(index)
            func cell(_ lo: Int, _ hi: Int, x: Float, width: Float, rtl: Bool) -> AccessibilityTextCell {
                let left = origin.x + (line.originX + x) * scale.x
                let top = origin.y + line.originY * scale.y
                let right = left + width * scale.x
                let bottom = top + h * scale.y
                let x0 = max(clip.left, left), y0 = max(clip.top, top)
                let w = min(clip.right, right) - x0, clippedH = min(clip.bottom, bottom) - y0
                // A visible insertion edge has zero width and positive height. A hidden glyph has neither.
                let visibleEdge = width == 0 && clip.width > 0 && left >= clip.left && left <= clip.right
                let visible = clippedH > 0 && (w > 0 || visibleEdge)
                return AccessibilityTextCell(start: units[lo], end: units[hi], line: Int32(index),
                                           x: Double(x0 * pixelScale), y: Double(y0 * pixelScale),
                                           width: visible ? Double(max(0, w) * pixelScale) : 0,
                                           height: visible ? Double(clippedH * pixelScale) : 0,
                                           hitMidpoint: Double((left + width * scale.x / 2) * pixelScale), rtl: rtl)
            }
            for item in visual {
                let range = item.range
                guard range.lowerBound >= start, range.upperBound <= end, !range.isEmpty,
                      units[range.lowerBound] >= 0, units[range.upperBound] >= 0 else { return nil }
                cells.append(cell(range.lowerBound, range.upperBound, x: item.left, width: item.width, rtl: item.rtl))
            }
            let rtl = shaped.lineIsRTL.indices.contains(index) && shaped.lineIsRTL[index]
            if end < next {
                // The layout omits paragraph separators from its line text. They occupy document
                // positions but have no ink; use the last logical character's trailing edge.
                let separator = String(decoding: bytes[end..<next], as: UTF8.self)
                guard separator.count == 1, separator.first?.isNewline == true else { return nil }
                let trailing = visual.first { $0.range.upperBound == end }?.trailingX ?? 0
                cells.append(cell(end, next, x: trailing, width: 0, rtl: rtl))
            } else if line.text.isEmpty {
                cells.append(cell(start, start, x: 0, width: 0, rtl: rtl))
            }
        }
        return cells
    }
}

/// Geometry uses the same retained text layout and transforms as paint. Rectangles
/// are window-relative. The destination selects logical coordinates or physical pixels.
internal struct AccessibilityFieldTextLayout {
    let text: String
    let box: TextLayoutBox
    let origin, scale: Vec2
    let clip: MotionRect
    let usesPlaceholder: Bool

    func cells(unit: AccessibilityTextGeometry.OffsetUnit, pixelScale: Float) -> [AccessibilityTextCell]? {
        var shaped = box.shaped
        if usesPlaceholder {
            guard !shaped.portableLines.isEmpty else { return nil }
            // The empty field's caret is painted at the placeholder's first insertion position.
            let caret = shaped.portableCaret(on: 0, at: 0)
            shaped = ShapedText(size: Vec2(0, caret.w), lineCount: 1, lineHeight: caret.w,
                                glyphs: [], underlines: [], backgrounds: [],
                                portableLines: [(0, "", caret.y, caret.x, [0])])
        }
        return AccessibilityTextGeometry.cells(for: text, shaped: shaped, origin: origin, scale: scale,
                                               pixelScale: pixelScale, clip: clip, unit: unit)
    }
}

#if os(Windows) || os(Linux)
extension Runtime {
    internal func accessibilityTextLayout(target: String, clip: MotionRect) -> AccessibilityFieldTextLayout? {
        guard let index = a11yTargetIndex(target) else { return nil }
        let node = flatNodes[index]
        guard !node.el.isSecure, let edit = node.el.handlers.editLens?.get(state), !edit.isSecure,
              edit.text.utf8.count <= AccessibilityTextGeometry.byteLimit,
              let box = nodeTextLayouts[node.nodeId]?.box, hitGeometryByPath[node.path]?.turn == nil else { return nil }
        let rect = presentedRectByPath[node.path] ?? node.targetRect
        let scale = presentedScales[node.path] ?? Vec2(1, 1)
        let scroll = edit.multiline ? 0 : (inputScroll[node.path] ?? 0)
        let origin = Vec2(rect.x + (node.el.layout.padding.left - scroll) * scale.x,
                          rect.y + node.el.layout.padding.top * scale.y)
        let parent = hitGeometryByPath[node.path]?.parentScreenClip ?? clip
        let visible = intersectRects(intersectRects(clip, rect), parent)
        let placeholder = edit.text.isEmpty && node.el.placeholder?.isEmpty == false && box.authText.utf8.elementsEqual((node.el.placeholder ?? "").utf8)
        guard placeholder || box.authText.utf8.elementsEqual(edit.text.utf8) else { return nil }
        return AccessibilityFieldTextLayout(text: edit.text, box: box, origin: origin, scale: scale, clip: visible,
                                            usesPlaceholder: placeholder)
    }
}
#endif
