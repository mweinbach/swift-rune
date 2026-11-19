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

    func selectionRange(for edit: TextEdit) -> Range<Int> {
        let selected = edit.selectedUTF8Range
        guard isSecure, !edit.isRevealed else { return selected }
        if edit.multiline { return 0..<renderedString.utf8.count }
        func bulletOffset(_ byte: Int) -> Int {
            let index = edit.text.utf8.index(edit.text.utf8.startIndex, offsetBy: min(byte, edit.text.utf8.count))
            return edit.text[..<index].unicodeScalars.count * "•".utf8.count
        }
        return bulletOffset(selected.lowerBound)..<bulletOffset(selected.upperBound)
    }

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
    var pretty: Bool = false

    func measure(using textSystem: TextSystem, maxWidth: Float?, pixelScale: Float) -> Vec2 {
        if let box = textSystem.preparedOverflowLayout(self, width: maxWidth, scale: pixelScale, forMeasurement: true) {
            var size = box.shaped.size
            if truncateFade, let maxWidth { size.x = min(size.x, max(0, maxWidth)) }
            return size
        }
        if let (run, offset) = advanceRun, !(isSecure && textSystem.isPreparingLayouts) {
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
                emitGlyphs: false,
                bypassCache: isSecure,
                pretty: pretty
            ).size
        }
        return textSystem.measure(
            displayedText,
            style: style,
            maxWidth: shapeMaxW,
            pixelScale: pixelScale,
            pills: pills,
            bypassCache: isSecure,
            pretty: pretty
        )
    }

    /// Reuse a mounted label's break or painted masks only when its authored UTF-8 offsets,
    /// dimensions and raster environment match the current paint.
    func retainedGlyphLayout(in box: TextLayoutBox, using textSystem: TextSystem,
                        maxWidth: Float?, pixelScale: Float, window: TextRasterWindow) -> TextLayoutBox? {
        guard matchesMountedLabel(box, using: textSystem, maxWidth: maxWidth, pixelScale: pixelScale, window: window) else { return nil }
        #if canImport(CoreText) && canImport(CoreGraphics)
        let geometry = box.cachedGeometry
        if geometry.hasGlyphs, !geometry.shaped.glyphPlacementsAreResident(in: textSystem.glyphAtlas) { return nil }
        #elseif os(Linux)
        if spans != nil {
            let geometry = box.cachedGeometry
            if geometry.hasGlyphs, !textSystem.glyphAtlas.retainPages(geometry.desktopPages, since: geometry.desktopAtlasResets) {
                return nil
            }
        }
        #endif
        let painted = textSystem.presentedLayout(box, spans: spans)
        if !painted.hasGlyphs { return textSystem.glyphsForCommittedLabel(painted) }
        #if canImport(CoreText) && canImport(CoreGraphics)
        if painted.shaped.glyphPlacements !== geometry.shaped.glyphPlacements,
           !painted.shaped.glyphPlacementsAreResident(in: textSystem.glyphAtlas) { return nil }
        #else
        guard textSystem.glyphAtlas.retainPages(painted.desktopPages, since: painted.desktopAtlasResets) else { return nil }
        #endif
        return painted
    }

    func matchesMountedLabel(_ box: TextLayoutBox, using textSystem: TextSystem,
                             maxWidth: Float?, pixelScale: Float, window: TextRasterWindow) -> Bool {
        guard box.rasterWindow == nil, !isSecure, advanceRun == nil, !truncateFade,
              style.maxLines == 0, style.wrap != .ellipsis, box.paragraphs == nil,
              box.shaped.lineCount <= 1 || (window.lowerY <= 0 && window.upperY >= box.shaped.size.y),
              box.pixelScale == max(1, pixelScale), box.maxWidth == (style.wrap == .noWrap ? nil : maxWidth),
              box.shapeKey.pretty == TextShapeKey.layoutPretty(pretty, style: style),
              box.style == style, box.shapeKey.matchesLayoutSpans(spans), box.pills == pills,
              TextUTF8Key.equalBytes(box.authText, displayedText),
              box.shapeKey.usesSmoothing(textSystem.smoothing),
              box.shapeKey.fontEpoch == textSystem.currentFontEpoch, box.shapeKey.languageTag == textSystem.language,
              box.shaped.canReplayGlyphInks else { return false }
        return true
    }

    func shape(
        using textSystem: TextSystem,
        maxWidth: Float?,
        pixelScale: Float,
        emitGlyphs: Bool,
        glidePx: Vec2 = .zero,
        bypassCache: Bool? = nil,
        rasterWindow: TextRasterWindow? = nil
    ) -> ShapedText {
        if bypassCache != true,
           let box = textSystem.preparedOverflowLayout(self, width: maxWidth, scale: pixelScale) {
            return emitGlyphs ? textSystem.drawPreparedOverflow(self, box: box, glide: glidePx) : box.shaped
        }
        if let (run, offset) = advanceRun, !(isSecure && textSystem.isPreparingLayouts) {
            if let sliced = textSystem.shapeRunSlice(run, at: offset, style: style, pixelScale: pixelScale, emitGlyphs: emitGlyphs) {
                guard let spans, emitGlyphs else { return sliced }
                var painted = sliced.applyingSpanInks(spans)
                painted.applyScopedGlyphMasks(in: textSystem.glyphAtlas)
                return painted
            }
        }
        var effectiveStyle = style
        var shapeMaxW = maxWidth
        var effectivePretty = pretty
        if truncateFade {
            effectiveStyle.wrap = .noWrap
            effectiveStyle.maxLines = 0
            shapeMaxW = nil
            effectivePretty = false
        } else if effectiveStyle.wrap == .noWrap && effectiveStyle.maxLines == 0 {
            shapeMaxW = nil
            effectivePretty = false
        }
        if let rasterWindow, emitGlyphs, !(bypassCache ?? isSecure) {
            return textSystem.layoutKeyed(text: displayedText, spans: spans, pills: pills,
                                          style: effectiveStyle, maxWidth: shapeMaxW, pixelScale: pixelScale,
                                          emitGlyphs: true, glidePx: glidePx, pretty: effectivePretty,
                                          rasterWindow: rasterWindow).shaped
        }
        return textSystem.shape(
            text: displayedText,
            spans: spans,
            pills: pills,
            style: effectiveStyle,
            maxWidth: shapeMaxW,
            pixelScale: pixelScale,
            emitGlyphs: emitGlyphs,
            glidePx: glidePx,
            bypassCache: bypassCache ?? isSecure,
            pretty: effectivePretty
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

    private static func buildInputPills<State>(
        el: El<State>,
        specPills: [(Range<Int>, String)],
        defaultPillBg: Color,
        defaultPillFg: Color?
    ) -> [PillChip] {
        var pills: [PillChip] = []
        pills.reserveCapacity(specPills.count)
        for (pRange, pillId) in specPills {
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
        }
        return pills
    }

    static func preResolveInputPills<State>(el: inout El<State>, edit inputEdit: TextEdit) {
        var edit = inputEdit
        edit.applyFieldLineMode(singleLine: el.fieldSingleLine)
        if el.isSecure {
            edit.isSecure = true
            if el.isRevealed { edit.isRevealed = true }
        }
        let isSecureHidden = edit.isSecure && !edit.isRevealed
        guard !isSecureHidden, edit.isRichEnabled else { return }
        let richStyle = el.richStyleSpec ?? RichStyle()
        var inputStyle = el.textStyle
        inputStyle.maxLines = 0
        let specs = edit.richDisplaySpecs(baseStyle: inputStyle, style: richStyle)
        let specRanges = specs.pills.map(\.0)
        if el.runtimeExtras["resolvedPillInputPills"] is [PillChip],
           let cachedRanges = el.runtimeExtras["resolvedPillInputRanges"] as? [Range<Int>],
           let cachedText = el.runtimeExtras["resolvedPillInputText"] as? String,
           cachedText == specs.displayText && cachedRanges == specRanges {
            return
        }
        let defaultPillBg = el.pillColorsSpec?.bg ?? richStyle.link.alpha(0.2)
        let defaultPillFg = el.pillColorsSpec?.fg
        let pills = buildInputPills(
            el: el,
            specPills: specs.pills,
            defaultPillBg: defaultPillBg,
            defaultPillFg: defaultPillFg
        )
        el.runtimeExtras["pillChips"] = pills
        el.runtimeExtras["resolvedPillInputPills"] = pills
        el.runtimeExtras["resolvedPillInputRanges"] = specRanges
        el.runtimeExtras["resolvedPillInputText"] = specs.displayText
    }

    static func resolveInput<State>(
        el: El<State>,
        edit inputEdit: TextEdit,
        innerWidth: Float? = nil,
        pxScale: Float? = nil,
        fallbackDirection: TextFlow? = nil
    ) -> ElResolvedInput {
        var edit = inputEdit
        edit.applyFieldLineMode(singleLine: el.fieldSingleLine)
        if el.isSecure {
            edit.isSecure = true
            if let rev = el.revealedOverride { edit.isRevealed = rev }
        }
        let richStyle = el.richStyleSpec ?? RichStyle()
        let isSingle = !edit.multiline
        var inputStyle = el.textStyle
        inputStyle.maxLines = 0
        if inputStyle.wrap == .ellipsis {
            inputStyle.wrap = edit.multiline ? .wrap : .noWrap
        }
        if isSingle {
            inputStyle.wrap = .noWrap
            inputStyle.wrapAnywhere = false
        } else if edit.multiline {
            inputStyle.wrap = .wrap
            if edit.isSecure {
                inputStyle.wrapAnywhere = true
            }
        }
        if let fDir = edit.forcedDir {
            inputStyle.direction = fDir
        } else if let fallbackDirection {
            inputStyle.direction = fallbackDirection
        }

        // On the element it holds its resolved flow for `dirByParagraph`; the shaped style says
        // whether the field lays out by paragraph (`applyByParagraph`).
        let plaintextStart = el.textStyle.byParagraphStart
        inputStyle.byParagraphStart = nil
        // A wrapping field wraps at `w * scale + FIT_SLACK` device px, as every text lays out (#948).
        let wrapsAt: Float? = pxScale.flatMap { TextBoxGeometry.wrapWidth(innerWidth, scale: $0) } ?? innerWidth
        let shapeMaxW: Float? = (!isSingle && inputStyle.wrap != .noWrap) ? wrapsAt : (inputStyle.direction == .rtl ? innerWidth : nil)
        let isSecureHidden = edit.isSecure && !edit.isRevealed
        if isSecureHidden {
            inputStyle.wrap = .noWrap
            inputStyle.wrapAnywhere = false
        }
        let rawDisplay = edit.displayString
        let showingPlaceholder = rawDisplay.isEmpty && (edit.preedit?.text.isEmpty ?? true)
        if showingPlaceholder {
            var placeholderStyle = el.placeholderFont ?? inputStyle
            placeholderStyle.maxLines = 0
            placeholderStyle.wrap = inputStyle.wrap
            // A placeholder is laid out in its own direction, as one text.
            placeholderStyle.byParagraphStart = nil
            let blocks = edit.isRichEnabled && !edit.isSecure ? edit.blocks : []
            placeholderStyle.placeholderIndent = blocks.first?.indentPt(fontSize: inputStyle.size) ?? 0
            if let fDir = edit.forcedDir {
                placeholderStyle.direction = fDir
            } else if placeholderStyle.direction == nil, let fallbackDirection {
                placeholderStyle.direction = fallbackDirection
            }
            return ElResolvedInput(
                displayString: rawDisplay,
                renderedString: el.placeholder ?? "",
                showingPlaceholder: true,
                spans: nil,
                pills: [],
                style: placeholderStyle,
                isSingleLine: isSingle,
                isRich: false,
                isSecure: edit.isSecure,
                richStyle: richStyle,
                maxWidthForShape: (!isSingle && placeholderStyle.wrap != .noWrap) ? wrapsAt : (placeholderStyle.direction == .rtl ? innerWidth : nil),
                blocks: blocks
            )
        }

        let decorations = el.inputDecorations
        let isRich = !isSecureHidden && (edit.isRichEnabled || !decorations.isEmpty || el.pillColorsSpec != nil || el.pillIconLookup != nil || el.pillStyleLookup != nil || el.richStyleSpec != nil)
        if !isRich {
            Self.applyByParagraph(&inputStyle, plaintextStart: plaintextStart, el: el, edit: edit, isSingle: isSingle, display: rawDisplay)
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
                maxWidthForShape: shapeMaxW
            )
        }

        let specs = edit.richDisplaySpecs(baseStyle: inputStyle, style: richStyle)
        if specs.blocks.contains(where: { $0 != .paragraph }) {
            inputStyle.paragraphBlocks = specs.blocks
        }
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
        let pills: [PillChip]
        if let cachedPills = el.runtimeExtras["resolvedPillInputPills"] as? [PillChip],
           let cachedRanges = el.runtimeExtras["resolvedPillInputRanges"] as? [Range<Int>],
           let cachedText = el.runtimeExtras["resolvedPillInputText"] as? String,
           cachedText == specs.displayText && cachedRanges == specs.pills.map(\.0) {
            pills = cachedPills
        } else {
            pills = buildInputPills(
                el: el,
                specPills: specs.pills,
                defaultPillBg: defaultPillBg,
                defaultPillFg: defaultPillFg
            )
        }
        for pill in pills {
            let resolvedFg = pill.style.color
            if resolvedFg != nil || pill.style.bold || pill.style.italic || pill.style.mono {
                var sp = RichSpan(pill.range)
                if let fg = resolvedFg { sp = sp.color(fg) }
                if pill.style.bold { sp = sp.weight(700) }
                if pill.style.italic { sp = sp.italic(true) }
                if pill.style.mono { sp = sp.mono(true) }
                combinedSpans.append(sp)
            }
        }

        Self.applyByParagraph(&inputStyle, plaintextStart: plaintextStart, el: el, edit: edit, isSingle: isSingle, display: specs.displayText)
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
            maxWidthForShape: shapeMaxW,
            blocks: specs.blocks
        )
    }

    /// `TextSpec::by_paragraph` / `paragraphs_flow` / `plaintext_flow` for a field's shaped style:
    /// a wrapped multi-line field (not secure) lays out by paragraph when its text holds more than
    /// one paragraph, or always under `El.dirByParagraph` (`TextDir::Plaintext`). Then every
    /// paragraph reads the way the element does, else the whole text's first strong character
    /// does, as one layout of it would; under `dirByParagraph` (unless the edit forces a
    /// direction, `TextDir::Fixed`) each reads its own way, starting from the element's flow
    /// (`plaintextStart`, left to right when nothing above sets one).
    static func applyByParagraph<State>(_ style: inout TextStyle, plaintextStart: TextFlow?, el: El<State>, edit: TextEdit, isSingle: Bool, display: String) {
        style.byParagraphStart = nil
        let plaintext = el.textDirByParagraph && edit.forcedDir == nil
        guard !isSingle, edit.multiline, !edit.isSecure, style.wrap == .wrap, style.maxLines == 0,
              plaintext || display.utf8.contains(0x0a) else { return }
        if plaintext {
            style.direction = nil
            style.byParagraphStart = plaintextStart ?? .ltr
        } else {
            let flow = style.direction ?? (Direction.of(display) == .rtl ? .rtl : .ltr)
            style.direction = flow
            style.byParagraphStart = flow
        }
    }

    static func resolveText<State>(
        el: borrowing El<State>,
        rawText: String?,
        isSecure: Bool,
        fallbackDirection: TextFlow? = nil
    ) -> ElResolvedText {
        var style = el.textStyle
        if (el.runtimeExtra("htmlWrapAnywhere") as? Bool == true) || (el.runtimeExtra("shell.wrapAnywhere") as? Bool == true) {
            style.wrapAnywhere = true
            if style.wrap == .noWrap {
                style.wrap = .wrap
            }
        }
        if let fallbackDirection, style.direction == nil {
            style.direction = fallbackDirection
        }

        // Unwrapped labels align the whole layout within their box during painting. Their
        // individual lines start at their paragraph's leading edge.
        if style.wrap == .noWrap || el.isTruncateFadeEnabled {
            style.align = .leading
        }

        let authored: String
        if let rawText {
            authored = rawText
        } else if let rawSpans = el.richSpans, !rawSpans.isEmpty {
            if rawSpans.count == 1 {
                authored = rawSpans[0].text
            } else {
                var total = 0
                for sp in rawSpans { total += sp.text.utf8.count }
                var joined = ""
                joined.reserveCapacity(total)
                for sp in rawSpans { joined.append(sp.text) }
                authored = joined
            }
        } else {
            authored = ""
        }
        let isHiddenSecure = isSecure && !el.isRevealed && !authored.isEmpty
        let caseMode: TextCase? = isHiddenSecure ? nil : el.textCaseValue

        let caseMap: TextCaseMapping?
        let displayedText: String
        let resolvedSpans: [TextSpan]?
        if let rawSpans = el.richSpans, !rawSpans.isEmpty, !isHiddenSecure {
            if let caseMode {
                let joined = rawText == nil ? authored : rawSpans.map(\.text).joined()
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

        let isPretty = TextSystem.prettyWrap &&
            !el.isWrapGreedy &&
            !isHiddenSecure &&
            style.align != .justified &&
            style.maxLines == 0 &&
            style.wrap == .wrap &&
            !el.isTruncateFadeEnabled

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
            truncateFadeEm: el.truncateFadeEm,
            pretty: isPretty
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
        exactInnerWPx: Float? = nil,
        layoutInnerW: Float? = nil,
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
        let sc = max(1e-4, scaleVec.x)
        let laidWidth = layoutInnerW ?? (innerW / sc)
        let fullWidthPx = shaped.size.x * pxScale
        let laidOutPx = max(0, laidWidth) * pxScale
        let boxX = textOriginX * pxScale
        let boxY = textOriginY * pxScale
        let boxW = max(0, innerW) * pxScale
        let boxH = max(0, max(innerH, shaped.size.y * scaleVec.y)) * pxScale
        let exactW = max(0, exactInnerWPx ?? boxW)
        let overflows = fullWidthPx > laidOutPx + 0.5 && fullWidthPx * sc > max(boxW, exactW) + 0.5 * sc
        let isRtl: Bool
        if let dir = shaped.forcedDirection ?? el.textStyle.direction {
            isRtl = (dir == .rtl)
        } else {
            isRtl = shaped.primaryIsRTL
        }
        var boxLeftPx = boxX
        var boxRightPx = boxX + boxW
        if !overflows {
            let needed = max(exactW, fullWidthPx * sc)
            if isRtl {
                boxLeftPx = min(boxLeftPx, boxRightPx - needed)
            } else {
                boxRightPx = max(boxRightPx, boxLeftPx + needed)
            }
        }
        let boxBoundsPx = SIMD4<Float>(boxLeftPx, boxY, boxRightPx, boxY + boxH)
        let x0 = max(baseClipPx.x, boxBoundsPx.x)
        let y0 = max(baseClipPx.y, boxBoundsPx.y)
        let x1 = min(baseClipPx.x + baseClipPx.z, boxBoundsPx.z)
        let y1 = min(baseClipPx.y + baseClipPx.w, boxBoundsPx.w)
        let clipped = SIMD4<Float>(x0, y0, max(0, x1 - x0), max(0, y1 - y0))
        guard overflows else {
            return (clipped, .zero, boxBoundsPx, .zero, .zero, false)
        }
        let fadeW = min(el.textStyle.size * el.truncateFadeEm * scaleVec.x * pxScale, max(0, x1 - x0))
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
