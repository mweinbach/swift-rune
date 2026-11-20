// Port of upstream `crates/rune-text/src/icon/anim/parse.rs`:
// Bounded, pre-parsed monochrome SMIL SVG icon compiler.
//
// Enforces hard caps BEFORE allocating on every untrusted input dimension (body length, nesting
// depth, element count, shape count, opacity-layer count, animation track count, path bytes &
// commands, polyline points, keyframes, transform ops, clock ranges, and coordinate bounds).
// Shared cap numbers match OpenCode Desktop's SVG sanitizer (`opencode-plugin-runtime::svg`).

import Foundation
#if os(Android)
import Android
#endif

/// Shared defence-in-depth caps (matching `opencode-plugin-runtime::svg` and `icon/anim/parse.rs`).
internal enum SVGIconAnimLimits {
    static let maxSVGBytes: Int = 32 * 1024
    static let maxDepth: Int = 16
    static let maxElements: Int = 128
    static let maxShapes: Int = 64
    static let maxLayers: Int = 8
    static let maxAnimations: Int = 16
    static let maxPathBytes: Int = 16 * 1024
    static let maxPathCommands: Int = 1024
    static let maxPointsNumbers: Int = 1024
    static let maxKeyframes: Int = 64
    static let maxTransformOps: Int = 8
    static let minViewDim: Float = 1.0
    static let maxViewDim: Float = 4096.0
    static let minDurSecs: Float = 0.016
    static let maxClockSecs: Float = 3600.0
    static let maxRepeatCount: Float = 10_000.0
    static let maxCoord: Float = 4096.0
    static let maxStrokeWidth: Float = 256.0
    static let maxScale: Float = 64.0
    static let maxSkewDeg: Float = 85.0
    static let minSplineY: Float = -4.0
    static let maxSplineY: Float = 5.0
    static let maxAttrsPerTag: Int = 32

    static let nonRenderingTags: Set<String> = [
        "defs", "clipPath", "mask", "symbol", "linearGradient", "radialGradient", "pattern",
        "marker", "filter", "title", "desc", "metadata", "style", "script", "foreignObject",
    ]
}

internal enum SVGAnimTransformKind: Equatable, Hashable, Sendable {
    case translate
    case scale
    case rotate
    case skewX
    case skewY
}

internal enum SVGAnimAttrKind: Equatable, Hashable, Sendable {
    case r
    case cx
    case cy
    case rx
    case ry
    case x
    case y
    case width
    case height
    case x1
    case y1
    case x2
    case y2
    case opacity
    case fillOpacity
    case strokeOpacity
    case strokeWidth
    case transform(SVGAnimTransformKind)

    @inline(__always)
    var numericSlot: Int? {
        switch self {
        case .r: return 0
        case .cx: return 1
        case .cy: return 2
        case .rx: return 3
        case .ry: return 4
        case .x: return 5
        case .y: return 6
        case .width: return 7
        case .height: return 8
        case .x1: return 9
        case .y1: return 10
        case .x2: return 11
        case .y2: return 12
        case .opacity: return 13
        case .fillOpacity: return 14
        case .strokeOpacity: return 15
        case .strokeWidth: return 16
        case .transform: return nil
        }
    }
}

internal enum SVGAnimCalcMode: Equatable, Hashable, Sendable {
    case linear
    case discrete
    case spline
    case paced
}

internal struct SVGAnimKeyVal: Equatable, Sendable {
    var v0: Float
    var v1: Float
    var v2: Float
    var len: UInt8

    init(_ v0: Float, _ v1: Float = 0, _ v2: Float = 0, len: UInt8) {
        self.v0 = v0
        self.v1 = v1
        self.v2 = v2
        self.len = len
    }

    static func scalar(_ x: Float) -> SVGAnimKeyVal {
        SVGAnimKeyVal(x, 0, 0, len: 1)
    }

    subscript(_ index: Int) -> Float {
        get {
            switch index {
            case 0: return v0
            case 1: return v1
            default: return v2
            }
        }
        set {
            switch index {
            case 0: v0 = newValue
            case 1: v1 = newValue
            default: v2 = newValue
            }
        }
    }
}

internal struct SVGAnimTrack: Equatable, Sendable {
    var target: UInt16
    var attr: SVGAnimAttrKind
    var begin: Float
    /// `nil` only for `<set>` with omitted or `"indefinite"` `dur` (one-shot switch at `begin`).
    var dur: Float?
    /// `nil` means `repeatCount="indefinite"` (only on `<animate>`/`<animateTransform>`).
    var repeatCount: Float?
    var freeze: Bool
    var additiveSum: Bool
    var isSet: Bool
    var calcMode: SVGAnimCalcMode
    var values: [SVGAnimKeyVal]
    /// Normalized `[0, 1]` keyTimes, always `values.count` entries when `values.count >= 2`.
    var keyTimes: [Float]
    /// Spline control points `(x1, y1, x2, y2)`, always `values.count - 1` entries when `.spline`.
    var keySplines: [SIMD4<Float>]
}

/// Inherited paint state carried on `<g>` scopes (and resolved onto shapes).
internal struct SVGAnimPaintProps: Equatable, Sendable {
    var fill: Bool?
    var stroke: Bool?
    var strokeWidth: Float?
    var fillRule: GAAARule?
    var cap: GLineCap?
    var join: GLineJoin?
    var miterLimit: Float?
    var fillOpacity: Float?
    var strokeOpacity: Float?

    static func fromAttrs(_ attrs: [(String, String)]) -> SVGAnimPaintProps {
        @inline(__always) func get(_ k: String) -> String? { SVGIconAnimParser.findAttr(attrs, k) }
        return SVGAnimPaintProps(
            fill: get("fill").map { SVGIconAnimParser.trimASCII($0) != "none" },
            stroke: get("stroke").map { SVGIconAnimParser.trimASCII($0) != "none" },
            strokeWidth: get("stroke-width").flatMap(SVGIconAnimParser.parseDim).map {
                min(SVGIconAnimLimits.maxStrokeWidth, max(0, $0))
            },
            fillRule: get("fill-rule").map {
                SVGIconAnimParser.trimASCII($0) == "evenodd" ? GAAARule.evenOdd : GAAARule.nonZero
            },
            cap: get("stroke-linecap").map { raw in
                switch SVGIconAnimParser.trimASCII(raw) {
                case "round": return GLineCap.round
                case "square": return GLineCap.square
                default: return GLineCap.butt
                }
            },
            join: get("stroke-linejoin").map { raw in
                switch SVGIconAnimParser.trimASCII(raw) {
                case "round": return GLineJoin.round
                case "bevel": return GLineJoin.bevel
                default: return GLineJoin.miter
                }
            },
            miterLimit: get("stroke-miterlimit").flatMap(SVGIconAnimParser.parseFinite).map {
                min(100.0, max(1.0, $0))
            },
            fillOpacity: get("fill-opacity").flatMap(SVGIconAnimParser.parseOpacityOpt),
            strokeOpacity: get("stroke-opacity").flatMap(SVGIconAnimParser.parseOpacityOpt)
        )
    }
}

