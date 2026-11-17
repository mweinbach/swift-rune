import Foundation
import RuneMotion
import RuneRef
import RuneTaffy

/// One element of an exported static HTML tree (`--html`), in document order.
public struct ExportNode: Sendable, Equatable {
    public struct Declaration: Sendable, Equatable {
        public var property: String
        public var value: String

        public init(_ property: String, _ value: String) {
            self.property = property
            self.value = value
        }
    }

    public var path: String
    public var depth: Int
    public var tag: String
    /// Attributes besides `class`, already escaped (e.g. ` id="views" href="..."`).
    public var attrs: String
    /// Inner HTML for text and shapes; children follow otherwise.
    public var inner: String
    /// CSS declarations, property then value.
    public var decls: [Declaration]
    /// Laid-out width in points, which an image's `sizes` follows across widths.
    public var width: Float
    /// A text element: its children are inline runs, not elements.
    public var text: Bool

    public init(
        path: String,
        depth: Int,
        tag: String,
        attrs: String = "",
        inner: String = "",
        decls: [Declaration] = [],
        width: Float,
        text: Bool
    ) {
        self.path = path
        self.depth = depth
        self.tag = tag
        self.attrs = attrs
        self.inner = inner
        self.decls = decls
        self.width = width
        self.text = text
    }
}

/// Inline hyperlink byte range within a text element (`[utf8Start, utf8End)` -> `url`).
public struct HTMLLink: Sendable, Equatable, Hashable {
    public var startUTF8: Int
    public var endUTF8: Int
    public var url: String

    public init(_ range: Range<Int>, url: String) {
        self.startUTF8 = range.lowerBound
        self.endUTF8 = range.upperBound
        self.url = url
    }
}

/// Proportional gradient specification for CSS radial/angled background export.
public struct HTMLGradientSpec: Sendable, Equatable {
    public enum Geometry: Sendable, Equatable {
        case radial(center: Vec2, radius: Vec2)
        case linear(angleRadians: Float)
    }

    public var geometry: Geometry
    public var stops: [(Float, Color)]

    public init(geometry: Geometry, stops: [(Float, Color)]) {
        self.geometry = geometry
        self.stops = stops
    }

