import Foundation
import RuneMotion

/// Resolved input-field display state shared across layout measurement, scene emission, and hit-testing.
internal struct ElResolvedInput {
    var displayString: String
    var renderedString: String
    var showingPlaceholder: Bool
    var spans: [TextSpan]?
    var pills: [PillChip]
    var style: TextStyle
    var isSingleLine: Bool
    var isRich: Bool
    var isSecure: Bool
    var richStyle: RichStyle
    var maxWidthForShape: Float?
    var blocks: [Block] = []

    func measureWidth(_ availMaxWidth: Float?) -> Float? {
        if isSingleLine { return nil }
        return style.wrap == .noWrap ? nil : availMaxWidth
    }
}

/// Resolved static/rich/case/run text state shared across layout measurement, scene emission, and rendering.
internal struct ElResolvedText {
    var authoredText: String
    var displayedText: String
    var caseMap: TextCaseMapping?
    var spans: [TextSpan]?
    var pills: [PillChip]
    var spanRings: [(range: Range<Int>, color: Color, width: Float)]
    var style: TextStyle
    var advanceRun: (run: TextRun, byteOffset: Int)?
    var isSecure: Bool
    var truncateFade: Bool
    var truncateFadeEm: Float

    func measure(using textSystem: TextSystem, maxWidth: Float?, pixelScale: Float) -> Vec2 {
        if let (run, offset) = advanceRun {
            return textSystem.measureRunSlice(run, at: offset, style: style, pixelScale: pixelScale)
                ?? Vec2(0, TextSystem.specLineHeight(lineCount: 1, lineHeightPt: style.resolvedLineHeight, scale: pixelScale, exact: style.exactLines))
        }
        if truncateFade {
            var singleStyle = style
            singleStyle.wrap = .noWrap
            singleStyle.maxLines = 0
            var sz = textSystem.shape(
                text: displayedText,
                spans: spans,
                pills: pills,
                style: singleStyle,
                maxWidth: nil,
                pixelScale: pixelScale,
                emitGlyphs: false
            ).size
            if let mw = maxWidth, mw.isFinite {
                sz.x = min(sz.x, max(0, mw))
            }
            return sz
        }
        let shapeMaxW: Float? = (style.wrap == .noWrap && style.maxLines == 0) ? nil : maxWidth
        if let spans, !spans.isEmpty {
            return textSystem.shape(
                text: "",
                spans: spans,
                pills: pills,
                style: style,
                maxWidth: shapeMaxW,
                pixelScale: pixelScale,
                emitGlyphs: false
            ).size
        }
        return textSystem.measure(
            displayedText,
            style: style,
            maxWidth: shapeMaxW,
            pixelScale: pixelScale,
            pills: pills
        )
    }

    func shape(
        using textSystem: TextSystem,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool,
        glidePx: Vec2 = .zero
    ) -> ShapedText {
        if let (run, offset) = advanceRun {
            if let sliced = textSystem.shapeRunSlice(run, at: offset, style: style, pixelScale: pixelScale, emitGlyphs: emitGlyphs) {
                return sliced
            }
        }
        var effectiveStyle = style
        var shapeMaxW = maxWidth
        if truncateFade {
            effectiveStyle.wrap = .noWrap
            effectiveStyle.maxLines = 0
            shapeMaxW = nil
        } else if effectiveStyle.wrap == .noWrap && effectiveStyle.maxLines == 0 {
            shapeMaxW = nil
        }
        return textSystem.shape(
            text: displayedText,
            spans: spans,
            pills: pills,
            style: effectiveStyle,
            maxWidth: shapeMaxW,
            pixelScale: pixelScale,
            emitGlyphs: emitGlyphs,
            glidePx: glidePx
        )
    }
}

internal enum ElDisplayResolver {
    private static func utf8Substring(_ str: String, byteRange: Range<Int>) -> String {
        let count = str.utf8.count
        let lo = max(0, min(byteRange.lowerBound, count))
        let hi = max(lo, min(byteRange.upperBound, count))
        let startIdx = str.utf8.index(str.utf8.startIndex, offsetBy: lo)
        let endIdx = str.utf8.index(str.utf8.startIndex, offsetBy: hi)
        return String(str[startIdx..<endIdx])
    }