internal enum SVGAnimBaseGeom: Equatable, Sendable {
    case circle(cx: Float, cy: Float, r: Float)
    case ellipse(cx: Float, cy: Float, rx: Float, ry: Float)
    case rect(x: Float, y: Float, w: Float, h: Float, rx: Float?, ry: Float?)
    case line(x1: Float, y1: Float, x2: Float, y2: Float)
    case path([GEl])
}

internal enum SVGAnimOp: Equatable, Sendable {
    case pushGroup(
        nodeId: UInt16,
        transform: GTransform,
        opacity: Float,
        displayNone: Bool,
        paint: SVGAnimPaintProps,
        hasOpacityAnim: Bool
    )
    case popGroup
    case drawShape(
        nodeId: UInt16,
        geom: SVGAnimBaseGeom,
        transform: GTransform,
        opacity: Float,
        displayNone: Bool,
        paint: SVGAnimPaintProps
    )
}

/// A compiled monochrome animated icon: flat op stream + validated SMIL tracks.
internal struct SVGCompiledAnim: Equatable, Sendable {
    var view: Float
    var ops: [SVGAnimOp]
    var tracks: [SVGAnimTrack]
    var nodeCount: Int
    /// True when at least one track repeats indefinitely (`repeatCount="indefinite"`).
    var hasIndefinite: Bool

    /// Total finite animation duration in seconds, or `nil` when any track repeats indefinitely.
    var finiteDuration: Double? {
        guard !hasIndefinite else { return nil }
        var maxEnd: Double = 0
        for tr in tracks {
            let begin = Double(tr.begin)
            let end: Double
            if tr.isSet {
                if let d = tr.dur {
                    end = begin + Double(d)
                } else {
                    end = max(0, begin)
                }
            } else {
                let dur = Double(tr.dur ?? 1.0)
                let rep = Double(tr.repeatCount ?? 1.0)
                end = begin + dur * rep
            }
            if end > maxEnd { maxEnd = end }
        }
        return max(0, maxEnd)
    }
}

/// Result of compiling an SVG icon body against the monochrome SMIL subset and hostile-input caps.
internal enum SVGAnimCompileOutcome: Equatable, Sendable {
    /// Valid monochrome animated SVG with at least one supported SMIL track.
    case animated(SVGCompiledAnim)
    /// Well-formed SVG within all caps, but with no supported SMIL tracks (safe to draw static).
    case staticOnly
    /// Exceeded a hostile-input cap or contained invalid XML/geometry/transforms (draw blank).
    case rejected
}

internal enum SVGIconAnimParser {
    /// Fast byte-level pre-check before touching the XML compiler.
    @inline(__always)
    static func mayBeAnimated(_ body: String) -> Bool {
        body.utf8.count <= SVGIconAnimLimits.maxSVGBytes
            && (body.contains("<animate") || body.contains("<set"))
    }

    /// Compiles `body` (for an icon with square `viewBox`) into a pre-parsed monochrome animation AST.
    static func compile(_ body: String, viewBox view: Float) -> SVGAnimCompileOutcome {
        compileInner(body, view: view) ?? .rejected
    }

    private struct StackEntry {
        var tag: String
        var nodeId: UInt16?
        var pushedGroup: Bool
        var skipSubtree: Bool
        var baseGeom: SVGAnimBaseGeom?
        var basePaint: SVGAnimPaintProps?
        var baseOpacity: Float
        var hasTransform: Bool
    }