    public static func == (lhs: HTMLGradientSpec, rhs: HTMLGradientSpec) -> Bool {
        guard lhs.geometry == rhs.geometry, lhs.stops.count == rhs.stops.count else { return false }
        return zip(lhs.stops, rhs.stops).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

/// Image `object-fit` mode for static HTML `<img>` export.
public enum HTMLObjectFit: String, Sendable, Equatable, Hashable {
    case fill
    case fit = "contain"
    case cover = "cover"
}

public extension El {
    /// Sets a raw ARIA/HTML semantic role tag string (including web landmark/table roles such as
    /// `"main"`, `"navigation"`, `"banner"`, `"contentinfo"`, `"region"`, `"article"`,
    /// `"complementary"`, `"list"`, `"listitem"`, `"figure"`, `"table"`, `"row"`, `"cell"`,
    /// `"columnheader"`, `"rowheader"`).
    func htmlRole(_ rawRole: String) -> Self {
        var copy = self
        copy.runtimeExtras["htmlRole"] = rawRole
        switch rawRole {
        case "main": copy.role = .main
        case "region": copy.role = .region
        case "heading": copy.role = .heading
        case "listitem": copy.role = .listItem
        case "row": copy.role = .row
        case "columnheader": copy.role = .columnHeader
        case "image", "img": copy.role = .image
        case "link": copy.role = .link
        case "button": copy.role = .button
        default: break
        }
        return copy
    }

    /// Attaches inline `<a href="...">` UTF-8 byte ranges for static HTML export.
    func htmlLinks(_ links: [HTMLLink]) -> Self {
        var copy = self
        copy.runtimeExtras["htmlLinks"] = links
        return copy
    }

    /// Appends one inline `<a href="...">` UTF-8 byte range for static HTML export.
    func htmlLink(_ range: Range<Int>, _ url: String) -> Self {
        var copy = self
        var existing = (copy.runtimeExtras["htmlLinks"] as? [HTMLLink]) ?? []
        existing.append(HTMLLink(range, url: url))
        copy.runtimeExtras["htmlLinks"] = existing
        return copy
    }

    /// Allows wrapping anywhere inside long tokens (`overflow-wrap: anywhere` in HTML/CSS & native text).
    func wrapAnywhere(_ enabled: Bool = true) -> Self {
        applyWrapAnywhere(enabled)
    }

    /// Sets justified text alignment for static HTML export (`text-align: justify`).
    func textJustify(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.runtimeExtras["htmlTextJustify"] = enabled
        return copy
    }

    /// Marks subtree unselectable (`user-select: none` in page mode).
    func unselectable(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.runtimeExtras["htmlUnselectable"] = enabled
        return copy
    }

    /// Records proportional radial gradient geometry & stops for static HTML CSS export.
    func radialGradient(center: Vec2, radius: Vec2, stops: [(Float, Color)]) -> Self {
        var copy = self
        copy.runtimeExtras["htmlRadialSpec"] = HTMLGradientSpec(
            geometry: .radial(center: center, radius: radius),
            stops: stops
        )
        if let first = stops.first?.1, let last = stops.last?.1 {
            copy.gradient = .radial(inner: first, outer: last)
        }
        return copy
    }

    /// Records external image `src` / `srcset` / `object-fit` metadata for `<img>` export.
    func htmlImageSource(url: String, sourceSet: String? = nil, objectFit: HTMLObjectFit? = nil) -> Self {
        var copy = self
        copy.runtimeExtras["htmlImageUrl"] = url
        if let sourceSet { copy.runtimeExtras["htmlImageSrcSet"] = sourceSet }
        if let objectFit { copy.runtimeExtras["htmlImageFit"] = objectFit }
        return copy
    }
}

/// Static HTML & CSS generator (`--html`, `--html-widths`, `--html-template`).
public enum ToolingHTML {
    public static let settleFrames: Int = 240
    public static let cssMarker = "<!-- rune:css -->"
    public static let bodyMarker = "<!-- rune:body -->"
    public static let defaultTemplate =
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>:root{--rune-sans:system-ui,sans-serif;--rune-mono:ui-monospace,monospace}body{margin:0}</style><!-- rune:css --></head><body><!-- rune:body --></body></html>"

    /// Escapes HTML text and attribute values.
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            default: out.append(ch)
            }
        }
        return out
    }

    /// Places `css` and `body` into `template` at `<!-- rune:css -->` and `<!-- rune:body -->`,
    /// or before `</head>` and immediately after `<body...>` when markers are absent.
    public static func fill(template: String, css: String, body: String) -> String {
        let style = "<style data-rune-static>\(css)</style>"
        let withCSS: String
        if let r = template.range(of: cssMarker) {
            var copy = template
            copy.replaceSubrange(r, with: style)
            withCSS = copy
        } else if let r = template.range(of: "</head>") {
            withCSS = String(template[..<r.lowerBound]) + style + String(template[r.lowerBound...])
        } else {
            withCSS = style + template
        }

        if let r = withCSS.range(of: bodyMarker) {
            var copy = withCSS
            copy.replaceSubrange(r, with: body)
            return copy
        }

        if let bodyOpen = withCSS.range(of: "<body"),
           let closeBracket = withCSS[bodyOpen.lowerBound...].firstIndex(of: ">") {
            let insertAt = withCSS.index(after: closeBracket)
            return String(withCSS[..<insertAt]) + body + String(withCSS[insertAt...])
        }
        return withCSS + body
    }

    /// Lands entrance motion and steps until settled or `settleFrames` (240 frames at 60 Hz) pass.
    public static func settle<State>(_ runtime: Runtime<State>) {
        runtime.markNeedsCommit(settle: true)
        _ = runtime.frame(at: 0.0)
        // Second initial commit lets `cx.layoutSize` / layout-read feedback observe the settled viewport.
        runtime.markNeedsCommit(settle: true)
        _ = runtime.frame(at: 0.0)
        var t = 0.0
        for _ in 0..<settleFrames {
            if !runtime.isAnimating && !runtime.hasPendingCommit { break }
            t += 1.0 / 60.0
            _ = runtime.frame(at: t)
        }
    }

    public enum ExportError: Error, LocalizedError, Equatable {
        case unknownScene(String)

        public var errorDescription: String? {
            switch self {
            case .unknownScene(let name): return "unknown scene '\(name)'"
            }
        }
    }

    /// Exports an `AppSpec` across one or more responsive widths as complete static HTML.
    public static func renderHTML<State>(
        spec: AppSpec<State>,
        widths: [Float] = [],
        height: Float? = nil,
        scale: Float = 2.0,
        dark: Bool = true,
        fitHeight: Bool = false,
        document: Bool = false,
        template: String? = nil,
        sceneName: String? = nil
    ) throws -> (html: String, elementCount: Int, widths: [Float]) {
        var resolvedWidths = widths.isEmpty ? [spec.size.x] : widths
        resolvedWidths.sort()
        var deduped: [Float] = []
        for w in resolvedWidths where deduped.last != w {
            deduped.append(w)
        }
        guard let firstWidth = deduped.first else {
            return ("", 0, [])
        }
        let targetHeight = height ?? spec.size.y
        let resolvedScale = max(0.5, scale)
        var state = spec.makeState()
        var initTx = Tx()
        if let sceneName, !sceneName.isEmpty {
            guard let applyScene = spec.scenes[sceneName] else {
                throw ExportError.unknownScene(sceneName)
            }
            applyScene(&state, &initTx)
        }

        let runtime = Runtime<State>(
            state: state,
            viewport: Vec2(firstWidth, targetHeight),
            pixelScale: resolvedScale,
            systemDark: dark,
            onKey: spec.onKey,
            view: spec.view
        )
        // The capture presets (`RUNE_CONTRAST`, `RUNE_INCREASE_CONTRAST`) as `tooling::runtime_for` applies them (#981).
        runtime.applyCapturePresets()
        runtime.applyTx(initTx, at: 0.0, markDirtyIfNotLiveOnly: false)
        if document { runtime.setPageMode(true) }
        _ = fitHeight // preserved for API parity with WebAppConfig.fitContentHeight

        var taken: [(Float, [ExportNode])] = []
        taken.reserveCapacity(deduped.count)
        for w in deduped {
            runtime.viewport = Vec2(w, targetHeight)
            runtime.pixelScale = resolvedScale
            settle(runtime)
            taken.append((w, runtime.exportHTMLNodes()))
        }
        let (body, css) = HTMLPageExporter.page(taken)
        let html = fill(template: template ?? defaultTemplate, css: css, body: body)
        return (html, taken.first?.1.count ?? 0, deduped)
    }

    /// Exports static HTML directly to `outputPath` (supporting CLI `--html`, `--html-widths`, `--html-template`).
    public static func exportToFile<State>(
        spec: AppSpec<State>,
        outputPath: String,
        widths: [Float] = [],
        height: Float? = nil,
        scale: Float = 2.0,
        dark: Bool = true,
        fitHeight: Bool = false,
        document: Bool = false,
        templatePath: String? = nil,
        sceneName: String? = nil
    ) throws -> (elementCount: Int, widths: [Float]) {
        let tpl: String?
        if let templatePath {
            tpl = try String(contentsOfFile: templatePath, encoding: .utf8)
        } else {
            tpl = nil
        }
        let result = try renderHTML(
            spec: spec,
            widths: widths,
            height: height,
            scale: scale,
            dark: dark,
            fitHeight: fitHeight,
            document: document,
            template: tpl,
            sceneName: sceneName
        )
        let url = URL(fileURLWithPath: outputPath)
        let dir = url.deletingLastPathComponent()
        if !dir.path.isEmpty {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try result.html.write(to: url, atomically: true, encoding: .utf8)
        return (result.elementCount, result.widths)
    }
}

