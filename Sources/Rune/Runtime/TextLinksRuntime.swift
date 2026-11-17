import Foundation
import simd

/// Identifies a specific UTF-8 link range within a text element by path and index.
internal struct TextLinkTarget: Sendable, Equatable {
    var path: String
    var key: String?
    var linkIndex: Int
    var button: PointerButton = .primary
}

/// Cached window/target hit boxes and sliced text for one `TextLink` attached to a text node.
internal struct TextLinkBox: Sendable {
    var linkIndex: Int
    var link: TextLink
    /// Per-line window-space boxes `[x, y, width, height]` (in unturned window logical points).
    var windowRects: [SIMD4<Float>]
    /// Unturned target-space union box `[x, y, width, height]`.
    var targetUnion: SIMD4<Float>
    /// Presented window-space union box `[x, y, width, height]`.
    var windowUnion: SIMD4<Float>
    /// Clipped visible union box `[x, y, width, height]`.
    var visibleUnion: SIMD4<Float>
    /// UTF-8 slice for `link.byteRange`.
    var sliceText: String
}

/// Optional ink color override per link byte range returned to glyph emission in `buildRefScene`.
internal struct TextLinkInkRange {
    var color: Color
    var rects: [SIMD4<Float>]

    func color(for glyph: PositionedGlyph) -> Color? {
        let cx = glyph.rect.x + glyph.rect.z * 0.5
        let cy = glyph.rect.y + glyph.rect.w * 0.5
        for r in rects {
            if cx >= r.x - 0.5 && cx <= r.x + r.z + 0.5 && cy >= r.y - 0.5 && cy <= r.y + r.w + 0.5 {
                return color
            }
        }
        return nil
    }
}

private func unionXYWH(_ a: SIMD4<Float>?, _ b: SIMD4<Float>) -> SIMD4<Float> {
    guard let a else { return b }
    let minX = min(a.x, b.x)
    let minY = min(a.y, b.y)
    let maxX = max(a.x + a.z, b.x + b.z)
    let maxY = max(a.y + a.w, b.y + b.w)
    return SIMD4<Float>(minX, minY, max(0, maxX - minX), max(0, maxY - minY))
}

internal extension Runtime {
    /// True when this element hosts active interactive `TextLink` ranges.
    /// Text inputs and `.secure()` elements ignore `El.link(_:)`.
    func hasActiveTextLinks(_ el: El<State>) -> Bool {
        !el.textLinks.isEmpty && !el.isSecure && el.handlers.editLens == nil
    }