    private static func compileInner(_ body: String, view: Float) -> SVGAnimCompileOutcome? {
        guard mayBeAnimated(body),
              view.isFinite,
              view >= SVGIconAnimLimits.minViewDim,
              view <= SVGIconAnimLimits.maxViewDim else {
            return nil
        }
        let bytes = Array(body.utf8)
        if bytes.contains(0) {
            return nil
        }

        var scanner = XMLScanner(bytes: bytes)
        var ops: [SVGAnimOp] = []
        var tracks: [SVGAnimTrack] = []
        var stack: [StackEntry] = []
        var elements = 0
        var shapes = 0
        var opacityLayers = 0
        var nextNodeId: UInt16 = 0

        while true {
            guard let step = scanner.nextToken() else {
                return nil
            }
            guard let tok = step else {
                break
            }
            switch tok {
            case .close(let name):
                guard let top = stack.popLast(), top.tag == name else {
                    return nil
                }
                if top.pushedGroup {
                    ops.append(.popGroup)
                }
            case .open(let tag, let attrs, let selfClosing):
                elements += 1
                if elements > SVGIconAnimLimits.maxElements {
                    return nil
                }
                if stack.count + (selfClosing ? 0 : 1) > SVGIconAnimLimits.maxDepth {
                    return nil
                }
                let inHidden = stack.last?.skipSubtree == true
                if inHidden || SVGIconAnimLimits.nonRenderingTags.contains(tag) {
                    if !selfClosing {
                        stack.append(StackEntry(
                            tag: tag,
                            nodeId: nil,
                            pushedGroup: false,
                            skipSubtree: true,
                            baseGeom: nil,
                            basePaint: nil,
                            baseOpacity: 1.0,
                            hasTransform: false
                        ))
                    }
                    continue
                }
                switch tag {
                case "g", "a", "svg":
                    let nodeId = nextNodeId
                    let (nextId, overflow) = nextNodeId.addingReportingOverflow(1)
                    if overflow { return nil }
                    nextNodeId = nextId
                    let opacity = findAttr(attrs, "opacity").flatMap(parseOpacityOpt) ?? 1.0
                    let displayNone = findAttr(attrs, "display").map { trimASCII($0) == "none" } ?? false
                    if opacity < 1.0 {
                        opacityLayers += 1
                        if opacityLayers > SVGIconAnimLimits.maxLayers {
                            return nil
                        }
                    }
                    let trAttr = findAttr(attrs, "transform")
                    let tr: GTransform
                    if let raw = trAttr {
                        guard let parsed = parseTransformBounded(raw) else { return nil }
                        tr = parsed
                    } else {
                        tr = .identity
                    }
                    let paint = SVGAnimPaintProps.fromAttrs(attrs)
                    if !selfClosing {
                        ops.append(.pushGroup(
                            nodeId: nodeId,
                            transform: tr,
                            opacity: opacity,
                            displayNone: displayNone,
                            paint: paint,
                            hasOpacityAnim: false
                        ))
                        stack.append(StackEntry(
                            tag: tag,
                            nodeId: nodeId,
                            pushedGroup: true,
                            skipSubtree: false,
                            baseGeom: nil,
                            basePaint: paint,
                            baseOpacity: opacity,
                            hasTransform: trAttr != nil
                        ))
                    }
                case "circle", "ellipse", "rect", "line", "path", "polyline", "polygon":
                    shapes += 1
                    if shapes > SVGIconAnimLimits.maxShapes {
                        return nil
                    }
                    guard let geom = parseGeom(tag: tag, attrs: attrs) else {
                        return nil
                    }
                    let nodeId = nextNodeId
                    let (nextId, overflow) = nextNodeId.addingReportingOverflow(1)
                    if overflow { return nil }
                    nextNodeId = nextId
                    let opacity = findAttr(attrs, "opacity").flatMap(parseOpacityOpt) ?? 1.0
                    let displayNone = findAttr(attrs, "display").map { trimASCII($0) == "none" } ?? false
                    let trAttr = findAttr(attrs, "transform")
                    let tr: GTransform
                    if let raw = trAttr {
                        guard let parsed = parseTransformBounded(raw) else { return nil }
                        tr = parsed
                    } else {
                        tr = .identity
                    }
                    let paint = SVGAnimPaintProps.fromAttrs(attrs)
                    ops.append(.drawShape(
                        nodeId: nodeId,
                        geom: geom,
                        transform: tr,
                        opacity: opacity,
                        displayNone: displayNone,
                        paint: paint
                    ))
                    if !selfClosing {
                        stack.append(StackEntry(
                            tag: tag,
                            nodeId: nodeId,
                            pushedGroup: false,
                            skipSubtree: false,
                            baseGeom: geom,
                            basePaint: paint,
                            baseOpacity: opacity,
                            hasTransform: trAttr != nil
                        ))
                    }
                case "animate", "animateTransform", "set":
                    if let parent = stack.last,
                       let target = parent.nodeId,
                       tracks.count < SVGIconAnimLimits.maxAnimations,
                       let track = parseTrack(tag: tag, attrs: attrs, target: target, stack: stack) {
                        if track.attr == .opacity && parent.pushedGroup {
                            // A group whose opacity is animated may drop below 1.0 at runtime:
                            // count it against MAX_LAYERS now and mark the PushGroup op.
                            if parent.baseOpacity >= 1.0 {
                                opacityLayers += 1
                                if opacityLayers > SVGIconAnimLimits.maxLayers {
                                    return nil
                                }
                            }
                            for idx in stride(from: ops.count - 1, through: 0, by: -1) {
                                if case .pushGroup(let opNodeId, let tr, let opOpacity, let disp, let paint, _) = ops[idx],
                                   opNodeId == target {
                                    ops[idx] = .pushGroup(
                                        nodeId: opNodeId,
                                        transform: tr,
                                        opacity: opOpacity,
                                        displayNone: disp,
                                        paint: paint,
                                        hasOpacityAnim: true
                                    )
                                    break
                                }
                            }
                        }
                        tracks.append(track)
                    }
                    if !selfClosing {
                        stack.append(StackEntry(
                            tag: tag,
                            nodeId: nil,
                            pushedGroup: false,
                            skipSubtree: true,
                            baseGeom: nil,
                            basePaint: nil,
                            baseOpacity: 1.0,
                            hasTransform: false
                        ))
                    }
                default:
                    if !selfClosing {
                        stack.append(StackEntry(
                            tag: tag,
                            nodeId: nil,
                            pushedGroup: false,
                            skipSubtree: true,
                            baseGeom: nil,
                            basePaint: nil,
                            baseOpacity: 1.0,
                            hasTransform: false
                        ))
                    }
                }
            }
        }

        if !stack.isEmpty {
            return nil
        }
        if tracks.isEmpty || shapes == 0 {
            return .staticOnly
        }
        let hasIndefinite = tracks.contains { !$0.isSet && $0.repeatCount == nil }
        return .animated(SVGCompiledAnim(
            view: view,
            ops: ops,
            tracks: tracks,
            nodeCount: Int(nextNodeId),
            hasIndefinite: hasIndefinite
        ))
    }

    private static func parseGeom(tag: String, attrs: [(String, String)]) -> SVGAnimBaseGeom? {
        @inline(__always) func coord(_ k: String) -> Float {
            let v = findAttr(attrs, k).flatMap(parseDim) ?? 0.0
            return min(SVGIconAnimLimits.maxCoord, max(-SVGIconAnimLimits.maxCoord, v))
        }
        @inline(__always) func nonneg(_ k: String) -> Float {
            let v = findAttr(attrs, k).flatMap(parseDim) ?? 0.0
            return min(SVGIconAnimLimits.maxCoord, max(0.0, v))
        }
        switch tag {
        case "circle":
            return .circle(cx: coord("cx"), cy: coord("cy"), r: nonneg("r"))
        case "ellipse":
            return .ellipse(cx: coord("cx"), cy: coord("cy"), rx: nonneg("rx"), ry: nonneg("ry"))
        case "rect":
            let rx = findAttr(attrs, "rx").flatMap(parseDim).map { min(SVGIconAnimLimits.maxCoord, max(0.0, $0)) }
            let ry = findAttr(attrs, "ry").flatMap(parseDim).map { min(SVGIconAnimLimits.maxCoord, max(0.0, $0)) }
            return .rect(x: coord("x"), y: coord("y"), w: nonneg("width"), h: nonneg("height"), rx: rx, ry: ry)
        case "line":
            return .line(x1: coord("x1"), y1: coord("y1"), x2: coord("x2"), y2: coord("y2"))
        case "path":
            guard let d = findAttr(attrs, "d") else { return nil }
            if d.utf8.count > SVGIconAnimLimits.maxPathBytes {
                return nil
            }
            var cmds = 0
            for b in d.utf8 {
                switch b {
                case UInt8(ascii: "M"), UInt8(ascii: "m"),
                     UInt8(ascii: "L"), UInt8(ascii: "l"),
                     UInt8(ascii: "H"), UInt8(ascii: "h"),
                     UInt8(ascii: "V"), UInt8(ascii: "v"),
                     UInt8(ascii: "C"), UInt8(ascii: "c"),
                     UInt8(ascii: "S"), UInt8(ascii: "s"),
                     UInt8(ascii: "Q"), UInt8(ascii: "q"),
                     UInt8(ascii: "T"), UInt8(ascii: "t"),
                     UInt8(ascii: "A"), UInt8(ascii: "a"),
                     UInt8(ascii: "Z"), UInt8(ascii: "z"):
                    cmds += 1
                    if cmds > SVGIconAnimLimits.maxPathCommands {
                        return nil
                    }
                default:
                    break
                }
            }
            let parsed = GSVGPathParser.parse(d)
            if parsed.count > SVGIconAnimLimits.maxPathCommands * 4 {
                return nil
            }
            @inline(__always) func ptOk(_ v: GPoint) -> Bool {
                v.x.isFinite && v.y.isFinite
                    && abs(v.x) <= SVGIconAnimLimits.maxCoord
                    && abs(v.y) <= SVGIconAnimLimits.maxCoord
            }
            for el in parsed {
                let ok: Bool
                switch el {
                case .move(let a), .line(let a):
                    ok = ptOk(a)
                case .quad(let a, let b):
                    ok = ptOk(a) && ptOk(b)
                case .cubic(let a, let b, let c):
                    ok = ptOk(a) && ptOk(b) && ptOk(c)
                case .conic(let a, let b, let w):
                    ok = ptOk(a) && ptOk(b) && w.isFinite && w > 0.0 && w <= 1024.0
                case .close:
                    ok = true
                }
                if !ok {
                    return nil
                }
            }
            return .path(parsed)
        case "polyline", "polygon":
            guard let raw = findAttr(attrs, "points") else { return nil }
            if raw.utf8.count > SVGIconAnimLimits.maxPathBytes {
                return nil
            }
            guard let nums = parseBoundedNumbers(raw, maxCount: SVGIconAnimLimits.maxPointsNumbers) else {
                return nil
            }
            if nums.count < 4 {
                return nil
            }
            let pairCount = nums.count / 2
            var els: [GEl] = []
            els.reserveCapacity(pairCount + 1)
            for i in 0..<pairCount {
                let x = min(SVGIconAnimLimits.maxCoord, max(-SVGIconAnimLimits.maxCoord, nums[i * 2]))
                let y = min(SVGIconAnimLimits.maxCoord, max(-SVGIconAnimLimits.maxCoord, nums[i * 2 + 1]))
                let v = GPoint(x: x, y: y)
                els.append(i == 0 ? .move(v) : .line(v))
            }
            if tag == "polygon" {
                els.append(.close)
            }
            return .path(els)
        default:
            return nil
        }
    }