// MARK: - Page & CSS Folding

/// Multi-width CSS deduplication and responsive `@media (min-width:...)` generator.
public enum HTMLPageExporter {
    public static let baseCSS =
        "[data-rune-static],[data-rune-static] *{box-sizing:border-box;display:flex;position:relative;margin:0;padding:0;min-width:0;border:0 solid transparent}[data-rune-static] a{color:inherit;text-decoration:none}[data-rune-static] .t>*{display:inline;position:static}[data-rune-static] img{display:block}:where([data-rune-static]) img{height:auto}[data-rune-static] svg{display:block;position:absolute;inset:0}"

    private static let rangePrefix = ["a", "b", "c", "d", "e", "f"]

    private static func initialValue(for prop: String) -> String {
        switch prop {
        case "display": return "flex"
        case "position": return "relative"
        case "min-width": return "0"
        case "border-width": return "0"
        case "margin", "padding": return "0"
        case "flex-direction": return "row"
        case "flex-wrap": return "nowrap"
        case "flex-grow", "row-gap", "column-gap", "border-radius": return "0"
        case "flex-shrink", "opacity": return "1"
        case "background", "box-shadow", "filter", "backdrop-filter": return "none"
        default: return "unset"
        }
    }

    private static func base36(_ value: Int) -> String {
        let digits = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var n = max(0, value)
        var out: [Character] = []
        repeat {
            out.append(digits[n % 36])
            n /= 36
        } while n > 0
        return String(out.reversed())
    }

    /// Folds snapshots taken at one or more ascending widths into `(body, css)`.
    public static func page(_ widths: [(Float, [ExportNode])]) -> (body: String, css: String) {
        guard let (_, primary) = widths.first else { return ("", "") }
        let capped = Array(widths.prefix(rangePrefix.count))

        var byPath: [[String: ExportNode]] = []
        byPath.reserveCapacity(capped.count)
        for (_, nodes) in capped {
            var map: [String: ExportNode] = [:]
            map.reserveCapacity(nodes.count)
            for node in nodes { map[node.path] = node }
            byPath.append(map)
        }

        var classes: [[String: String]] = Array(repeating: [:], count: capped.count)
        var nodeClasses: [[String]] = []
        nodeClasses.reserveCapacity(primary.count)

        for node in primary {
            let found: [ExportNode?] = byPath.map { $0[node.path] }
            var props: [String] = []
            for case let n? in found {
                for decl in n.decls where !props.contains(decl.property) {
                    props.append(decl.property)
                }
            }
            if found.contains(where: { $0 == nil }) && !props.contains("display") {
                props.append("display")
            }

            var mine: [String] = []
            var lastText: String? = nil
            for (k, maybeNode) in found.enumerated() {
                let text: String
                if let n = maybeNode {
                    text = props.map { prop in
                        let v = n.decls.last(where: { $0.property == prop })?.value ?? initialValue(for: prop)
                        return "\(prop):\(v)"
                    }.joined(separator: ";")
                } else {
                    text = "display:none"
                }

                // Only the base width writes a rule that sets nothing.
                if lastText != text && !(k == 0 && text.isEmpty) {
                    if let existing = classes[k][text] {
                        mine.append(existing)
                    } else {
                        let name = "\(rangePrefix[k])\(base36(classes[k].count))"
                        classes[k][text] = name
                        mine.append(name)
                    }
                }
                lastText = text
            }
            nodeClasses.append(mine)
        }

        var css = baseCSS
        for (k, rules) in classes.enumerated() {
            var block = ""
            let sorted = rules.sorted {
                if $0.value.count != $1.value.count { return $0.value.count < $1.value.count }
                return $0.value < $1.value
            }
            for (decls, name) in sorted {
                block += ".\(name){\(decls)}"
            }
            if k == 0 {
                css += block
            } else if !block.isEmpty {
                css += "@media (min-width:\(HTMLCSSExporter.num(capped[k].0))px){\(block)}"
            }
        }

        var body = ""
        var openTags: [String] = []
        for (node, cls) in zip(primary, nodeClasses) {
            while openTags.count > node.depth, let closing = openTags.popLast() {
                body += "</\(closing)>"
            }
            var names: [String] = []
            if node.text { names.append("t") }
            names.append(contentsOf: cls)
            let classAttr = names.isEmpty ? "" : " class=\"\(names.joined(separator: " "))\""
            let rootAttr = node.depth == 0 ? " data-rune-static" : ""
            let sizesAttr = node.attrs.contains(" srcset=") ? sizes(for: node, widths: capped, byPath: byPath) : ""
            body += "<\(node.tag)\(rootAttr)\(classAttr)\(node.attrs)\(sizesAttr)>"
            if node.tag == "img" { continue }
            body += node.inner
            openTags.append(node.tag)
        }
        while let closing = openTags.popLast() {
            body += "</\(closing)>"
        }
        return (body, css)
    }

    private static func sizes(
        for node: ExportNode,
        widths: [(Float, [ExportNode])],
        byPath: [[String: ExportNode]]
    ) -> String {
        func vw(_ k: Int) -> Float? {
            guard widths[k].0 > 0, let found = byPath[k][node.path] else { return nil }
            return ceilf((found.width / widths[k].0) * 100.0)
        }
        var parts: [String] = []
        if widths.count > 1 {
            for k in (1..<widths.count).reversed() {
                if let v = vw(k) {
                    parts.append("(min-width:\(HTMLCSSExporter.num(widths[k].0))px) \(HTMLCSSExporter.num(v))vw")
                }
            }
        }
        parts.append("\(HTMLCSSExporter.num(vw(0) ?? 100.0))vw")
        return " sizes=\"\(parts.joined(separator: ","))\""
    }
}