    /// Computes per-link geometry, records help hits and hit boxes, and emits `LinkPaint`
    /// backgrounds, underlines, and rings for a text element during `buildRefScene`.
    func recordAndEmitTextLinks(
        snap: FlatNode,
        el: El<State>,
        text: String,
        authoredText: String? = nil,
        caseMap: TextCaseMapping? = nil,
        shaped: ShapedText,
        elided: TextElision? = nil,
        textOriginX: Float,
        textOriginY: Float,
        scaleVec: Vec2,
        pxScale: Float,
        localAlpha: Float,
        defaultTextColor: Color,
        defaultRingOutline: Outline?,
        forceFocusRings: Bool,
        isFocused: Bool,
        isExiting: Bool,
        shouldEmit: Bool,
        visClip: MotionRect,
        devClip: SIMD4<Float>,
        useLayer: Bool,
        effRotate: Float,
        into primitives: inout [Primitive],
        linkBoxes: inout [String: [TextLinkBox]],
        helpHits: inout [HelpHitRecord],
        interactiveHits: inout [HelpInteractiveHitRecord]
    ) -> [TextLinkInkRange] {
        guard hasActiveTextLinks(el), !isExiting else { return [] }
        let rawString = authoredText ?? text
        let utf8Bytes = Array(rawString.utf8)
        let len = utf8Bytes.count
        guard len > 0 else { return [] }

        let targetOriginX = snap.targetRect.x + el.layout.padding.left
        let targetOriginY = snap.targetRect.y + el.layout.padding.top
        let rot = useLayer ? 0 : effRotate

        var nodeBoxes: [TextLinkBox] = []
        var inkRanges: [TextLinkInkRange] = []

        let drawnText = elided != nil ? shaped.drawnText : rawString
        let drawnBytes = Array(drawnText.utf8)
        let drawnLen = drawnBytes.count
        let mappedLinks: [(origIndex: Int, link: TextLink)] = elided.map { elision in
            let displayedLinks: [TextLink] = caseMap.map { cm in
                el.textLinks.map { lk in
                    var copy = lk
                    copy.byteRange = cm.displayedRange(forSourceUTF8Range: lk.byteRange)
                    return copy
                }
            } ?? el.textLinks
            return elision.mapLinks(displayedLinks, contentLength: text.utf8.count)
        } ?? Array(el.textLinks.enumerated()).map { ($0.offset, $0.element) }

        for (k, link) in mappedLinks {
            let a = max(0, min(link.byteRange.lowerBound, drawnLen))
            let b = max(a, min(link.byteRange.upperBound, drawnLen))
            guard a < b else { continue }
            let shapeRange = (elided != nil) ? (a..<b) : (caseMap?.displayedRange(forSourceUTF8Range: a..<b) ?? (a..<b))
            let localBoxes = textSystem.selectionRects(in: shaped, utf8Range: shapeRange, pixelScale: pxScale)
            guard !localBoxes.isEmpty else { continue }

            var winRects: [SIMD4<Float>] = []
            winRects.reserveCapacity(localBoxes.count)
            var winUnion: SIMD4<Float>? = nil
            var tgtUnion: SIMD4<Float>? = nil
            var visUnion: SIMD4<Float>? = nil

            for r in localBoxes where r.z > 0 && r.w > 0 {
                let wx = textOriginX + r.x * scaleVec.x
                let wy = textOriginY + r.y * scaleVec.y
                let ww = r.z * scaleVec.x
                let wh = r.w * scaleVec.y
                let wBox = SIMD4<Float>(wx, wy, ww, wh)
                winRects.append(wBox)
                winUnion = unionXYWH(winUnion, wBox)

                let tBox = SIMD4<Float>(targetOriginX + r.x, targetOriginY + r.y, r.z, r.w)
                tgtUnion = unionXYWH(tgtUnion, tBox)

                let vis = intersectRects(visClip, MotionRect.fromXYWH(wx, wy, ww, wh))
                if vis.width > 0 && vis.height > 0 {
                    visUnion = unionXYWH(visUnion, SIMD4<Float>(vis.x, vis.y, vis.width, vis.height))
                    if !snap.effectiveInert && el.opacity > 0.001 {
                        let hitRect4 = SIMD4<Float>(vis.x, vis.y, vis.right, vis.bottom)
                        if let helpText = link.help, !helpText.isEmpty {
                            helpHits.append(HelpHitRecord(
                                path: snap.path,
                                key: link.id,
                                rect: hitRect4,
                                seq: interactiveHits.count,
                                text: runeHelpWords(helpText),
                                side: el.helpSide,
                                linkIndex: k
                            ))
                        }
                        interactiveHits.append(HelpInteractiveHitRecord(path: snap.path, rect: hitRect4))
                    }
                }
            }

            guard !winRects.isEmpty, let resolvedWinUnion = winUnion, let resolvedTgtUnion = tgtUnion else {
                continue
            }
            let sliceText = String(decoding: drawnBytes[a..<b], as: UTF8.self)
            nodeBoxes.append(TextLinkBox(
                linkIndex: k,
                link: link,
                windowRects: winRects,
                targetUnion: resolvedTgtUnion,
                windowUnion: resolvedWinUnion,
                visibleUnion: visUnion ?? .zero,
                sliceText: sliceText
            ))

            guard shouldEmit && localAlpha > 0.0005 else { continue }
            let activeLinkIdx = focusedLinkIndex ?? 0
            let isLinkHovered = !snap.effectiveInert
                && hoveredPath == snap.path
                && hoveredLink?.path == snap.path
                && hoveredLink?.linkIndex == k
            let isLinkPressed = isLinkHovered
                && pressedLink?.path == snap.path
                && pressedLink?.linkIndex == k
                && pressedLink?.button == .primary
                && linkIndex(atPath: snap.path, at: pointerPosition) == k
            let isLinkFocused = isFocused
                && activeLinkIdx == k
                && focusVisible

            guard isLinkHovered || isLinkPressed || isLinkFocused else { continue }

            var paint = link.effectivePaint(
                hovered: isLinkHovered,
                pressed: isLinkPressed,
                focused: isLinkFocused
            )
            var fallbackUnderlineColor: Color? = nil
            if isLinkFocused && !isLinkHovered && !isLinkPressed && paint.isEmpty {
                var spanColor: Color? = nil
                if let spans = el.richSpans {
                    var offset = 0
                    for sp in spans {
                        let nextOffset = offset + sp.text.utf8.count
                        if offset <= a && nextOffset > a, let col = sp.color {
                            spanColor = col
                            break
                        }
                        offset = nextOffset
                    }
                }
                fallbackUnderlineColor = spanColor ?? defaultTextColor
                paint.underline = true
            }

            if let bg = paint.background {
                let bgColor = bg.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                for r in localBoxes where r.z > 0 && r.w > 0 {
                    primitives.append(.roundedRect(
                        rect: SIMD4<Float>(
                            (textOriginX + r.x * scaleVec.x) * pxScale,
                            (textOriginY + r.y * scaleVec.y) * pxScale,
                            r.z * scaleVec.x * pxScale,
                            r.w * scaleVec.y * pxScale
                        ),
                        radii: SIMD4<Float>(repeating: 3.0 * pxScale),
                        fill: bgColor,
                        clip: devClip,
                        turn: rot
                    ))
                }
            }

            if paint.underline == true {
                let ulColor = (paint.color ?? fallbackUnderlineColor ?? defaultTextColor).scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                let ulThickness = max(1.0, 1.0 * scaleVec.y * pxScale)
                for r in localBoxes where r.z > 0 && r.w > 0 {
                    let ulY = (textOriginY + (r.y + r.w) * scaleVec.y) * pxScale - ulThickness * 1.5
                    primitives.append(.roundedRect(
                        rect: SIMD4<Float>(
                            (textOriginX + r.x * scaleVec.x) * pxScale,
                            ulY,
                            r.z * scaleVec.x * pxScale,
                            ulThickness
                        ),
                        radii: .zero,
                        fill: ulColor,
                        clip: devClip,
                        turn: rot
                    ))
                }
            }

            if let ring = paint.ring {
                let ringColor = ring.color.scaleAlpha(localAlpha).simd4(srgb: srgbBlend)
                let ringW = max(1.0, ring.width * pxScale)
                let padPx = 1.5 * pxScale
                for r in localBoxes where r.z > 0 && r.w > 0 {
                    primitives.append(.roundedRect(
                        rect: SIMD4<Float>(
                            (textOriginX + r.x * scaleVec.x) * pxScale - padPx,
                            (textOriginY + r.y * scaleVec.y) * pxScale - padPx,
                            r.z * scaleVec.x * pxScale + padPx * 2.0,
                            r.w * scaleVec.y * pxScale + padPx * 2.0
                        ),
                        radii: SIMD4<Float>(repeating: 3.0 * pxScale),
                        fill: .zero,
                        borderColor: ringColor,
                        borderWidth: ringW,
                        clip: devClip,
                        turn: rot
                    ))
                }
            }

            if let ink = paint.color {
                inkRanges.append(TextLinkInkRange(color: ink, rects: localBoxes))
            }
        }

        if !nodeBoxes.isEmpty {
            linkBoxes[snap.path] = nodeBoxes
        }
        return inkRanges
    }