    private static func baseAttrValue(stack: [StackEntry], attr: SVGAnimAttrKind) -> Float? {
        guard let parent = stack.last else { return nil }
        func inherited(_ get: (SVGAnimPaintProps) -> Float?, default defaultVal: Float) -> Float {
            for e in stack.reversed() {
                if let p = e.basePaint, let v = get(p) {
                    return v
                }
            }
            return defaultVal
        }
        switch attr {
        case .opacity: return parent.baseOpacity
        case .fillOpacity: return inherited({ $0.fillOpacity }, default: 1.0)
        case .strokeOpacity: return inherited({ $0.strokeOpacity }, default: 1.0)
        case .strokeWidth: return inherited({ $0.strokeWidth }, default: 1.0)
        case .r:
            if case .circle(_, _, let r) = parent.baseGeom { return r }
            return nil
        case .cx:
            switch parent.baseGeom {
            case .circle(let cx, _, _), .ellipse(let cx, _, _, _): return cx
            default: return nil
            }
        case .cy:
            switch parent.baseGeom {
            case .circle(_, let cy, _), .ellipse(_, let cy, _, _): return cy
            default: return nil
            }
        case .rx:
            switch parent.baseGeom {
            case .ellipse(_, _, let rx, _): return rx
            case .rect(_, _, _, _, let rx, _): return rx ?? 0.0
            default: return nil
            }
        case .ry:
            switch parent.baseGeom {
            case .ellipse(_, _, _, let ry): return ry
            case .rect(_, _, _, _, let rx, let ry): return (ry ?? rx) ?? 0.0
            default: return nil
            }
        case .x:
            if case .rect(let x, _, _, _, _, _) = parent.baseGeom { return x }
            return nil
        case .y:
            if case .rect(_, let y, _, _, _, _) = parent.baseGeom { return y }
            return nil
        case .width:
            if case .rect(_, _, let w, _, _, _) = parent.baseGeom { return w }
            return nil
        case .height:
            if case .rect(_, _, _, let h, _, _) = parent.baseGeom { return h }
            return nil
        case .x1:
            if case .line(let x1, _, _, _) = parent.baseGeom { return x1 }
            return nil
        case .y1:
            if case .line(_, let y1, _, _) = parent.baseGeom { return y1 }
            return nil
        case .x2:
            if case .line(_, _, let x2, _) = parent.baseGeom { return x2 }
            return nil
        case .y2:
            if case .line(_, _, _, let y2) = parent.baseGeom { return y2 }
            return nil
        case .transform:
            return nil
        }
    }