// MARK: - CSS & Markup Serialization

public enum HTMLCSSExporter {
    public typealias Decl = ExportNode.Declaration

    public static func num(_ v: Float) -> String {
        let rounded = (v * 100.0).rounded() / 100.0
        let normalized: Float = (rounded == 0) ? 0 : rounded
        if normalized == normalized.rounded(.towardZero),
           normalized >= Float(Int64.min / 2),
           normalized <= Float(Int64.max / 2) {
            return String(Int64(normalized))
        }
        return String(format: "%g", Double(normalized))
    }

    public static func px(_ v: Float) -> String {
        v == 0 ? "0" : "\(num(v))px"
    }

    public static func color(_ c: Color) -> String {
        c.hexString()
    }

    private static func dimCSS(_ dim: Dimension) -> String? {
        switch dim {
        case .auto: return "auto"
        case .points(let pt): return px(pt)
        case .fraction(let f): return "\(num(f * 100.0))%"
        case .minContent: return "min-content"
        case .maxContent: return "max-content"
        case .fitContentPx, .fitContentPercent: return nil
        }
    }

    public static func layout(_ style: LayoutStyle, root: Bool) -> [Decl] {
        var d: [Decl] = []
        func pushDim(_ prop: String, _ dim: Dimension, default def: String) {
            if let v = dimCSS(dim), v != def { d.append(Decl(prop, v)) }
        }
        func pushOptPx(_ prop: String, _ val: Float?) {
            if let val { d.append(Decl(prop, px(val))) }
        }

        if style.displayNone {
            d.append(Decl("display", "none"))
        } else {
            switch style.displayMode {
            case .flex: break
            case .grid: d.append(Decl("display", "grid"))
            case .block: d.append(Decl("display", "block"))
            }
        }

        switch style.direction {
        case .row: break
        case .column: d.append(Decl("flex-direction", "column"))
        case .rowReverse: d.append(Decl("flex-direction", "row-reverse"))
        case .columnReverse: d.append(Decl("flex-direction", "column-reverse"))
        }

        if style.wrapReverse {
            d.append(Decl("flex-wrap", "wrap-reverse"))
        } else if style.wrap {
            d.append(Decl("flex-wrap", "wrap"))
        }

        func alignString(_ a: AlignItems) -> String {
            switch a {
            case .start: return "flex-start"
            case .center: return "center"
            case .end: return "flex-end"
            case .stretch: return "stretch"
            }
        }
        func justifyString(_ j: JustifyContent) -> String {
            switch j {
            case .start: return "flex-start"
            case .center: return "center"
            case .end: return "flex-end"
            case .spaceBetween: return "space-between"
            case .spaceAround: return "space-around"
            case .spaceEvenly: return "space-evenly"
            }
        }

        if style.alignItems != .stretch {
            d.append(Decl("align-items", alignString(style.alignItems)))
        }
        if let selfAlign = style.alignSelf {
            d.append(Decl("align-self", alignString(selfAlign)))
        }
        if style.justifyContent != .start {
            d.append(Decl("justify-content", justifyString(style.justifyContent)))
        }
        if let ac = style.alignContent {
            d.append(Decl("align-content", justifyString(ac)))
        }

        if style.rowGap != 0 { d.append(Decl("row-gap", px(style.rowGap))) }
        if style.columnGap != 0 { d.append(Decl("column-gap", px(style.columnGap))) }
        if style.flexGrow != 0 { d.append(Decl("flex-grow", num(style.flexGrow))) }
        if style.flexShrink != 1 { d.append(Decl("flex-shrink", num(style.flexShrink))) }
        pushDim("flex-basis", style.flexBasis, default: "auto")

        if style.isAbsolute {
            d.append(Decl("position", "absolute"))
            pushOptPx("left", style.pinLeft)
            pushOptPx("right", style.pinRight)
            pushOptPx("top", style.pinTop)
            pushOptPx("bottom", style.pinBottom)
        }

        if root {
            d.append(Decl("width", "100%"))
        } else {
            pushDim("width", style.width, default: "auto")
            pushDim("height", style.height, default: "auto")
            pushDim("min-width", style.minWidth, default: "auto")
            pushDim("min-height", style.minHeight, default: "auto")
            pushDim("max-width", style.maxWidth, default: "auto")
            pushDim("max-height", style.maxHeight, default: "auto")
        }

        if let ar = style.aspectRatio {
            d.append(Decl("aspect-ratio", num(ar)))
        }

        func shorthand(_ s: Sides) -> String? {
            let vals = [px(s.top), px(s.right), px(s.bottom), px(s.left)]
            if vals.allSatisfy({ $0 == "0" }) { return nil }
            if vals[0] == vals[2] && vals[1] == vals[3] {
                return vals[0] == vals[1] ? vals[0] : "\(vals[0]) \(vals[1])"
            }
            return vals.joined(separator: " ")
        }

        if let m = shorthand(style.margin) { d.append(Decl("margin", m)) }
        if let p = shorthand(style.padding) { d.append(Decl("padding", p)) }
        if style.borderLayout, let b = shorthand(style.border) {
            d.append(Decl("border-width", b))
        }

        if style.scrollAxes.contains(.horizontal) {
            d.append(Decl("overflow-x", "auto"))
        } else if style.clipOverflow {
            d.append(Decl("overflow-x", "clip"))
        }
        if style.scrollAxes.contains(.vertical) {
            d.append(Decl("overflow-y", "auto"))
        } else if style.clipOverflow {
            d.append(Decl("overflow-y", "clip"))
        }

        return d
    }