    static func resolveInput<State>(
        el: El<State>,
        edit inputEdit: TextEdit,
        innerWidth: Float? = nil,
        fallbackDirection: TextFlow? = nil
    ) -> ElResolvedInput {
        var edit = inputEdit
        if el.isSecure {
            edit.isSecure = true
            if el.isRevealed { edit.isRevealed = true }
        }
        let richStyle = el.richStyleSpec ?? RichStyle()
        let isSingle = el.isSingleLineInput
        var inputStyle = el.textStyle
        inputStyle.maxLines = 0
        if inputStyle.wrap == .ellipsis {
            inputStyle.wrap = edit.multiline ? .wrap : .noWrap
        }
        if isSingle {
            inputStyle.wrap = .noWrap
        } else if edit.multiline {
            inputStyle.wrap = .wrap
        }
        if let fDir = edit.forcedDir {
            inputStyle.direction = fDir
        } else if let fallbackDirection {
            inputStyle.direction = fallbackDirection
        }

        let isSecureHidden = edit.isSecure && !edit.isRevealed
        let rawDisplay = edit.displayString
        let showingPlaceholder = rawDisplay.isEmpty && (edit.preedit?.text.isEmpty ?? true)
        if showingPlaceholder {
            return ElResolvedInput(
                displayString: rawDisplay,
                renderedString: el.placeholder ?? "",
                showingPlaceholder: true,
                spans: nil,
                pills: [],
                style: inputStyle,
                isSingleLine: isSingle,
                isRich: false,
                isSecure: edit.isSecure,
                richStyle: richStyle,
                maxWidthForShape: isSingle ? nil : (inputStyle.wrap == .noWrap ? nil : innerWidth)
            )
        }

        let decorations = el.inputDecorations
        let isRich = !isSecureHidden && (edit.isRichEnabled || !decorations.isEmpty || el.pillColorsSpec != nil || el.pillIconLookup != nil || el.pillStyleLookup != nil || el.richStyleSpec != nil)
        if !isRich {
            return ElResolvedInput(
                displayString: rawDisplay,
                renderedString: rawDisplay,
                showingPlaceholder: false,
                spans: nil,
                pills: [],
                style: inputStyle,
                isSingleLine: isSingle,
                isRich: false,
                isSecure: edit.isSecure,
                richStyle: richStyle,
                maxWidthForShape: isSingle ? nil : (inputStyle.wrap == .noWrap ? nil : innerWidth)
            )
        }

        let specs = edit.richDisplaySpecs(baseStyle: inputStyle, style: richStyle)
        let defaultPillBg = el.pillColorsSpec?.bg ?? richStyle.link.alpha(0.2)
        let defaultPillFg = el.pillColorsSpec?.fg
        var combinedSpans = specs.spans
        for deco in decorations {
            for mapped in edit.mapRangeToDisplay(deco.byteRange.lowerBound, deco.byteRange.upperBound) {
                var shifted = deco
                shifted.byteRange = mapped
                combinedSpans.append(shifted)
            }
        }
        var pills: [PillChip] = []
        pills.reserveCapacity(specs.pills.count)

        for (pRange, pillId) in specs.pills {
            let customStyle = el.pillStyleLookup?(pillId)
            let resolvedBg: Color?
            if let st = customStyle {
                resolvedBg = (st.background == PillStyle.default.background) ? defaultPillBg : st.background
            } else {
                resolvedBg = defaultPillBg
            }
            let resolvedFg = customStyle?.color ?? defaultPillFg
            let resolvedIcon = customStyle?.icon ?? el.pillIconLookup?(pillId).map { BareIcon($0, size: 12.0) }
            let pillStyle = PillStyle(
                background: resolvedBg,
                ring: customStyle?.ring,
                color: resolvedFg,
                pad: customStyle?.pad ?? 4.0,
                gap: customStyle?.gap ?? 4.0,
                bold: customStyle?.bold ?? false,
                italic: customStyle?.italic ?? false,
                mono: customStyle?.mono ?? false,
                icon: resolvedIcon
            )
            pills.append(PillChip(pRange, style: pillStyle, icon: resolvedIcon))
            if resolvedFg != nil || pillStyle.bold || pillStyle.italic || pillStyle.mono {
                var sp = RichSpan(pRange)
                if let fg = resolvedFg { sp = sp.color(fg) }
                if pillStyle.bold { sp = sp.weight(700) }
                if pillStyle.italic { sp = sp.italic(true) }
                if pillStyle.mono { sp = sp.mono(true) }
                combinedSpans.append(sp)
            }
        }

        let flatSpans: [TextSpan]? = combinedSpans.isEmpty
            ? nil
            : RichSpanFlattener.flatten(combinedSpans, in: specs.displayText, base: inputStyle)
        return ElResolvedInput(
            displayString: rawDisplay,
            renderedString: specs.displayText,
            showingPlaceholder: false,
            spans: flatSpans,
            pills: pills,
            style: inputStyle,
            isSingleLine: isSingle,
            isRich: true,
            isSecure: edit.isSecure,
            richStyle: richStyle,
            maxWidthForShape: isSingle ? nil : (inputStyle.wrap == .noWrap ? nil : innerWidth),
            blocks: specs.blocks
        )
    }