    private static func parseTrack(
        tag: String,
        attrs: [(String, String)],
        target: UInt16,
        stack: [StackEntry]
    ) -> SVGAnimTrack? {
        guard let parent = stack.last,
              let rawAttrName = findAttr(attrs, "attributeName") else {
            return nil
        }
        let attrName = trimASCII(rawAttrName)
        let isSet = tag == "set"
        let attr: SVGAnimAttrKind
        if tag == "animateTransform" {
            guard attrName == "transform" else { return nil }
            let rawType = findAttr(attrs, "type").map(trimASCII) ?? "translate"
            let kind: SVGAnimTransformKind
            switch rawType {
            case "translate": kind = .translate
            case "scale": kind = .scale
            case "rotate": kind = .rotate
            case "skewX": kind = .skewX
            case "skewY": kind = .skewY
            default: return nil
            }
            attr = .transform(kind)
        } else {
            switch attrName {
            case "r": attr = .r
            case "cx": attr = .cx
            case "cy": attr = .cy
            case "rx": attr = .rx
            case "ry": attr = .ry
            case "x": attr = .x
            case "y": attr = .y
            case "width": attr = .width
            case "height": attr = .height
            case "x1": attr = .x1
            case "y1": attr = .y1
            case "x2": attr = .x2
            case "y2": attr = .y2
            case "opacity": attr = .opacity
            case "fill-opacity": attr = .fillOpacity
            case "stroke-opacity": attr = .strokeOpacity
            case "stroke-width": attr = .strokeWidth
            default: return nil
            }
        }

        // `begin`: absent defaults to 0.0; if present, MUST parse as a finite clock value (rejects
        // event-bases like "click" or "indefinite" rather than silently auto-playing at 0).
        let begin: Float
        if let rawBegin = findAttr(attrs, "begin") {
            guard let b = parseClock(rawBegin),
                  b >= -SVGIconAnimLimits.maxClockSecs,
                  b <= SVGIconAnimLimits.maxClockSecs else {
                return nil
            }
            begin = b
        } else {
            begin = 0.0
        }

        // `dur`: required finite `[MIN_DUR_SECS, MAX_CLOCK_SECS]` for `<animate>`/`<animateTransform>`.
        // For `<set>`, omitted or `"indefinite"` means a single step at `begin` (`dur = nil`, never
        // spinning); a specified finite `dur` must also lie in `[MIN_DUR_SECS, MAX_CLOCK_SECS]`.
        let dur: Float?
        if isSet {
            switch findAttr(attrs, "dur").map(trimASCII) {
            case nil, "indefinite":
                dur = nil
            case let raw?:
                guard let d = parseClock(raw),
                      d >= SVGIconAnimLimits.minDurSecs,
                      d <= SVGIconAnimLimits.maxClockSecs else {
                    return nil
                }
                dur = d
            }
        } else {
            guard let rawDur = findAttr(attrs, "dur"),
                  let d = parseClock(rawDur),
                  d >= SVGIconAnimLimits.minDurSecs,
                  d <= SVGIconAnimLimits.maxClockSecs else {
                return nil
            }
            dur = d
        }

        let repeatCount: Float?
        if isSet {
            repeatCount = 1.0
        } else {
            switch findAttr(attrs, "repeatCount").map(trimASCII) {
            case nil:
                repeatCount = 1.0
            case "indefinite":
                repeatCount = nil
            case let raw?:
                guard let n = parseFinite(raw),
                      n > 0.0,
                      n <= SVGIconAnimLimits.maxRepeatCount else {
                    return nil
                }
                repeatCount = n
            }
        }

        let freeze = findAttr(attrs, "fill").map(trimASCII) == "freeze"
        let additiveSum = !isSet && findAttr(attrs, "additive").map(trimASCII) == "sum"

        var values: [SVGAnimKeyVal] = []
        var extraAdditive = false
        if isSet {
            guard let rawTo = findAttr(attrs, "to"),
                  let v = parseKeyVal(rawTo, attr: attr, isDelta: false) else {
                return nil
            }
            values.append(v)
        } else if let rawVals = findAttr(attrs, "values") {
            var rawParts = 0
            for part in rawVals.split(separator: ";", omittingEmptySubsequences: false) {
                rawParts += 1
                if rawParts > SVGIconAnimLimits.maxKeyframes + 1 {
                    return nil
                }
                let t = trimASCII(String(part))
                if t.isEmpty { continue }
                if values.count >= SVGIconAnimLimits.maxKeyframes {
                    return nil
                }
                guard let kv = parseKeyVal(t, attr: attr, isDelta: additiveSum) else {
                    return nil
                }
                values.append(kv)
            }
        } else {
            let fromRaw = findAttr(attrs, "from")
            let toRaw = findAttr(attrs, "to")
            let byRaw = findAttr(attrs, "by")
            switch (fromRaw, toRaw, byRaw) {
            case (let f?, let t?, _):
                guard let fv = parseKeyVal(f, attr: attr, isDelta: additiveSum),
                      let tv = parseKeyVal(t, attr: attr, isDelta: additiveSum) else {
                    return nil
                }
                values.append(fv)
                values.append(tv)
            case (let f?, nil, let b?):
                guard let fv = parseKeyVal(f, attr: attr, isDelta: additiveSum),
                      let bv = parseKeyVal(b, attr: attr, isDelta: true) else {
                    return nil
                }
                let len = max(fv.len, bv.len)
                let tv = SVGAnimKeyVal(fv.v0 + bv.v0, fv.v1 + bv.v1, fv.v2 + bv.v2, len: len)
                values.append(fv)
                values.append(clampKeyVal(tv, attr: attr, isDelta: additiveSum))
            case (nil, let t?, _):
                guard let base = defaultBaseKeyVal(stack: stack, attr: attr),
                      let tv = parseKeyVal(t, attr: attr, isDelta: false) else {
                    return nil
                }
                values.append(base)
                values.append(tv)
                // On a transform with an existing static base transform, `to`-only interpolates
                // relative to the underlying transform rather than discarding it.
                if case .transform = attr, parent.hasTransform {
                    extraAdditive = true
                }
            case (nil, nil, let b?):
                // SMIL `by`-only animation is implicitly additive (`additive="sum"`):
                // for `scale`, identity is `(1, 1)` so `by` interpolates `(1, 1) -> (1 + bx, 1 + by)`;
                // for all other attributes, identity is `0` so `by` interpolates `0 -> by` (signed!).
                guard let bv = parseKeyVal(b, attr: attr, isDelta: true) else {
                    return nil
                }
                if attr == .transform(.scale) {
                    values.append(SVGAnimKeyVal(1.0, 1.0, 0.0, len: 2))
                    values.append(clampKeyVal(SVGAnimKeyVal(1.0 + bv.v0, 1.0 + bv.v1, 0.0, len: 2), attr: attr, isDelta: false))
                } else {
                    values.append(SVGAnimKeyVal(0.0, 0.0, 0.0, len: bv.len))
                    values.append(bv)
                }
                extraAdditive = true
            default:
                return nil
            }
        }

        if values.isEmpty || (!isSet && values.count < 2) {
            return nil
        }

        let calcMode: SVGAnimCalcMode
        if isSet {
            calcMode = .discrete
        } else {
            switch findAttr(attrs, "calcMode").map(trimASCII) {
            case nil, "linear": calcMode = .linear
            case "discrete": calcMode = .discrete
            case "spline": calcMode = .spline
            case "paced": calcMode = .paced
            default: return nil
            }
        }

        let keyTimes: [Float]
        let keySplines: [SIMD4<Float>]
        if isSet || values.count < 2 {
            keyTimes = []
            keySplines = []
        } else if calcMode == .paced {
            // SMIL 3.0: `calcMode="paced"` ignores `keyTimes`/`keySplines` and paces at constant
            // velocity by cumulative Euclidean distance between keyframes.
            keyTimes = pacedKeyTimes(values)
            keySplines = []
        } else {
            if let rawKT = findAttr(attrs, "keyTimes") {
                guard let parsedKT = parseKeyTimes(rawKT, count: values.count, mode: calcMode) else {
                    return nil
                }
                keyTimes = parsedKT
            } else {
                keyTimes = uniformKeyTimes(count: values.count, mode: calcMode)
            }
            if calcMode == .spline {
                if let rawKS = findAttr(attrs, "keySplines") {
                    guard let parsedKS = parseKeySplines(rawKS, segments: values.count - 1) else {
                        return nil
                    }
                    keySplines = parsedKS
                } else {
                    keySplines = Array(repeating: SIMD4<Float>(0, 0, 1, 1), count: values.count - 1)
                }
            } else {
                keySplines = []
            }
        }

        return SVGAnimTrack(
            target: target,
            attr: attr,
            begin: begin,
            dur: dur,
            repeatCount: repeatCount,
            freeze: freeze,
            additiveSum: additiveSum || extraAdditive,
            isSet: isSet,
            calcMode: calcMode,
            values: values,
            keyTimes: keyTimes,
            keySplines: keySplines
        )
    }

    private static func defaultBaseKeyVal(stack: [StackEntry], attr: SVGAnimAttrKind) -> SVGAnimKeyVal? {
        switch attr {
        case .transform(.scale): return SVGAnimKeyVal(1.0, 1.0, 0.0, len: 2)
        case .transform(.translate): return SVGAnimKeyVal(0.0, 0.0, 0.0, len: 2)
        case .transform(.rotate): return SVGAnimKeyVal(0.0, 0.0, 0.0, len: 3)
        case .transform(.skewX), .transform(.skewY): return SVGAnimKeyVal.scalar(0.0)
        default:
            guard let v = baseAttrValue(stack: stack, attr: attr) else { return nil }
            return SVGAnimKeyVal.scalar(v)
        }
    }