    /// Resolves any link glyph ink color override at a shaped glyph's center.
    func linkInkColor(for glyph: PositionedGlyph, ranges: [TextLinkInkRange]) -> Color? {
        guard !ranges.isEmpty else { return nil }
        for entry in ranges {
            if let col = entry.color(for: glyph) {
                return col
            }
        }
        return nil
    }

    /// Clears `focusable`/`focused`/`focusVisible` on link-bearing text nodes and emits
    /// individual `<parentPath>#link-<k>` `ElementInfo` entries (`links.rs:313-362`).
    func appendLinkElements(to infos: inout [ElementInfo]) {
        guard !linkBoxesByPath.isEmpty else { return }
        let baseCount = infos.count
        for parentIdx in 0..<baseCount {
            let parent = infos[parentIdx]
            guard let boxes = linkBoxesByPath[parent.path], !boxes.isEmpty else { continue }
            let parentFocused = (focusedPath == parent.path) && !parent.exiting
            let parentFocusable = parent.focusable
            infos[parentIdx].focusable = false
            infos[parentIdx].focused = false
            infos[parentIdx].focusVisible = false

            let activeIdx = focusedLinkIndex ?? 0
            for box in boxes {
                let isLinkFocused = parentFocused && (activeIdx == box.linkIndex)
                let isLinkFocusable = parentFocusable && !parent.inert && !parent.exiting && box.windowUnion.z > 0 && box.windowUnion.w > 0
                let isLinkHovered = !parent.inert && !parent.exiting
                    && hoveredPath == parent.path
                    && hoveredLink?.path == parent.path
                    && hoveredLink?.linkIndex == box.linkIndex
                let isLinkPressed = isLinkHovered
                    && pressedLink?.path == parent.path
                    && pressedLink?.linkIndex == box.linkIndex
                    && pressedLink?.button == .primary
                    && linkIndex(atPath: parent.path, at: pointerPosition) == box.linkIndex
                let words: String? = (parent.text != nil && !parent.secure) ? box.sliceText : nil

                infos.append(ElementInfo(
                    path: "\(parent.path)#link-\(box.linkIndex)",
                    key: box.link.id,
                    parentIndex: parentIdx,
                    role: box.link.role,
                    rect: [box.windowUnion.x, box.windowUnion.y, box.windowUnion.z, box.windowUnion.w],
                    target: [box.targetUnion.x, box.targetUnion.y, box.targetUnion.z, box.targetUnion.w],
                    visible: [box.visibleUnion.x, box.visibleUnion.y, box.visibleUnion.z, box.visibleUnion.w],
                    opacity: parent.opacity,
                    scale: parent.scale,
                    blur: parent.blur,
                    radius: 0,
                    fill: .transparent,
                    textColor: parent.textColor,
                    text: words,
                    label: box.link.label ?? words,
                    help: box.link.help.map(runeHelpWords),
                    selected: nil,
                    expanded: nil,
                    level: nil,
                    itemSelected: false,
                    focusable: isLinkFocusable,
                    focused: isLinkFocused,
                    focusVisible: isLinkFocused && focusVisible,
                    inert: parent.inert,
                    moving: parent.moving,
                    exiting: parent.exiting,
                    hover: isLinkHovered ? 1.0 : 0.0,
                    press: isLinkPressed ? 1.0 : 0.0,
                    scrolled: parent.scrolled,
                    carriedScrolled: parent.carriedScrolled,
                    caret: nil,
                    secure: parent.secure,
                    disabled: parent.disabled,
                    checked: nil,
                    a11yValue: nil,
                    a11yDescription: nil,
                    a11yHidden: parent.a11yHidden
                ))
            }
        }
    }