    public static func paint<State>(_ el: El<State>, size: (Float, Float), into d: inout [Decl]) {
        var layers: [String] = []
        if let spec = el.runtimeExtras["htmlRadialSpec"] as? HTMLGradientSpec {
            layers.append(gradientCSS(spec, size: size))
        } else if let grad = el.gradient {
            switch grad {
            case let .radial(inner, outer):
                layers.append(gradientCSS(
                    HTMLGradientSpec(
                        geometry: .radial(center: Vec2(0.5, 0.5), radius: Vec2(size.0 * 0.5, size.1 * 0.5)),
                        stops: [(0.0, inner), (1.0, outer)]
                    ),
                    size: size
                ))
            case let .linear(top, bottom, angleRadians):
                if abs(angleRadians - (.pi * 0.5)) < 0.001 {
                    layers.append("linear-gradient(\(color(top)),\(color(bottom)))")
                } else {
                    let deg = angleRadians * 180.0 / .pi
                    layers.append("linear-gradient(\(num(deg))deg,\(color(top)),\(color(bottom)))")
                }
            }
        }
        if el.background.a > 0 {
            layers.append(color(el.background))
        }
        if !layers.isEmpty {
            d.append(Decl("background", layers.joined(separator: ",")))
        }

        if let fade = el.clipFade {
            maskCSS(fade, into: &d)
        }

        let r = [el.corners.topLeft, el.corners.topRight, el.corners.bottomRight, el.corners.bottomLeft]
        if r.contains(where: { $0 > 0 }) {
            let value = r.allSatisfy({ $0 == r[0] }) ? px(r[0]) : r.map(px).joined(separator: " ")
            d.append(Decl("border-radius", value))
        }

        let laidOutBorder = d.contains(where: { $0.property == "border-width" })
        var shadows: [String] = []
        if el.borderWidth > 0 && el.borderColor.a > 0 {
            if laidOutBorder {
                d.append(Decl("border-style", "solid"))
                d.append(Decl("border-color", color(el.borderColor)))
            } else if let sides = el.borderSides {
                let entries: [(Float, Float, Float)] = [
                    (0, sides.top, sides.top),
                    (-sides.right, 0, sides.right),
                    (0, -sides.bottom, sides.bottom),
                    (sides.left, 0, sides.left),
                ]
                for (x, y, w) in entries where w > 0 {
                    shadows.append("inset \(px(x)) \(px(y)) 0 0 \(color(el.borderColor))")
                }
            } else {
                shadows.append("inset 0 0 0 \(px(el.borderWidth)) \(color(el.borderColor))")
            }
        }

        for s in el.shadows {
            let inset = s.inset ? "inset " : ""
            shadows.append("\(inset)\(px(s.x)) \(px(s.y)) \(px(s.blur)) \(px(s.spread)) \(color(s.color))")
        }
        if !shadows.isEmpty {
            d.append(Decl("box-shadow", shadows.joined(separator: ",")))
        }

        if el.opacity < 0.999 {
            d.append(Decl("opacity", num(el.opacity)))
        }
        if el.clipFade != nil || el.clipRadius != nil || el.clipCorners != nil {
            if !d.contains(where: { $0.property.hasPrefix("overflow") }) {
                d.append(Decl("overflow", "hidden"))
            }
        }
        if el.backdropBlur > 0 {
            d.append(Decl("backdrop-filter", "blur(\(px(el.backdropBlur)))"))
        }
        if el.blur > 0 {
            d.append(Decl("filter", "blur(\(px(el.blur)))"))
        }
    }

    private static func gradientCSS(_ spec: HTMLGradientSpec, size: (Float, Float)) -> String {
        let stops = spec.stops.map { "\(color($0.1)) \(num($0.0 * 100.0))%" }.joined(separator: ",")
        switch spec.geometry {
        case let .radial(center, radius):
            func pct(_ r: Float, _ side: Float) -> String {
                side > 0 ? "\(num((r / side) * 100.0))%" : px(r)
            }
            return "radial-gradient(\(pct(radius.x, size.0)) \(pct(radius.y, size.1)) at \(num(center.x * 100.0))% \(num(center.y * 100.0))%,\(stops))"
        case let .linear(angle):
            let deg = angle * 180.0 / .pi
            return "linear-gradient(\(num(deg))deg,\(stops))"
        }
    }

    private static func maskCSS(_ fade: SIMD4<Float>, into d: inout [Decl]) {
        func ramp(to dir: String, _ a: Float, _ z: Float) -> String? {
            if a == 0 && z == 0 { return nil }
            func side(_ w: Float, fromEnd: Bool) -> [String] {
                let at = fromEnd ? "calc(100% - \(px(abs(w))))" : px(abs(w))
                let edge = fromEnd ? "100%" : "0"
                var s = ["transparent \(edge)", "#000 \(at)"]
                if fromEnd { s.reverse() }
                return s
            }
            var stops = (a != 0) ? side(a, fromEnd: false) : ["#000 0"]
            stops.append(contentsOf: (z != 0) ? side(z, fromEnd: true) : ["#000 100%"])
            return "linear-gradient(to \(dir),\(stops.joined(separator: ",")))"
        }
        let layers = [ramp(to: "right", fade.x, fade.z), ramp(to: "bottom", fade.y, fade.w)].compactMap { $0 }
        guard !layers.isEmpty else { return }
        let image = layers.joined(separator: ",")
        d.append(Decl("-webkit-mask-image", image))
        d.append(Decl("mask-image", image))
        if layers.count == 2 {
            d.append(Decl("-webkit-mask-composite", "source-in"))
            d.append(Decl("mask-composite", "intersect"))
        }
    }

    private static func familyCSS(_ family: FontFamily) -> String {
        switch family {
        case .systemUI: return "var(--rune-sans)"
        case .monospace: return "var(--rune-mono)"
        case .custom(let name): return "\"\(ToolingHTML.escape(name))\""
        }
    }