    private static func uniformKeyTimes(count: Int, mode: SVGAnimCalcMode) -> [Float] {
        if mode == .discrete {
            return (0..<count).map { Float($0) / Float(count) }
        } else {
            let denom = Float(max(1, count - 1))
            return (0..<count).map { Float($0) / denom }
        }
    }

    private static func pacedKeyTimes(_ values: [SVGAnimKeyVal]) -> [Float] {
        var dists: [Float] = []
        dists.reserveCapacity(values.count)
        dists.append(0.0)
        var total: Float = 0.0
        for i in 0..<(values.count - 1) {
            let a = values[i]
            let b = values[i + 1]
            let len = Int(max(a.len, b.len))
            var sq: Float = 0.0
            for j in 0..<len {
                let d = b[j] - a[j]
                sq += d * d
            }
            total += sq.squareRoot()
            dists.append(total)
        }
        if total <= 1e-6 || !total.isFinite {
            return uniformKeyTimes(count: values.count, mode: .linear)
        }
        return dists.map { min(1.0, max(0.0, $0 / total)) }
    }

    private static func parseKeyVal(_ raw: String, attr: SVGAnimAttrKind, isDelta: Bool) -> SVGAnimKeyVal? {
        guard let nums = parseSmallNumbers(raw, maxCount: 3), !nums.isEmpty else {
            return nil
        }
        let v0: Float = nums[0]
        var v1: Float = nums.count > 1 ? nums[1] : 0.0
        let v2: Float = nums.count > 2 ? nums[2] : 0.0
        var len = UInt8(nums.count)
        // Normalize 1-arg `scale(s)` to `scale(s, s)` at compile time so mixed 1-arg / 2-arg scale
        // animations interpolate `sy` smoothly instead of interpolating from 0.
        if attr == .transform(.scale) && len == 1 {
            v1 = v0
            len = 2
        }
        return clampKeyVal(SVGAnimKeyVal(v0, v1, v2, len: len), attr: attr, isDelta: isDelta)
    }

    private static func clampKeyVal(_ inKV: SVGAnimKeyVal, attr: SVGAnimAttrKind, isDelta: Bool) -> SVGAnimKeyVal {
        var kv = inKV
        switch attr {
        case .opacity, .fillOpacity, .strokeOpacity:
            kv.v0 = isDelta ? min(1.0, max(-1.0, kv.v0)) : min(1.0, max(0.0, kv.v0))
        case .strokeWidth:
            let lim = SVGIconAnimLimits.maxStrokeWidth
            kv.v0 = isDelta ? min(lim, max(-lim, kv.v0)) : min(lim, max(0.0, kv.v0))
        case .r, .rx, .ry, .width, .height:
            let lim = SVGIconAnimLimits.maxCoord
            kv.v0 = isDelta ? min(lim, max(-lim, kv.v0)) : min(lim, max(0.0, kv.v0))
        case .cx, .cy, .x, .y, .x1, .y1, .x2, .y2:
            let lim = SVGIconAnimLimits.maxCoord
            kv.v0 = min(lim, max(-lim, kv.v0))
        case .transform(.scale):
            let lim = SVGIconAnimLimits.maxScale
            kv.v0 = min(lim, max(-lim, kv.v0))
            kv.v1 = min(lim, max(-lim, kv.v1))
        case .transform(.translate):
            let lim = SVGIconAnimLimits.maxCoord
            kv.v0 = min(lim, max(-lim, kv.v0))
            kv.v1 = min(lim, max(-lim, kv.v1))
        case .transform(.rotate):
            let lim = SVGIconAnimLimits.maxCoord
            kv.v0 = min(36_000.0, max(-36_000.0, kv.v0))
            kv.v1 = min(lim, max(-lim, kv.v1))
            kv.v2 = min(lim, max(-lim, kv.v2))
        case .transform(.skewX), .transform(.skewY):
            let lim = SVGIconAnimLimits.maxSkewDeg
            kv.v0 = min(lim, max(-lim, kv.v0))
        }
        return kv
    }

    private static func parseKeyTimes(_ raw: String, count: Int, mode: SVGAnimCalcMode) -> [Float]? {
        var parsed: [Float] = []
        parsed.reserveCapacity(count)
        var rawParts = 0
        for part in raw.split(separator: ";", omittingEmptySubsequences: false) {
            rawParts += 1
            if rawParts > count + 1 { return nil }
            let t = trimASCII(String(part))
            if t.isEmpty { continue }
            if parsed.count >= count { return nil }
            guard let v = parseFinite(t), v >= 0.0, v <= 1.0 else { return nil }
            if let prev = parsed.last, v < prev { return nil }
            parsed.append(v)
        }
        guard parsed.count == count, parsed[0] == 0.0 else { return nil }
        if mode != .discrete && abs(parsed[count - 1] - 1.0) > 1e-4 {
            return nil
        }
        return parsed
    }

    private static func parseKeySplines(_ raw: String, segments: Int) -> [SIMD4<Float>]? {
        var out: [SIMD4<Float>] = []
        out.reserveCapacity(segments)
        var rawParts = 0
        for part in raw.split(separator: ";", omittingEmptySubsequences: false) {
            rawParts += 1
            if rawParts > segments + 1 { return nil }
            let t = trimASCII(String(part))
            if t.isEmpty { continue }
            if out.count >= segments { return nil }
            guard let nums = parseSmallNumbers(t, maxCount: 4),
                  nums.count == 4,
                  nums[0] >= 0.0 && nums[0] <= 1.0,
                  nums[2] >= 0.0 && nums[2] <= 1.0 else {
                return nil
            }
            out.append(SIMD4<Float>(
                nums[0],
                min(SVGIconAnimLimits.maxSplineY, max(SVGIconAnimLimits.minSplineY, nums[1])),
                nums[2],
                min(SVGIconAnimLimits.maxSplineY, max(SVGIconAnimLimits.minSplineY, nums[3]))
            ))
        }
        guard out.count == segments else { return nil }
        return out
    }