    /// Returns the `linkIndex` under `pos` for `path`, or `nil` when outside all link line boxes.
    func linkIndex(atPath path: String, at pos: Vec2) -> Int? {
        guard let boxes = linkBoxesByPath[path], !boxes.isEmpty else { return nil }
        if let geom = hitGeometryByPath[path] {
            guard let localPos = geom.unturnedLocalPoint(for: pos) else { return nil }
            for box in boxes {
                for r in box.windowRects {
                    if localPos.x >= r.x && localPos.x < r.x + r.z && localPos.y >= r.y && localPos.y < r.y + r.w {
                        return box.linkIndex
                    }
                }
            }
            return nil
        }
        for box in boxes {
            for r in box.windowRects {
                if pos.x >= r.x && pos.x < r.x + r.z && pos.y >= r.y && pos.y < r.y + r.w {
                    return box.linkIndex
                }
            }
        }
        return nil
    }

    /// Resolves link cursor shape (`.pointer` unless overridden by `.cursor(...)` other than text selection `.text`).
    func linkCursor(atPath path: String, at pos: Vec2) -> Cursor? {
        guard let idx = nodeByPath[path], !flatNodes[idx].effectiveInert else { return nil }
        let el = flatNodes[idx].el
        guard hasActiveTextLinks(el), linkIndex(atPath: path, at: pos) != nil else { return nil }
        if let c = el.attachedCursor, c != .text {
            return c
        }
        return .pointer
    }