    public static func text<State>(_ el: El<State>, systemDark: Bool = true, into d: inout [Decl]) {
        let s = el.textStyle
        if !d.contains(where: { $0.property == "display" }) {
            d.append(Decl("display", "block"))
        }
        d.append(Decl("font-family", familyCSS(s.family)))
        d.append(Decl("font-size", px(s.size)))
        d.append(Decl("font-weight", num(s.weight)))
        let lh = s.lineHeight ?? (s.size * 1.25)
        d.append(Decl("line-height", px(lh)))
        if s.letterSpacing != 0 {
            d.append(Decl("letter-spacing", px(s.letterSpacing)))
        }
        if s.italic {
            d.append(Decl("font-style", "italic"))
        }
        let resolvedColor = el.textColor ?? Tok.theme(dark: systemDark).text
        d.append(Decl("color", color(resolvedColor)))

        switch s.align {
        case .leading: break
        case .center: d.append(Decl("text-align", "center"))
        case .trailing: d.append(Decl("text-align", "right"))
        case .justified: d.append(Decl("text-align", "justify"))
        }
        if (el.runtimeExtras["htmlTextJustify"] as? Bool) == true {
            d.append(Decl("text-align", "justify"))
        }
        if s.wrap == .ellipsis {
            d.append(Decl("white-space", "pre"))
            d.append(Decl("overflow", "hidden"))
            d.append(Decl("text-overflow", "ellipsis"))
        } else {
            d.append(Decl("white-space", s.wrap == .wrap ? "pre-wrap" : "pre"))
            if (el.runtimeExtras["htmlWrapAnywhere"] as? Bool) == true {
                d.append(Decl("overflow-wrap", "anywhere"))
            }
        }
    }

    public static func textHTML<State>(_ el: El<State>) -> String {
        let links = (el.runtimeExtras["htmlLinks"] as? [HTMLLink]) ?? []
        if let spans = el.richSpans {
            let full = spans.map(\.text).joined()
            if links.isEmpty {
                var out = ""
                for sp in spans {
                    let piece = ToolingHTML.escape(sp.text)
                    var style = ""
                    if let w = sp.weight { style += "font-weight:\(num(w));" }
                    if sp.monospace { style += "font-family:var(--rune-mono);" }
                    if let c = sp.color { style += "color:\(color(c));" }
                    if let bg = sp.background { style += "background:\(color(bg));border-radius:3px;padding:0 3px;" }
                    if sp.underline { style += "text-decoration:underline;" }
                    if sp.italic { style += "font-style:italic;" }
                    if style.isEmpty {
                        out += piece
                    } else {
                        let trimmed = style.hasSuffix(";") ? String(style.dropLast()) : style
                        out += "<span style=\"\(trimmed)\">\(piece)</span>"
                    }
                }
                return out
            }
            // Flatten spans into UTF-8 ranges so links split cleanly across spans too.
            var spanRanges: [(start: Int, end: Int, span: TextSpan)] = []
            var cursor = 0
            for sp in spans {
                let len = sp.text.utf8.count
                spanRanges.append((cursor, cursor + len, sp))
                cursor += len
            }
            return renderContentWithLinks(full, spanRanges: spanRanges, links: links)
        }
        let plain = el.plainText ?? el.liveText?.get() ?? ""
        return renderContentWithLinks(plain, spanRanges: [], links: links)
    }

    private static func renderContentWithLinks(
        _ content: String,
        spanRanges: [(start: Int, end: Int, span: TextSpan)],
        links: [HTMLLink]
    ) -> String {
        if links.isEmpty && spanRanges.isEmpty {
            return ToolingHTML.escape(content)
        }
        let utf8 = Array(content.utf8)
        let total = utf8.count
        var cuts: [Int] = [0, total]
        for s in spanRanges { cuts.append(s.start); cuts.append(s.end) }
        for l in links { cuts.append(l.startUTF8); cuts.append(l.endUTF8) }

        let validBounds: Set<Int> = {
            var set: Set<Int> = [0, total]
            var idx = content.startIndex
            while idx < content.endIndex {
                let off = content.utf8.distance(from: content.startIndex, to: idx)
                set.insert(off)
                idx = content.index(after: idx)
            }
            return set
        }()
        cuts = Array(Set(cuts.filter { $0 >= 0 && $0 <= total && validBounds.contains($0) })).sorted()

        var out = ""
        var openLink: Int? = nil
        for k in 0..<max(0, cuts.count - 1) {
            let a = cuts[k]
            let b = cuts[k + 1]
            if a == b { continue }
            let linkIdx = links.firstIndex(where: { $0.startUTF8 <= a && b <= $0.endUTF8 })
            if linkIdx != openLink {
                if openLink != nil { out += "</a>" }
                if let li = linkIdx {
                    out += "<a href=\"\(ToolingHTML.escape(links[li].url))\">"
                }
                openLink = linkIdx
            }
            let slice = String(decoding: utf8[a..<b], as: UTF8.self)
            let piece = ToolingHTML.escape(slice)
            var style = ""
            if let s = spanRanges.last(where: { $0.start <= a && b <= $0.end })?.span {
                if let w = s.weight { style += "font-weight:\(num(w));" }
                if s.monospace { style += "font-family:var(--rune-mono);" }
                if let c = s.color { style += "color:\(color(c));" }
                if let bg = s.background { style += "background:\(color(bg));border-radius:3px;padding:0 3px;" }
                if s.underline { style += "text-decoration:underline;" }
                if s.italic { style += "font-style:italic;" }
            }
            if style.isEmpty {
                out += piece
            } else {
                let trimmed = style.hasSuffix(";") ? String(style.dropLast()) : style
                out += "<span style=\"\(trimmed)\">\(piece)</span>"
            }
        }
        if openLink != nil { out += "</a>" }
        return out
    }