    /// Parses SMIL clock values: `hh:mm:ss(.fff)`, `mm:ss(.fff)`, `h`, `min`, `s`, `ms`, or bare
    /// seconds, with optional leading `+` or `-`.
    static func parseClock(_ raw: String) -> Float? {
        let t = trimASCII(raw)
        guard !t.isEmpty else { return nil }
        let sign: Float
        let body: String
        if t.hasPrefix("-") {
            sign = -1.0
            body = trimASCII(String(t.dropFirst()))
        } else if t.hasPrefix("+") {
            sign = 1.0
            body = trimASCII(String(t.dropFirst()))
        } else {
            sign = 1.0
            body = t
        }
        if body.isEmpty || body.hasPrefix("+") || body.hasPrefix("-") {
            return nil
        }
        let mag: Float
        if body.contains(":") {
            let parts = body.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 3 {
                guard let h = parseFinite(String(parts[0])),
                      let m = parseFinite(String(parts[1])),
                      let s = parseFinite(String(parts[2])),
                      h >= 0.0,
                      m >= 0.0 && m < 60.0,
                      s >= 0.0 && s < 60.0 else {
                    return nil
                }
                mag = h * 3600.0 + m * 60.0 + s
            } else if parts.count == 2 {
                guard let m = parseFinite(String(parts[0])),
                      let s = parseFinite(String(parts[1])),
                      m >= 0.0,
                      s >= 0.0 && s < 60.0 else {
                    return nil
                }
                mag = m * 60.0 + s
            } else {
                return nil
            }
        } else if body.hasSuffix("ms") {
            guard let v = parseFinite(String(body.dropLast(2))) else { return nil }
            mag = v / 1000.0
        } else if body.hasSuffix("min") {
            guard let v = parseFinite(String(body.dropLast(3))) else { return nil }
            mag = v * 60.0
        } else if body.hasSuffix("h") {
            guard let v = parseFinite(String(body.dropLast(1))) else { return nil }
            mag = v * 3600.0
        } else if body.hasSuffix("s") {
            guard let v = parseFinite(String(body.dropLast(1))) else { return nil }
            mag = v
        } else {
            guard let v = parseFinite(body) else { return nil }
            mag = v
        }
        let val = sign * mag
        return val.isFinite ? val : nil
    }

    static func parseTransformBounded(_ raw: String) -> GTransform? {
        var m = GTransform.identity
        var ops = 0
        var rest = trimASCII(raw)
        while !rest.isEmpty {
            ops += 1
            if ops > SVGIconAnimLimits.maxTransformOps {
                return nil
            }
            guard let openParen = rest.firstIndex(of: "(") else { return nil }
            let afterOpen = rest[rest.index(after: openParen)...]
            guard let closeParen = afterOpen.firstIndex(of: ")") else { return nil }
            var op = trimASCII(String(rest[..<openParen]))
            while op.hasPrefix(",") {
                op = trimASCII(String(op.dropFirst()))
            }
            let args = String(afterOpen[..<closeParen])
            let tail = String(afterOpen[afterOpen.index(after: closeParen)...])
            guard let nums = parseSmallNumbers(args, maxCount: 6) else { return nil }
            let t: GTransform
            switch op {
            case "matrix" where nums.count == 6:
                let sc = SVGIconAnimLimits.maxScale
                let co = SVGIconAnimLimits.maxCoord
                t = GTransform(
                    xx: min(sc, max(-sc, nums[0])),
                    xy: min(sc, max(-sc, nums[1])),
                    yx: min(sc, max(-sc, nums[2])),
                    yy: min(sc, max(-sc, nums[3])),
                    tx: min(co, max(-co, nums[4])),
                    ty: min(co, max(-co, nums[5]))
                )
            case "translate" where nums.count == 1 || nums.count == 2:
                let co = SVGIconAnimLimits.maxCoord
                let tx = min(co, max(-co, nums[0]))
                let ty = min(co, max(-co, nums.count > 1 ? nums[1] : 0.0))
                t = .translation(tx, ty)
            case "scale" where nums.count == 1 || nums.count == 2:
                let sc = SVGIconAnimLimits.maxScale
                let sx = min(sc, max(-sc, nums[0]))
                let sy = min(sc, max(-sc, nums.count > 1 ? nums[1] : sx))
                t = .scale(sx, sy)
            case "rotate" where nums.count == 1 || nums.count == 3:
                let co = SVGIconAnimLimits.maxCoord
                let deg = min(36_000.0, max(-36_000.0, nums[0]))
                let cx = min(co, max(-co, nums.count > 1 ? nums[1] : 0.0))
                let cy = min(co, max(-co, nums.count > 2 ? nums[2] : 0.0))
                t = rotateTransform(deg: deg, cx: cx, cy: cy)
            case "skewX" where nums.count == 1:
                let deg = min(SVGIconAnimLimits.maxSkewDeg, max(-SVGIconAnimLimits.maxSkewDeg, nums[0]))
                t = GTransform(xx: 1, xy: 0, yx: Float(tan(Double(deg) * Double.pi / 180.0)), yy: 1, tx: 0, ty: 0)
            case "skewY" where nums.count == 1:
                let deg = min(SVGIconAnimLimits.maxSkewDeg, max(-SVGIconAnimLimits.maxSkewDeg, nums[0]))
                t = GTransform(xx: 1, xy: Float(tan(Double(deg) * Double.pi / 180.0)), yx: 0, yy: 1, tx: 0, ty: 0)
            default:
                return nil
            }
            m = GTransform.then(t, m)
            if !SVGAnimatedIcons.localCTMIsSafe(m) {
                return nil
            }
            rest = trimASCII(tail)
            while rest.hasPrefix(",") {
                rest = trimASCII(String(rest.dropFirst()))
            }
        }
        return m
    }

    static func rotateTransform(deg: Float, cx: Float, cy: Float) -> GTransform {
        let rad = Double(deg) * Double.pi / 180.0
        let s = sin(rad)
        let c = cos(rad)
        let dcx = Double(cx)
        let dcy = Double(cy)
        let tx = dcx - c * dcx + s * dcy
        let ty = dcy - s * dcx - c * dcy
        return GTransform(xx: Float(c), xy: Float(s), yx: Float(-s), yy: Float(c), tx: Float(tx), ty: Float(ty))
    }

    private static func parseSmallNumbers(_ s: String, maxCount: Int) -> [Float]? {
        parseBoundedNumbers(s, maxCount: maxCount)
    }

    private static func parseBoundedNumbers(_ s: String, maxCount: Int) -> [Float]? {
        var out: [Float] = []
        var start: Int? = nil
        let bytes = Array(s.utf8)
        var prev: UInt8 = UInt8(ascii: " ")
        for i in 0..<bytes.count {
            let b = bytes[i]
            let signSplit = (b == UInt8(ascii: "-") || b == UInt8(ascii: "+"))
                && prev != UInt8(ascii: "e") && prev != UInt8(ascii: "E")
            let sep = b == UInt8(ascii: ",") || isASCIIWhitespace(b)
            if sep || (signSplit && start != nil) {
                if let st = start {
                    start = nil
                    if out.count >= maxCount { return nil }
                    guard let val = parseFiniteBytes(bytes[st..<i]) else { return nil }
                    out.append(val)
                }
            }
            if !sep && start == nil {
                start = i
            }
            prev = b
        }
        if let st = start {
            if out.count >= maxCount { return nil }
            guard let val = parseFiniteBytes(bytes[st..<bytes.count]) else { return nil }
            out.append(val)
        }
        return out
    }

    private static func parseFiniteBytes(_ slice: ArraySlice<UInt8>) -> Float? {
        parseFinite(String(decoding: slice, as: UTF8.self))
    }