    static func resolveText<State>(
        el: El<State>,
        rawText: String?,
        isSecure: Bool,
        fallbackDirection: TextFlow? = nil
    ) -> ElResolvedText {
        var style = el.textStyle
        if (el.runtimeExtras["htmlWrapAnywhere"] as? Bool == true) || (el.runtimeExtras["shell.wrapAnywhere"] as? Bool == true) {
            style.wrapAnywhere = true
            if style.wrap == .noWrap {
                style.wrap = .wrap
            }
        }
        if let fallbackDirection, style.direction == nil {
            style.direction = fallbackDirection
        }

        let authoredFromSpans = el.richSpans?.map(\.text).joined()
        let authored = rawText ?? authoredFromSpans ?? ""
        let isHiddenSecure = isSecure && !el.isRevealed && !authored.isEmpty
        let caseMode: TextCase? = isHiddenSecure ? nil : el.textCaseValue

        let caseMap: TextCaseMapping?
        let displayedText: String
        let resolvedSpans: [TextSpan]?
        if let rawSpans = el.richSpans, !rawSpans.isEmpty, !isHiddenSecure {
            if let caseMode {
                let joined = authoredFromSpans ?? authored
                let map = TextCaseMapping(source: joined, textCase: caseMode)
                caseMap = map
                displayedText = map.displayed
                var cursor = 0
                var outSpans: [TextSpan] = []
                outSpans.reserveCapacity(rawSpans.count)
                for sp in rawSpans {
                    let len = sp.text.utf8.count
                    let dRange = map.displayedRange(forSourceUTF8Range: cursor..<(cursor + len))
                    var copy = sp
                    copy.text = utf8Substring(map.displayed, byteRange: dRange)
                    outSpans.append(copy)
                    cursor += len
                }
                resolvedSpans = outSpans
            } else {
                caseMap = nil
                displayedText = authored
                resolvedSpans = rawSpans
            }
        } else {
            resolvedSpans = nil
            if isHiddenSecure {
                caseMap = nil
                displayedText = "••••••••••••"
            } else if let caseMode {
                let map = TextCaseMapping(source: authored, textCase: caseMode)
                caseMap = map
                displayedText = map.displayed
            } else {
                caseMap = nil
                displayedText = authored
            }
        }

        let rawPills = isHiddenSecure ? [] : el.pillChips
        let resolvedPills: [PillChip] = rawPills.map { chip in
            var c = chip
            if let pc = el.pillColorsSpec {
                if c.style.background == PillStyle.default.background {
                    c.style.background = pc.bg
                }
                if c.style.color == nil, let fg = pc.fg {
                    c.style.color = fg
                }
            }
            if let map = caseMap {
                c.range = map.displayedRange(forSourceUTF8Range: c.range)
            }
            return c
        }

        let resolvedRings: [(range: Range<Int>, color: Color, width: Float)] = isHiddenSecure ? [] : el.spanRingsSpec.compactMap { entry in
            let r = caseMap?.displayedRange(forSourceUTF8Range: entry.range) ?? entry.range
            guard !r.isEmpty else { return nil }
            return (r, entry.color, entry.width)
        }

        return ElResolvedText(
            authoredText: authored,
            displayedText: displayedText,
            caseMap: caseMap,
            spans: resolvedSpans,
            pills: resolvedPills,
            spanRings: resolvedRings,
            style: style,
            advanceRun: isHiddenSecure ? nil : el.advanceInRun,
            isSecure: isSecure,
            truncateFade: el.isTruncateFadeEnabled,
            truncateFadeEm: el.truncateFadeEm
        )
    }