    /// Keeps `focusedLinkIndex` and `focusedKey` synchronized with `focusedPath`.
    func syncFocusedLinkIndex() {
        guard let fPath = focusedPath,
              let idx = nodeByPath[fPath],
              !flatNodes[idx].effectiveInert,
              hasActiveTextLinks(flatNodes[idx].el) else {
            focusedLinkIndex = nil
            return
        }
        let links = flatNodes[idx].el.textLinks
        let next = min(max(0, focusedLinkIndex ?? 0), links.count - 1)
        focusedLinkIndex = next
        focusedKey = links[next].id
    }

    /// Steps Tab / Shift+Tab across multiple links inside the currently focused text node.
    func linkTab(backward: Bool) -> Bool {
        guard let fPath = focusedPath,
              let idx = nodeByPath[fPath],
              !flatNodes[idx].effectiveInert,
              hasActiveTextLinks(flatNodes[idx].el) else {
            return false
        }
        let links = flatNodes[idx].el.textLinks
        guard links.count > 1 else { return false }
        let cur = min(max(0, focusedLinkIndex ?? 0), links.count - 1)
        if !backward && cur + 1 < links.count {
            let next = cur + 1
            focusedLinkIndex = next
            focusedKey = links[next].id
            return true
        }
        if backward && cur > 0 {
            let next = cur - 1
            focusedLinkIndex = next
            focusedKey = links[next].id
            return true
        }
        return false
    }

    /// Activates the currently focused text link on Return / Space.
    func activateFocusedLink(at now: Double) -> Bool {
        guard let fPath = focusedPath,
              let idx = nodeByPath[fPath],
              !flatNodes[idx].effectiveInert,
              hasActiveTextLinks(flatNodes[idx].el) else {
            return false
        }
        let links = flatNodes[idx].el.textLinks
        let k = min(max(0, focusedLinkIndex ?? 0), links.count - 1)
        guard let onLink = flatNodes[idx].el.handlers.onLink else { return false }
        focusVisible = true
        var tx = makeTx(at: now)
        onLink(&state, links[k].id, &tx)
        applyTx(tx, at: now)
        return true
    }

    /// Opens the secondary menu for the currently focused text link (`Key.contextMenu` -> bottom-left of link).
    private func resolveOnLinkSecondary(from startIdx: Int) -> ((inout State, String, PointerPress, inout Tx) -> Void)? {
        var cur: Int? = startIdx
        while let i = cur, i < flatNodes.count {
            if let fn = flatNodes[i].el.handlers.onLinkSecondary {
                return fn
            }
            cur = flatNodes[i].parentIndex
        }
        return nil
    }