    public static func svg(_ shape: Shape, size: (Float, Float)) -> String {
        let vb = shape.viewBox ?? Vec2(size.0, size.1)
        var out =
            "<svg viewBox=\"0 0 \(num(vb.x)) \(num(vb.y))\" preserveAspectRatio=\"none\" width=\"100%\" height=\"100%\" aria-hidden=\"true\" focusable=\"false\" shape-rendering=\"crispEdges\">"

        func pointsStr(_ pts: [Vec2]) -> String {
            pts.map { "\(num($0.x)),\(num($0.y))" }.joined(separator: " ")
        }

        var currentFill: (Color, String)? = nil
        func flushFill() {
            if let (c, d) = currentFill {
                out += "<path fill=\"\(color(c))\" d=\"\(d)\"/>"
                currentFill = nil
            }
        }

        for op in shape.ops {
            switch op {
            case let .fill(pts, c):
                if let existing = currentFill, existing.0 != c {
                    flushFill()
                }
                let pathSeg = "M" + pointsStr(pts).replacingOccurrences(of: " ", with: "L") + "Z"
                if var existing = currentFill {
                    existing.1 += pathSeg
                    currentFill = existing
                } else {
                    currentFill = (c, pathSeg)
                }
            case let .stroke(pts, closed, width, cap, c):
                flushFill()
                let tag = closed ? "polygon" : "polyline"
                let capName = (cap == .round) ? "round" : "butt"
                out +=
                    "<\(tag) fill=\"none\" stroke=\"\(color(c))\" stroke-width=\"\(num(width))\" stroke-linecap=\"\(capName)\" stroke-linejoin=\"round\" vector-effect=\"non-scaling-stroke\" points=\"\(pointsStr(pts))\"/>"
            }
        }
        flushFill()
        out += "</svg>"
        return out
    }
}

// MARK: - Runtime HTML Export & Page Mode

private final class HTMLPageModeRegistry: @unchecked Sendable {
    static let shared = HTMLPageModeRegistry()
    private let lock = NSLock()
    private var pageModeIds: Set<ObjectIdentifier> = []

    func set(_ id: ObjectIdentifier, enabled: Bool) {
        lock.lock()
        if enabled {
            pageModeIds.insert(id)
        } else {
            pageModeIds.remove(id)
        }
        lock.unlock()
    }

    func contains(_ id: ObjectIdentifier) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pageModeIds.contains(id)
    }
}

private struct HTMLWalkEntry<State> {
    let el: El<State>
    let solved: LayoutEngine.ResultNode
    let path: String
    let origin: Vec2
    let parentSelects: Bool
    let isRoot: Bool
}

public extension Runtime {
    /// Marks this runtime as exporting a selectable web document page (mirrors `Runtime::page_mode()`).
    func setPageMode(_ enabled: Bool = true) {
        HTMLPageModeRegistry.shared.set(ObjectIdentifier(self), enabled: enabled)
    }

    /// True if `setPageMode(true)` was called for this runtime.
    var isPageMode: Bool {
        HTMLPageModeRegistry.shared.contains(ObjectIdentifier(self))
    }