    /// Computes inset `TextHighlight` specs for `spanRings` restricted to byte ranges covered by background-bearing `TextSpan`s.
    static func spanRingHighlights(
        spanRings: [(range: Range<Int>, color: Color, width: Float)],
        spans: [TextSpan]?
    ) -> [TextHighlight] {
        guard !spanRings.isEmpty, let spans, !spans.isEmpty else { return [] }
        var bgRanges: [Range<Int>] = []
        var cursor = 0
        for sp in spans {
            let len = sp.text.utf8.count
            if sp.background != nil && len > 0 {
                let next = cursor..<(cursor + len)
                if let last = bgRanges.last, last.upperBound == next.lowerBound {
                    bgRanges[bgRanges.count - 1] = last.lowerBound..<next.upperBound
                } else {
                    bgRanges.append(next)
                }
            }
            cursor += len
        }
        guard !bgRanges.isEmpty else { return [] }

        var highlights: [TextHighlight] = []
        for (ringRange, col, w) in spanRings {
            for bgR in bgRanges {
                let lo = max(ringRange.lowerBound, bgR.lowerBound)
                let hi = min(ringRange.upperBound, bgR.upperBound)
                if hi > lo {
                    highlights.append(TextHighlight(
                        lo..<hi,
                        bg: Color.transparent,
                        ring: TextRing(color: col, width: w)
                    ))
                }
            }
        }
        return highlights
    }

    /// Computes glyph clip and edge fade parameters when `truncateFade` overflows the element's inner box.
    static func truncateFadeParams<State>(
        el: El<State>,
        shaped: ShapedText,
        innerW: Float,
        innerH: Float,
        scaleVec: Vec2,
        pxScale: Float,
        textOriginX: Float,
        textOriginY: Float,
        baseClipPx: SIMD4<Float> // [x, y, width, height] in device px
    ) -> (
        glyphClip: SIMD4<Float>,
        glyphFadeLTRB: SIMD4<Float>,
        boxBoundsPx: SIMD4<Float>,
        refFade: SIMD4<Float>,
        refFadeOrigin: SIMD2<Float>,
        isTruncated: Bool
    ) {
        let wrapWidth = innerW / max(1e-4, scaleVec.x)
        let overflows = shaped.size.x > wrapWidth + 0.5 / pxScale
        let boxX = textOriginX * pxScale
        let boxY = textOriginY * pxScale
        let boxW = max(0, innerW) * pxScale
        let boxH = max(0, max(innerH, shaped.size.y * scaleVec.y)) * pxScale
        let boxBoundsPx = SIMD4<Float>(boxX, boxY, boxX + boxW, boxY + boxH)
        let x0 = max(baseClipPx.x, boxX)
        let y0 = max(baseClipPx.y, boxY)
        let x1 = min(baseClipPx.x + baseClipPx.z, boxBoundsPx.z)
        let y1 = min(baseClipPx.y + baseClipPx.w, boxBoundsPx.w)
        let clipped = SIMD4<Float>(x0, y0, max(0, x1 - x0), max(0, y1 - y0))
        guard overflows else {
            return (baseClipPx, .zero, boxBoundsPx, .zero, .zero, false)
        }
        let fadeW = min(el.textStyle.size * el.truncateFadeEm * scaleVec.x * pxScale, max(0, x1 - x0))
        let isRtl: Bool
        if let dir = shaped.forcedDirection ?? el.textStyle.direction {
            isRtl = (dir == .rtl)
        } else {
            isRtl = shaped.primaryIsRTL
        }
        let fadeLeft = (el.textStyle.align == .trailing) != isRtl
        let fadeLTRB = fadeLeft ? SIMD4<Float>(fadeW, 0, 0, 0) : SIMD4<Float>(0, 0, fadeW, 0)
        let refFade: SIMD4<Float>
        let refFadeOrigin: SIMD2<Float>
        if fadeW > 0 {
            let dirX: Float = fadeLeft ? 1.0 : -1.0
            refFade = SIMD4<Float>(dirX, 0, 1.0 / max(1, fadeW), 0)
            refFadeOrigin = SIMD2<Float>(fadeLeft ? boxX : boxBoundsPx.z, boxY)
        } else {
            refFade = .zero
            refFadeOrigin = .zero
        }
        return (clipped, fadeLTRB, boxBoundsPx, refFade, refFadeOrigin, true)
    }
}