    static func parseFinite(_ s: String) -> Float? {
        let trimmed = trimASCII(s)
        guard !trimmed.isEmpty else { return nil }
        // Reject Swift-specific hex floats (`0x1p2`) and non-decimal syntax for strict SVG parity.
        for b in trimmed.utf8 {
            if b == UInt8(ascii: "x") || b == UInt8(ascii: "X") || b == UInt8(ascii: "_") {
                return nil
            }
        }
        guard let v = Float(trimmed), v.isFinite else { return nil }
        return v
    }

    static func parseDim(_ s: String) -> Float? {
        let trimmed = trimASCII(s)
        if trimmed.hasSuffix("px") {
            return parseFinite(String(trimmed.dropLast(2)))
        }
        return parseFinite(trimmed)
    }

    static func parseOpacityOpt(_ s: String) -> Float? {
        let t = trimASCII(s)
        let v: Float
        if t.hasSuffix("%") {
            guard let p = parseFinite(String(t.dropLast())) else { return nil }
            v = p / 100.0
        } else {
            guard let p = parseFinite(t) else { return nil }
            v = p
        }
        return min(1.0, max(0.0, v))
    }

    static func findAttr(_ attrs: [(String, String)], _ name: String) -> String? {
        for (k, v) in attrs where k == name {
            return v
        }
        return nil
    }

    @inline(__always)
    static func isASCIIWhitespace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C
    }

    static func trimASCII(_ s: String) -> String {
        let bytes = Array(s.utf8)
        var lo = 0
        var hi = bytes.count
        while lo < hi && isASCIIWhitespace(bytes[lo]) { lo += 1 }
        while hi > lo && isASCIIWhitespace(bytes[hi - 1]) { hi -= 1 }
        if lo == 0 && hi == bytes.count { return s }
        return String(decoding: bytes[lo..<hi], as: UTF8.self)
    }

    private enum Token {
        case open(tag: String, attrs: [(String, String)], selfClosing: Bool)
        case close(String)
    }

    /// Iterative XML tag scanner supporting XML comments (including `>` inside comments), both single
    /// and double quoted attribute values (including `>` inside attributes), and rejecting DTD/CDATA.
    private struct XMLScanner {
        let bytes: [UInt8]
        var pos: Int = 0

        /// Returns `.some(.some(tok))` for a token, `.some(.none)` at clean EOF, and `.none` on malformed XML.
        mutating func nextToken() -> Token?? {
            let n = bytes.count
            while true {
                var lt = pos
                while lt < n && bytes[lt] != UInt8(ascii: "<") {
                    lt += 1
                }
                if lt >= n {
                    pos = n
                    return .some(nil)
                }
                pos = lt

                // Comment `<!-- ... -->`
                if pos + 3 < n
                    && bytes[pos + 1] == UInt8(ascii: "!")
                    && bytes[pos + 2] == UInt8(ascii: "-")
                    && bytes[pos + 3] == UInt8(ascii: "-") {
                    var j = pos + 4
                    var found = false
                    while j + 2 < n {
                        if bytes[j] == UInt8(ascii: "-")
                            && bytes[j + 1] == UInt8(ascii: "-")
                            && bytes[j + 2] == UInt8(ascii: ">") {
                            pos = j + 3
                            found = true
                            break
                        }
                        j += 1
                    }
                    if !found { return nil }
                    continue
                }

                // Reject DTD / CDATA / entity declarations (`<!...`).
                if pos + 1 < n && bytes[pos + 1] == UInt8(ascii: "!") {
                    return nil
                }

                // Processing instruction `<? ... ?>`
                if pos + 1 < n && bytes[pos + 1] == UInt8(ascii: "?") {
                    var j = pos + 2
                    var found = false
                    while j + 1 < n {
                        if bytes[j] == UInt8(ascii: "?") && bytes[j + 1] == UInt8(ascii: ">") {
                            pos = j + 2
                            found = true
                            break
                        }
                        j += 1
                    }
                    if !found { return nil }
                    continue
                }

                // Closing tag `</tag>`
                if pos + 1 < n && bytes[pos + 1] == UInt8(ascii: "/") {
                    var close = pos + 2
                    while close < n && bytes[close] != UInt8(ascii: ">") {
                        close += 1
                    }
                    if close >= n { return nil }
                    let tag = SVGIconAnimParser.trimASCII(String(decoding: bytes[(pos + 2)..<close], as: UTF8.self))
                    if tag.isEmpty { return nil }
                    pos = close + 1
                    return .some(.close(tag))
                }

                // Opening / self-closing tag
                var i = pos + 1
                let tagStart = i
                while i < n
                    && !SVGIconAnimParser.isASCIIWhitespace(bytes[i])
                    && bytes[i] != UInt8(ascii: ">")
                    && bytes[i] != UInt8(ascii: "/") {
                    i += 1
                }
                if i == tagStart { return nil }
                let tag = String(decoding: bytes[tagStart..<i], as: UTF8.self)
                var attrs: [(String, String)] = []

                while true {
                    while i < n && SVGIconAnimParser.isASCIIWhitespace(bytes[i]) {
                        i += 1
                    }
                    if i >= n { return nil }
                    if bytes[i] == UInt8(ascii: ">") {
                        pos = i + 1
                        return .some(.open(tag: tag, attrs: attrs, selfClosing: false))
                    }
                    if bytes[i] == UInt8(ascii: "/") {
                        guard i + 1 < n && bytes[i + 1] == UInt8(ascii: ">") else {
                            return nil
                        }
                        pos = i + 2
                        return .some(.open(tag: tag, attrs: attrs, selfClosing: true))
                    }
                    let attrStart = i
                    while i < n
                        && !SVGIconAnimParser.isASCIIWhitespace(bytes[i])
                        && bytes[i] != UInt8(ascii: "=")
                        && bytes[i] != UInt8(ascii: ">")
                        && bytes[i] != UInt8(ascii: "/") {
                        i += 1
                    }
                    if i == attrStart { return nil }
                    let attrName = String(decoding: bytes[attrStart..<i], as: UTF8.self)
                    while i < n && SVGIconAnimParser.isASCIIWhitespace(bytes[i]) {
                        i += 1
                    }
                    guard i < n && bytes[i] == UInt8(ascii: "=") else { return nil }
                    i += 1
                    while i < n && SVGIconAnimParser.isASCIIWhitespace(bytes[i]) {
                        i += 1
                    }
                    guard i < n && (bytes[i] == UInt8(ascii: "\"") || bytes[i] == UInt8(ascii: "'")) else {
                        return nil
                    }
                    let quote = bytes[i]
                    i += 1
                    let valStart = i
                    while i < n && bytes[i] != quote {
                        i += 1
                    }
                    if i >= n { return nil }
                    let attrVal = String(decoding: bytes[valStart..<i], as: UTF8.self)
                    i += 1
                    if attrs.count >= SVGIconAnimLimits.maxAttrsPerTag {
                        return nil
                    }
                    attrs.append((attrName, attrVal))
                }
            }
        }
    }
}