    /// Exports the visible laid-out scene as static HTML `ExportNode`s at the runtime's current viewport.
    func exportHTMLNodes() -> [ExportNode] {
        let committed = elements()
        var committedByPath: [String: ElementInfo] = [:]
        committedByPath.reserveCapacity(committed.count)
        for item in committed {
            committedByPath[item.path] = item
        }

        let cx = Cx<State>(
            viewport: viewport,
            pixelScale: pixelScale,
            systemDark: systemDark,
            reducedMotion: reducedMotion,
            windowFocused: windowFocused,
            layoutRectLookup: { key in
                if let match = committed.first(where: { !$0.exiting && selectsElementSelector(key, path: $0.path, key: $0.key) }) {
                    return MotionRect.fromXYWH(match.rect[0], match.rect[1], match.rect[2], match.rect[3])
                }
                return nil
            }
        )
        var mutableCx = cx
        let rootEl = view(state, &mutableCx)
        let layoutCoord = RetainedLayoutCoordinator()
        let solvedRoot = layoutCoord.compute(
            root: rootEl,
            state: state,
            viewport: viewport,
            pixelScale: pixelScale,
            textSystem: TextSystem()
        )

        var out: [ExportNode] = []
        var stack: [(endDepth: Int, tag: String)] = []
        let pageMode = isPageMode

        func effectiveRole(_ el: El<State>) -> String {
            (el.runtimeExtras["htmlRole"] as? String) ?? el.role.rawValue
        }

        func takesPointer(_ el: El<State>, role: String) -> Bool {
            let h = el.handlers
            if h.onClick != nil || h.onClickPress != nil || h.onDoubleClick != nil
                || h.onSecondaryClick != nil || h.onMiddlePress != nil || h.onPointerDown != nil || h.onDrag != nil
                || h.editLens != nil || el.a11yHref != nil {
                return true
            }
            return ["button", "checkbox", "switch", "radio", "tab", "slider", "menuitem", "link", "textbox"].contains(role)
        }

        func containerTag(role: String) -> String? {
            switch role {
            case "main": return "main"
            case "navigation": return "nav"
            case "banner": return "header"
            case "contentinfo": return "footer"
            case "region": return "section"
            case "article": return "article"
            case "complementary": return "aside"
            case "list": return "ul"
            case "listitem": return "li"
            case "figure": return "figure"
            case "table", "row", "cell", "columnheader", "rowheader", "gridcell": return "div"
            default: return nil
            }
        }

        func ariaRole(role: String) -> String? {
            switch role {
            case "table", "row", "cell", "columnheader", "rowheader": return role
            case "gridcell": return "cell"
            default: return nil
            }
        }

        func anchorId(_ key: String?) -> String? {
            guard let key, let first = key.first, first.isASCII, first.isLetter else { return nil }
            let ok = key.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" || $0 == "_" }
            return ok ? key : nil
        }

        func visit(_ entry: HTMLWalkEntry<State>, depth: Int) {
            let el = entry.el
            let info = committedByPath[entry.path]
            if info?.exiting == true || info?.inert == true || el.isInert { return }
            let opacity = info?.opacity ?? el.opacity
            if opacity <= 0.01 || el.handlers.editLens != nil { return }

            let rect = entry.solved.layout.localRect
            let worldX = entry.origin.x + rect.x
            let worldY = entry.origin.y + rect.y
            let width = rect.width
            let height = rect.height

            let roleStr = effectiveRole(el)
            let inline = stack.contains { ["a", "h1", "h2", "h3", "h4", "h5", "h6", "span", "p"].contains($0.tag) }
            let hasText = el.plainText != nil || el.richSpans != nil || el.liveText != nil
            let isLeaf = el.children.isEmpty
            let imageURL = isLeaf ? (el.runtimeExtras["htmlImageUrl"] as? String) : nil

            let tag: String
            if let ct = containerTag(role: roleStr) {
                tag = ct
            } else if el.a11yHref != nil {
                tag = "a"
            } else if roleStr == "heading" {
                let lv = max(1, min(6, el.a11yLevel ?? 2))
                tag = "h\(lv)"
            } else if imageURL != nil {
                tag = "img"
            } else if hasText {
                tag = inline ? "span" : "p"
            } else if inline {
                tag = "span"
            } else {
                tag = "div"
            }

            var attrs = ""
            if ["a", "h1", "h2", "h3", "h4", "h5", "h6"].contains(tag) || containerTag(role: roleStr) != nil {
                if let id = anchorId(el.keyId) {
                    attrs += " id=\"\(id)\""
                }
            }
            if let aria = ariaRole(role: roleStr) {
                attrs += " role=\"\(aria)\""
            }
            if let href = el.a11yHref {
                attrs += " href=\"\(ToolingHTML.escape(href))\""
            }
            let trimmedLabel = el.a11yLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let nonEmptyLabel = (trimmedLabel?.isEmpty == false) ? el.a11yLabel : nil
            if let url = imageURL {
                attrs +=
                    " src=\"\(ToolingHTML.escape(url))\" alt=\"\(ToolingHTML.escape(nonEmptyLabel ?? ""))\" width=\"\(Int(width.rounded()))\" height=\"\(Int(height.rounded()))\" decoding=\"async\""
                if let srcset = el.runtimeExtras["htmlImageSrcSet"] as? String {
                    attrs += " srcset=\"\(ToolingHTML.escape(srcset))\""
                }
                if worldY > 900.0 {
                    attrs += " loading=\"lazy\""
                }
            } else if let l = nonEmptyLabel, !hasText, tag != "a" {
                let roleAttr = (roleStr == "image" || roleStr == "img") ? " role=\"img\"" : ""
                attrs += "\(roleAttr) aria-label=\"\(ToolingHTML.escape(l))\""
            }
            if el.isA11yHidden {
                attrs += " aria-hidden=\"true\""
            }

            var decls = HTMLCSSExporter.layout(el.layout, root: entry.isRoot)
            HTMLCSSExporter.paint(el, size: (width, height), into: &decls)
            var inner = ""
            if hasText {
                HTMLCSSExporter.text(el, systemDark: systemDark, into: &decls)
                inner = HTMLCSSExporter.textHTML(el)
            } else if let firstShape = el.shapes.first {
                inner = HTMLCSSExporter.svg(firstShape, size: (width, height))
            }
            if tag == "img" {
                let fit = (el.runtimeExtras["htmlImageFit"] as? HTMLObjectFit) ?? .fill
                decls.append(ExportNode.Declaration("object-fit", fit.rawValue))
            }

            let explicitSelectableRaw = el.runtimeExtras[El<State>.selectableExtraKey] as? Bool
            let unselectable = (el.runtimeExtras["htmlUnselectable"] as? Bool) == true
                || explicitSelectableRaw == false
            let explicitSelectable = el.isSelectable
            let mySelects: Bool
            if pageMode {
                mySelects = (entry.parentSelects && !unselectable && !takesPointer(el, role: roleStr)) || explicitSelectable
                if !mySelects && entry.parentSelects {
                    decls.append(ExportNode.Declaration("-webkit-user-select", "none"))
                    decls.append(ExportNode.Declaration("user-select", "none"))
                } else if explicitSelectable && !entry.parentSelects {
                    decls.append(ExportNode.Declaration("-webkit-user-select", "text"))
                    decls.append(ExportNode.Declaration("user-select", "text"))
                }
            } else {
                mySelects = false
            }

            out.append(ExportNode(
                path: entry.path,
                depth: depth,
                tag: tag,
                attrs: attrs,
                inner: inner,
                decls: decls,
                width: width,
                text: hasText
            ))

            if tag == "img" { return }

            stack.append((depth, tag))
            defer { _ = stack.popLast() }

            for (idx, childEl) in el.children.enumerated() {
                guard idx < entry.solved.children.count else { continue }
                let childSolved = entry.solved.children[idx]
                let childPath = childEl.keyId.map { "\(entry.path)/@\($0)" } ?? "\(entry.path)/\(idx)"
                visit(
                    HTMLWalkEntry(
                        el: childEl,
                        solved: childSolved,
                        path: childPath,
                        origin: Vec2(worldX, worldY),
                        parentSelects: mySelects,
                        isRoot: false
                    ),
                    depth: depth + 1
                )
            }
        }

        let rootPath = rootEl.keyId.map { "/@\($0)" } ?? "/0"
        visit(
            HTMLWalkEntry(
                el: rootEl,
                solved: solvedRoot,
                path: rootPath,
                origin: .zero,
                parentSelects: true,
                isRoot: true
            ),
            depth: 0
        )
        return out
    }
}