    func activateFocusedLinkSecondary(at now: Double) -> Bool {
        guard let fPath = focusedPath,
              let idx = nodeByPath[fPath],
              !flatNodes[idx].effectiveInert,
              hasActiveTextLinks(flatNodes[idx].el) else {
            return false
        }
        let links = flatNodes[idx].el.textLinks
        let k = min(max(0, focusedLinkIndex ?? 0), links.count - 1)
        guard let onSec = resolveOnLinkSecondary(from: idx),
              let box = linkBoxesByPath[fPath]?.first(where: { $0.linkIndex == k }) else {
            return false
        }
        let rect = presentedRectByPath[fPath] ?? flatNodes[idx].targetRect
        let winPos = Vec2(box.windowUnion.x, box.windowUnion.y + box.windowUnion.w)
        let press = PointerPress(
            window: winPos,
            local: Vec2(winPos.x - rect.x, winPos.y - rect.y),
            elementSize: Vec2(rect.width, rect.height),
            button: .secondary,
            mods: .none,
            clicks: 1
        )
        var tx = makeTx(at: now, button: .secondary)
        onSec(&state, links[k].id, press, &tx)
        applyTx(tx, at: now)
        return true
    }

    /// Handles pointer press on a link range while preserving existing keyboard focus.
    func dispatchLinkDown(
        node: FlatNode,
        linkIdx: Int,
        at pos: Vec2,
        button: PointerButton,
        mods: Mods,
        at now: Double
    ) -> Bool {
        guard hasActiveTextLinks(node.el),
              linkBoxesByPath[node.path]?.contains(where: { $0.linkIndex == linkIdx }) == true else {
            return false
        }
        if button == .secondary {
            guard node.el.handlers.onLinkSecondary != nil else { return false }
            pressedLink = TextLinkTarget(path: node.path, key: node.key, linkIndex: linkIdx, button: .secondary)
            dirtyCommit(at: now, why: CommitWhy.input)
            return true
        }
        guard button == .primary || (button == .middle && node.el.handlers.onLink != nil) else { return false }
        pressedLink = TextLinkTarget(path: node.path, key: node.key, linkIndex: linkIdx, button: button)
        dirtyCommit(at: now, why: CommitWhy.input)
        return true
    }

    /// Completes a pressed link click when pointer releases inside the same link range
    /// and was not suppressed by a selectable text drag.
    func dispatchLinkUp(at pos: Vec2, button: PointerButton, mods: Mods, suppressed: Bool, at now: Double) -> Bool {
        guard let pl = pressedLink, button == pl.button else { return false }
        pressedLink = nil
        dirtyCommit(at: now, why: CommitWhy.input)
        guard !suppressed,
              linkIndex(atPath: pl.path, at: pos) == pl.linkIndex,
              let idx = nodeByPath[pl.path],
              !flatNodes[idx].effectiveInert,
              let box = linkBoxesByPath[pl.path]?.first(where: { $0.linkIndex == pl.linkIndex }) else {
            return true
        }
        if button == .secondary {
            if let onSec = resolveOnLinkSecondary(from: idx) {
                let rect = presentedRectByPath[pl.path] ?? flatNodes[idx].targetRect
                let unturnedLocal = hitGeometryByPath[pl.path]?.turn?.unturn(pos) ?? pos
                let press = PointerPress(
                    window: pos,
                    local: Vec2(unturnedLocal.x - rect.x, unturnedLocal.y - rect.y),
                    elementSize: Vec2(rect.width, rect.height),
                    button: .secondary,
                    mods: mods,
                    clicks: clickCount
                )
                var tx = makeTx(at: now, button: .secondary)
                onSec(&state, box.link.id, press, &tx)
                applyTx(tx, at: now)
            }
        } else if (button == .primary || button == .middle), let onLink = flatNodes[idx].el.handlers.onLink {
            var tx = makeTx(at: now, button: button, mods: mods)
            onLink(&state, box.link.id, &tx)
            applyTx(tx, at: now)
        }
        return true
    }
}
