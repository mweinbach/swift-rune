import Foundation
#if canImport(simd)
import simd
#endif

// MARK: - Rules, Recording, Snap, Track, Finding & Checkers (`motion_gate/check.rs` + submodules)

public struct MotionGateRule: Sendable, Equatable {
    public let kind: String
    public let threshold: Float
    public let means: String
}

public let MOTION_GATE_RULES: [MotionGateRule] = [
    MotionGateRule(kind: "pop-in", threshold: 0.5, means: "mounts at or above this opacity, at full size, with no fade, growth or scale (and no ancestor transitioning)"),
    MotionGateRule(kind: "pop-out", threshold: 0.5, means: "unmounts at or above this opacity: it vanished instead of leaving"),
    MotionGateRule(kind: "cut-exit", threshold: 0.05, means: "unmounts above this opacity, below pop-out's: a fade cut short"),
    MotionGateRule(kind: "jump", threshold: 2.0, means: "an edge moves at least this many pt in one frame between still frames, where it shows (its visible part, or what it holds that shows, moves with it, or it brings what it holds into view with no input)"),
    MotionGateRule(kind: "offset-jump", threshold: 2.0, means: "a jump of a scroll's content: every row in it moved by the same delta in one frame"),
    MotionGateRule(kind: "appear-then-jump", threshold: 2.0, means: "mounts, then moves at least this many pt on its next frame"),
    MotionGateRule(kind: "jerk", threshold: 10.0, means: "a moving edge's per-frame step changes by more than this many pt from one frame to the next"),
    MotionGateRule(kind: "stop-start", threshold: 3.0, means: "a travelling edge rests (under 0.5 s) and sets off again the same way this many times in 2 s, with no input but data arriving: it moves in kicks, not one glide"),
    MotionGateRule(kind: "reversal", threshold: 1.0, means: "a travelling edge heads this many pt the wrong way and turns back, with no input mid-flight (one monotonic path)"),
    MotionGateRule(kind: "overshoot", threshold: 1.0, means: "passes where it comes to rest by this many pt (bounce 0)"),
    MotionGateRule(kind: "jiggle", threshold: 1.0, means: "an edge reverses twice or more within one motion, over at least this many pt"),
    MotionGateRule(kind: "text-swap", threshold: 0.5, means: "a text element's words change in one frame at or above this opacity, with no roll or crossfade (streaming text excepted)"),
    MotionGateRule(kind: "fade-snap", threshold: 0.5, means: "a mounted element's opacity steps by at least this in one frame: it blinks on or off instead of fading"),
    MotionGateRule(kind: "flicker", threshold: 0.3, means: "opacity dips by at least this much and comes back within 0.3 s, or an element vanishes and comes back at its place"),
    MotionGateRule(kind: "faint", threshold: 0.25, means: "geometry checks skip frames fainter than this opacity: a row fading out can't be seen to lurch"),
    MotionGateRule(kind: "load-motion", threshold: 1.0, means: "a row that loaded with the view moves or fades by more than this after its first frame (no animation on load)"),
    MotionGateRule(kind: "never-settles", threshold: 0.05, means: "still changing by more than this in the last half second of the run, long after the last input (loops excepted)"),
    MotionGateRule(kind: "loop-jump", threshold: 0.03, means: "a loop's phase steps this many periods off its usual step in one frame: it restarted or skipped (a remount, or a new loop where one was running)"),
    MotionGateRule(kind: "wakes-after-end", threshold: 1.0, means: "still asking for frames this many seconds after the cell's motion ended (a run that finished)"),
    MotionGateRule(kind: "lands-unseen", threshold: 40.0, means: "travels at least this many pt in plain view, then its clip cuts it from view in one frame where it rests: it flew somewhere you can't see"),
    MotionGateRule(kind: "remount", threshold: 2.0, means: "words start leaving while the same words mount elsewhere within this many frames: one thing fades out at its old place as its copy fades in (its row lost its key)"),
    MotionGateRule(kind: "unpinned", threshold: 2.0, means: "a scroll pinned to its end has its content's bottom this many pt below the viewport with no input since: it stopped following"),
    MotionGateRule(kind: "scroll-commit", threshold: 0.25, means: "the app ran its view (its `poll`, a handler or a layout read) on 6 or more of a scroll's frames and at least this share of them: a scroll needs no commit, so each one is a frame's whole view rebuilt mid-gesture"),
    MotionGateRule(kind: "snap", threshold: 1.0, means: "a painted property steps by at least this in one frame between frames that hold still, with no input, `Tx::instant` commit or mark asking for it: a colour by OKLab ΔE 0.08 (weighted by the area that shows and its opacity), a corner by 3 pt, a blur by 2 pt, a border by 1 pt, a new image, or two surfaces trading places (z-order). `(pixels)`: a region of the composited window, where no element changed"),
    MotionGateRule(kind: "flash", threshold: 0.5, means: "a painted property (or a region of the window) steps out by at least this and comes at least halfway back within 0.4 s, or drifts out and snaps back: a surface that drops out for a frame, or blinks before what replaces it fades in"),
    MotionGateRule(kind: "changes-twice", threshold: 0.25, means: "a painted property (or region) changes, rests from 2 frames to this many seconds, then carries on the same way with no input between: one change landed as two"),
    MotionGateRule(kind: "twice", threshold: 0.0, means: "two siblings share one key (Rune's `#dup`), so one thing shows twice, as an optimistic copy beside the server's")
]

public func motionGateRule(_ kind: String) -> Float {
    MOTION_GATE_RULES.first(where: { $0.kind == kind })?.threshold ?? .infinity
}

public func motionGateShort(_ path: String) -> String {
    let segs = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    let keyed = segs.indices.filter {
        let seg = segs[$0]
        return !seg.hasPrefix("#") && !seg.allSatisfy(\.isNumber)
    }
    let from = max(0, keyed.count - 2)
    let start = from < keyed.count ? keyed[from] : 0
    return segs[start...].map { $0.hasPrefix("@") ? String($0.dropFirst()) : $0 }.joined(separator: "/")
}

public enum MotionGateSnapFlags {
    public static let exiting: UInt8 = 1
    public static let scrolling: UInt8 = 2
    public static let growing: UInt8 = 4
    public static let live: UInt8 = 8
    public static let virtual: UInt8 = 16
    public static let text: UInt8 = 32
    public static let ink: UInt8 = 128
}

/// Optional per-element motion telemetry paired by index with `[ElementInfo]`.
public struct ElementMotionMeta: Sendable, Equatable {
    public var scrolling: Bool
    public var inGrowingRow: Bool
    public var revealing: Bool
    public var liveIntent: UInt16
    public var virtualExtent: Bool
    public var loopPhase: Double?
    public var carriedScrolled: [Float]?

    public init(
        scrolling: Bool = false,
        inGrowingRow: Bool = false,
        revealing: Bool = false,
        liveIntent: UInt16 = 0,
        virtualExtent: Bool = false,
        loopPhase: Double? = nil,
        carriedScrolled: [Float]? = nil
    ) {
        self.scrolling = scrolling
        self.inGrowingRow = inGrowingRow
        self.revealing = revealing
        self.liveIntent = liveIntent
        self.virtualExtent = virtualExtent
        self.loopPhase = loopPhase
        self.carriedScrolled = carriedScrolled
    }
}

public struct MotionGateSnap: Sendable {
    public var rect: [Float] // [x, y, w, h]
    public var vis: [Float]  // [x, y, w, h]
    public var op: Float
    public var scale: Float
    public var flags: UInt8
    public var phase: Float
    public var scrolled: [Float] // [x, y]

    public init(
        rect: [Float],
        vis: [Float],
        op: Float,
        scale: Float,
        flags: UInt8,
        phase: Float = .nan,
        scrolled: [Float] = [0, 0]
    ) {
        self.rect = rect
        self.vis = vis
        self.op = op
        self.scale = scale
        self.flags = flags
        self.phase = phase
        self.scrolled = scrolled
    }
}

public final class MotionGateTrack: @unchecked Sendable {
    public var path: String
    public var parent: Int?
    public var frames: [(Int, MotionGateSnap)] = []
    public var text: String?
    public var words: [(Int, String)] = []
    public var edits: [(Int, String)] = []
    public var paint: [MotionGatePaint?] = []

    public init(path: String, parent: Int? = nil) {
        self.path = path
        self.parent = parent
    }

    private func frameIndex(at k: Int) -> Int? {
        var lo = 0
        var hi = frames.count
        while lo < hi {
            let mid = (lo + hi) / 2
            let fk = frames[mid].0
            if fk == k { return mid }
            if fk < k { lo = mid + 1 } else { hi = mid }
        }
        return nil
    }

    public func at(_ k: Int) -> MotionGateSnap? {
        guard let i = frameIndex(at: k) else { return nil }
        return frames[i].1
    }

    public func paintAt(_ k: Int) -> MotionGatePaint? {
        guard let i = frameIndex(at: k), i < paint.count else { return nil }
        return paint[i]
    }
}

public struct MotionGateFinding: Sendable, CustomStringConvertible {
    public var kind: String
    public var element: String
    public var frame: Int
    public var detail: String

    public init(kind: String, element: String, frame: Int, detail: String) {
        self.kind = kind
        self.element = element
        self.frame = frame
        self.detail = detail
    }

    public var description: String {
        let kPad = kind.padding(toLength: 16, withPad: " ", startingAt: 0)
        let ePad = element.padding(toLength: 44, withPad: " ", startingAt: 0)
        let fPad = "\(frame)".padding(toLength: 4, withPad: " ", startingAt: 0)
        return "\(kPad) \(ePad) @\(fPad) \(detail)"
    }
}

public final class MotionGateRecording: @unchecked Sendable {
    public var size: (Float, Float)
    public var hz: Double
    public var tracks: [MotionGateTrack] = []
    private var index: [String: Int] = [:]
    public var inputs: [(Int, String)] = []
    public var frames: Int = 0
    public var start: Int = 0
    public var loads: [Int] = []
    public var awake: [Bool] = []
    public var quietFrom: Int? = nil
    public var countsRoll: Bool = false
    internal var scrolled: [(Bool, UInt16)] = []
    public var instant: [Bool] = []
    public var grids: [MotionGateGrid?] = []
    public var tips: [[Float]?] = []

    public struct PaintKey: Hashable, Sendable {
        public let path: String
        public let exiting: Bool

        public init(path: String, exiting: Bool) {
            self.path = path
            self.exiting = exiting
        }
    }

    public init(size: (Float, Float) = (0, 0), hz: Double = 120.0) {
        self.size = size
        self.hz = hz
    }

    public func commits(scrolling: Bool, why: UInt16) {
        scrolled.append((scrolling, why & (CommitWhy.poll | CommitWhy.input | CommitWhy.layout | CommitWhy.read)))
        instant.append((why & CommitWhy.instant) != 0)
    }

    public func setGrid(_ grid: MotionGateGrid?) {
        while grids.count < max(0, frames - 1) {
            grids.append(nil)
        }
        grids.append(grid)
    }

    @discardableResult
    public func track(_ path: String, parent: Int? = nil) -> Int {
        if let existing = index[path] {
            return existing
        }
        let i = tracks.count
        tracks.append(MotionGateTrack(path: path, parent: parent))
        index[path] = i
        return i
    }

    public func input(_ what: String) {
        inputs.append((frames, what))
    }

    public func sample(_ els: [ElementInfo]) {
        sampleWith(els, meta: nil, paints: nil)
    }

    public func sampleWith(
        _ els: [ElementInfo],
        meta: [ElementMotionMeta]? = nil,
        paints: [PaintKey: MotionGatePaint]? = nil
    ) {
        let k = frames
        frames += 1

        let live = Set(els.filter { !$0.exiting }.map(\.path))
        var ids = Array(repeating: -1, count: els.count)
        var ink = Array(repeating: false, count: els.count)
        var parentOf = Array(repeating: false, count: els.count)
        for e in els {
            if let p = e.parentIndex, p >= 0 && p < els.count {
                parentOf[p] = true
            }
        }
        for i in stride(from: els.count - 1, through: 0, by: -1) {
            let e = els[i]
            let hasText = !(e.text?.isEmpty ?? true)
            let p = e.fill.a > 0.01 || hasText || !parentOf[i]
            ink[i] = ink[i] || (p && e.opacity > 0.02)
            if ink[i], let parent = e.parentIndex, parent >= 0 && parent < els.count {
                ink[parent] = true
            }
        }

        for (i, e) in els.enumerated() {
            let m = (meta != nil && i < meta!.count) ? meta![i] : ElementMotionMeta()
            let path = (e.exiting && live.contains(e.path)) ? "\(e.path) (leaving)" : e.path
            let parent: Int? = e.parentIndex.flatMap { p in (p >= 0 && p < ids.count && ids[p] >= 0) ? ids[p] : nil }
            let t = track(path, parent: parent)
            ids[i] = t

            var flags: UInt8 = 0
            if e.exiting { flags |= MotionGateSnapFlags.exiting }
            if m.scrolling { flags |= MotionGateSnapFlags.scrolling }
            if m.inGrowingRow || m.revealing { flags |= MotionGateSnapFlags.growing }
            if m.liveIntent != 0 { flags |= MotionGateSnapFlags.live }
            if m.virtualExtent { flags |= MotionGateSnapFlags.virtual }
            if e.role == .text { flags |= MotionGateSnapFlags.text }
            if ink[i] { flags |= MotionGateSnapFlags.ink }

            let tr = tracks[t]
            if tr.frames.last?.0 == k {
                continue
            }
            tr.parent = parent ?? tr.parent
            if tr.text == nil, let txt = e.text, !txt.isEmpty {
                tr.text = txt
            }
            if let words = e.text, !words.isEmpty, (!e.focusable || e.role.rawValue == "link"), tr.words.last?.1 != words {
                tr.words.append((k, words))
            }
            if e.focusable && e.role.rawValue != "link" {
                let words = e.text ?? ""
                if let last = tr.edits.last {
                    if last.1 != words { tr.edits.append((k, words)) }
                } else if !words.isEmpty {
                    tr.edits.append((k, words))
                }
            }
            tr.frames.append((
                k,
                MotionGateSnap(
                    rect: e.rect,
                    vis: e.visible,
                    op: e.opacity,
                    scale: e.scale,
                    flags: flags,
                    phase: m.loopPhase.map(Float.init) ?? .nan,
                    scrolled: m.carriedScrolled ?? e.scrolled
                )
            ))
            if let paints {
                while tr.paint.count < tr.frames.count - 1 {
                    tr.paint.append(nil)
                }
                tr.paint.append(paints[PaintKey(path: e.path, exiting: e.exiting)])
            }
        }
    }
}

// MARK: - Helpers & Checker Entry Point

private enum MotionGateCheckHelpers {
    static let axes = ["x", "y", "w", "h"]

    static func rectArea(_ r: [Float]) -> Float {
        max(0.0, r[2]) * max(0.0, r[3])
    }

    static func onWindow(_ r: [Float], _ size: (Float, Float)) -> [Float] {
        let x0 = max(0.0, r[0])
        let y0 = max(0.0, r[1])
        let x1 = min(size.0, r[0] + r[2])
        let y1 = min(size.1, r[1] + r[3])
        return [x0, y0, max(0.0, x1 - x0), max(0.0, y1 - y0)]
    }

    static func seen(_ s: MotionGateSnap, _ size: (Float, Float)) -> Bool {
        s.op > 0.02 && rectArea(onWindow(s.vis, size)) >= 1.0
    }

    static func edge(_ s: MotionGateSnap, _ axis: Int) -> Float {
        s.rect[axis]
    }

    static func shownEdge(_ s: MotionGateSnap, _ axis: Int, _ size: (Float, Float)) -> Float {
        let r = onWindow(s.vis, size)
        switch axis {
        case 0: return min(r[0], size.0)
        case 1: return min(r[1], size.1)
        case 2: return r[2]
        default: return r[3]
        }
    }

    static func ownEdge(_ s: MotionGateSnap, _ axis: Int) -> Float {
        s.rect[axis] + (axis < s.scrolled.count ? s.scrolled[axis] : 0.0)
    }

    static func meet(_ a: [Float], _ b: [Float]) -> [Float] {
        let x0 = max(a[0], b[0])
        let y0 = max(a[1], b[1])
        return [
            x0,
            y0,
            max(0.0, min(a[0] + a[2], b[0] + b[2]) - x0),
            max(0.0, min(a[1] + a[3], b[1] + b[3]) - y0)
        ]
    }

    static func startsWithWords(_ text: String, _ prefix: String) -> Bool {
        func isVisible(_ s: UnicodeScalar) -> Bool {
            s.value < 0x2066 || s.value > 0x2069
        }
        let tv = text.unicodeScalars.filter(isVisible)
        let pv = prefix.unicodeScalars.filter(isVisible)
        guard tv.count >= pv.count else { return false }
        return zip(tv, pv).allSatisfy { $0 == $1 }
    }

    static func ticks(_ old: String, _ new: String) -> Bool {
        func shape(_ t: String) -> String {
            var out = ""
            for ch in t {
                if !ch.isASCII || !ch.isNumber {
                    out.append(ch)
                } else if out.last != "#" {
                    out.append("#")
                }
            }
            return out
        }
        return shape(old) == shape(new)
    }

    static func inside(_ a: String, _ b: String) -> Bool {
        guard a.count > b.count, a.hasPrefix(b) else { return false }
        let idx = a.index(a.startIndex, offsetBy: b.count)
        return a[idx] == "/"
    }

    static func lastSeg(_ path: String) -> String {
        if let idx = path.lastIndex(of: "/") {
            return String(path[path.index(after: idx)...])
        }
        return path
    }
}

public func motionGateCheck(_ rec: MotionGateRecording) -> [MotionGateFinding] {
    let size = rec.size
    let n = rec.frames
    let tr = rec.tracks
    var out: [MotionGateFinding] = []
    let inputFrames = rec.inputs.map(\.0)

    func inputBetween(_ a: Int, _ b: Int) -> Bool {
        inputFrames.contains { $0 >= a && $0 <= b }
    }

    func born(_ t: MotionGateTrack) -> Int? { t.frames.first?.0 }
    func died(_ t: MotionGateTrack) -> Int? {
        guard let last = t.frames.last?.0, last + 1 < n else { return nil }
        return last + 1
    }
    func gaps(_ t: MotionGateTrack) -> [(Int, Int)] {
        guard t.frames.count >= 2 else { return [] }
        var res: [(Int, Int)] = []
        for idx in 1..<t.frames.count where t.frames[idx].0 != t.frames[idx - 1].0 + 1 {
            res.append((t.frames[idx - 1].0 + 1, t.frames[idx].0))
        }
        return res
    }

    let parents = Set(tr.compactMap(\.parent))

    func transitioning(_ tIdx: Int, _ a: Int, _ b: Int) -> Bool {
        var p = tr[tIdx].parent
        while let i = p {
            let s = (max(0, a - 1)...b).compactMap { tr[i].at($0) }
            for idx in 1..<s.count {
                if abs(s[idx - 1].op - s[idx].op) > 0.005 || abs(s[idx - 1].scale - s[idx].scale) > 0.001 {
                    return true
                }
            }
            if s.contains(where: { ($0.flags & (MotionGateSnapFlags.growing | MotionGateSnapFlags.exiting)) != 0 }) {
                return true
            }
            p = tr[i].parent
        }
        return false
    }

    // 1. Loops (`check/loops.rs`)
    let loops = MotionGateLoops.findLoops(rec)

    // 2. Pops / Flickers / Cut-exits
    var births: [Int: [Int]] = [:]
    var deaths: [Int: [Int]] = [:]
    for (i, t) in tr.enumerated() {
        var bks: [Int] = []
        if let b = born(t) { bks.append(b) }
        bks.append(contentsOf: gaps(t).map(\.1))
        for k in bks where k > rec.start {
            births[k, default: []].append(i)
        }

        var dks: [Int] = []
        if let d = died(t) { dks.append(d) }
        dks.append(contentsOf: gaps(t).map(\.0))
        for k in dks where k > rec.start {
            deaths[k, default: []].append(i)
        }
    }

    func outermost(_ ids: [Int]) -> [Int] {
        let set = Set(ids)
        return ids.filter { i in
            var p = tr[i].parent
            while let j = p {
                if set.contains(j) { return false }
                p = tr[j].parent
            }
            return true
        }
    }

    var left: [Int: [(Int, MotionGateSnap)]] = [:]
    for k in deaths.keys.sorted() {
        for i in outermost(deaths[k]!) {
            guard let last = tr[i].at(k - 1) else { continue }
            if !MotionGateCheckHelpers.seen(last, size) ||
                MotionGateCheckHelpers.rectArea(last.vis) < 16.0 ||
                loops.contains(i) ||
                (last.flags & MotionGateSnapFlags.virtual) != 0 {
                continue
            }
            if let back = tr[i].frames.first(where: { $0.0 > k && $0.0 <= k + 12 }),
               abs(back.1.rect[1] - last.rect[1]) < 4.0 && MotionGateCheckHelpers.seen(back.1, size) {
                let firstBackFrame = tr[i].frames.first(where: { $0.0 > k })?.0 ?? back.0
                out.append(MotionGateFinding(
                    kind: "flicker",
                    element: motionGateShort(tr[i].path),
                    frame: k,
                    detail: String(format: "vanished at opacity %.2f and came back %d frames later at the same place", last.op, firstBackFrame - k)
                ))
                continue
            }
            if last.op >= motionGateRule("pop-out") {
                left[k, default: []].append((i, last))
                let insideNote = transitioning(i, k - 1, k - 1) ? " inside a moving container" : ""
                out.append(MotionGateFinding(
                    kind: "pop-out",
                    element: motionGateShort(tr[i].path),
                    frame: k,
                    detail: String(format: "unmounted at opacity %.2f, %.0f×%.0f at (%.0f,%.0f)%@", last.op, last.rect[2], last.rect[3], last.rect[0], last.rect[1], insideNote)
                ))
            } else if last.op > motionGateRule("cut-exit") {
                out.append(MotionGateFinding(
                    kind: "cut-exit",
                    element: motionGateShort(tr[i].path),
                    frame: k,
                    detail: String(format: "unmounted at opacity %.2f before its fade reached 0", last.op)
                ))
            }
        }
    }

    for k in births.keys.sorted() {
        for i in outermost(births[k]!) {
            let t = tr[i]
            guard let first = t.at(k) else { continue }
            if first.op < motionGateRule("pop-in") ||
                !MotionGateCheckHelpers.seen(first, size) ||
                MotionGateCheckHelpers.rectArea(MotionGateCheckHelpers.onWindow(first.vis, size)) < 16.0 ||
                (first.flags & (MotionGateSnapFlags.growing | MotionGateSnapFlags.virtual)) != 0 ||
                loops.contains(i) {
                continue
            }
            let next = ((k + 1)...(k + 2)).compactMap { t.at($0) }
            let grows = next.contains { s in
                abs(s.op - first.op) > 0.01 ||
                abs(s.scale - first.scale) > 0.002 ||
                abs(s.rect[2] - first.rect[2]) > 0.5 ||
                abs(s.rect[3] - first.rect[3]) > 0.5 ||
                abs(s.vis[2] - first.vis[2]) > 0.5 ||
                abs(s.vis[3] - first.vis[3]) > 0.5
            } || (first.rect[3] < 1.0 && ((k + 1)...(k + Int(0.25 * rec.hz))).compactMap { t.at($0) }.contains { $0.rect[3] >= 1.0 })
            if grows || transitioning(i, k, k + 2) { continue }

            let moved = next.first.map { max(abs($0.rect[0] - first.rect[0]), abs($0.rect[1] - first.rect[1])) } ?? 0.0
            let handoff = left[k]?.first { (j, _) in
                (tr[j].text != nil && tr[j].text == t.text) ||
                MotionGateCheckHelpers.lastSeg(tr[j].path) == MotionGateCheckHelpers.lastSeg(t.path)
            }
            var detail = String(format: "mounted at opacity %.2f, %.0f×%.0f at (%.0f,%.0f) with no transition", first.op, first.rect[2], first.rect[3], first.rect[0], first.rect[1])
            if let (j, s) = handoff {
                detail += String(format: "; replaces %@ which vanished from (%.0f,%.0f) this frame (identity lost)", motionGateShort(tr[j].path), s.rect[0], s.rect[1])
            }
            if moved >= motionGateRule("appear-then-jump") {
                out.append(MotionGateFinding(
                    kind: "appear-then-jump",
                    element: motionGateShort(t.path),
                    frame: k,
                    detail: String(format: "%@, then moved %.0f pt", detail, moved)
                ))
            } else {
                out.append(MotionGateFinding(kind: "pop-in", element: motionGateShort(t.path), frame: k, detail: detail))
            }
        }
    }

    // 3. Painted properties + Geometry
    func riding(_ i: Int, _ k: Int, _ axis: Int, _ d: Float) -> Bool {
        if axis >= 2 { return false }
        guard let p = tr[i].parent,
              let a = tr[p].at(k),
              let b = tr[p].at(k - 1) else { return false }
        return abs(MotionGateCheckHelpers.edge(a, axis) - MotionGateCheckHelpers.edge(b, axis) - d) < 0.25
    }

    func pushed(_ i: Int, _ k: Int, _ axis: Int, _ d: Float) -> Bool {
        if axis != 1 || !inputBetween(k - 1, k) { return false }
        guard let a = tr[i].at(k - 1) else { return false }
        return tr.enumerated().contains { (j, o) in
            if j == i || MotionGateCheckHelpers.inside(tr[i].path, o.path) || MotionGateCheckHelpers.inside(o.path, tr[i].path) { return false }
            guard let oa = o.at(k - 1), let ob = o.at(k) else { return false }
            if abs(abs(ob.rect[3] - oa.rect[3]) - abs(d)) > 0.25 { return false }
            let top = ob.rect[1] - oa.rect[1]
            let bottom = ob.rect[1] + ob.rect[3] - oa.rect[1] - oa.rect[3]
            let above = oa.rect[1] + oa.rect[3] <= a.rect[1] + 0.5 && abs(bottom - d) < 0.25
            let below = oa.rect[1] >= a.rect[1] + a.rect[3] - 0.5 && abs(top - d) < 0.25
            return above || below
        }
    }

    func carried(_ i: Int, _ k: Int, _ axis: Int, _ d: Float, entering: Bool) -> Int {
        if axis >= 2 { return 0 }
        let ent = entering && !inputBetween(k - 1, k)
        return tr.filter { MotionGateCheckHelpers.inside($0.path, tr[i].path) }.filter { c in
            guard let a = c.at(k - 1), let b = c.at(k) else { return false }
            if !MotionGateCheckHelpers.seen(b, size) || abs(MotionGateCheckHelpers.edge(b, axis) - MotionGateCheckHelpers.edge(a, axis) - d) >= 0.25 {
                return false
            }
            if MotionGateCheckHelpers.seen(a, size) {
                return abs(MotionGateCheckHelpers.shownEdge(b, axis, size) - MotionGateCheckHelpers.shownEdge(a, axis, size) - d) < 0.25
            }
            return ent && b.op >= motionGateRule("faint") && (b.flags & MotionGateSnapFlags.ink) != 0 && (b.flags & (MotionGateSnapFlags.growing | MotionGateSnapFlags.exiting)) == 0
        }.count
    }

    var geo: [(Int, MotionGateFinding)] = MotionGatePainted.checkPainted(rec, loops: loops)

    for (i, t) in tr.enumerated() {
        if loops.contains(i) || t.frames.count < 3 { continue }
        let fs = t.frames

        for axis in 0..<4 {
            let d: [Float?] = (1..<fs.count).map { j in
                fs[j].0 == fs[j - 1].0 + 1 ? (MotionGateCheckHelpers.edge(fs[j].1, axis) - MotionGateCheckHelpers.edge(fs[j - 1].1, axis)) : nil
            }
            func vd(_ j: Int) -> Float {
                fs[j].0 == fs[j - 1].0 + 1 ? (MotionGateCheckHelpers.shownEdge(fs[j].1, axis, size) - MotionGateCheckHelpers.shownEdge(fs[j - 1].1, axis, size)) : 0.0
            }
            func clipped(_ j: Int) -> Bool {
                MotionGateCheckHelpers.rectArea(MotionGateCheckHelpers.onWindow(fs[j].1.vis, size)) + 1.0 < MotionGateCheckHelpers.rectArea(fs[j].1.rect)
            }
            func quiet(_ j: Int) -> Bool {
                (fs[j].1.flags & (MotionGateSnapFlags.live | MotionGateSnapFlags.virtual)) != 0 ||
                !MotionGateCheckHelpers.seen(fs[j].1, size) ||
                fs[j].1.op < motionGateRule("faint")
            }
            func grew(_ k: Int) -> Bool {
                guard let p = t.words.firstIndex(where: { $0.0 == k }), p > 0 else { return false }
                return MotionGateCheckHelpers.startsWithWords(t.words[p].1, t.words[p - 1].1)
            }

            for j in 1..<fs.count {
                guard let step = d[j - 1] else { continue }
                let k = fs[j].0
                if k <= rec.start || quiet(j) || quiet(j - 1) || ((fs[j].1.flags & MotionGateSnapFlags.growing) != 0 && axis == 3) {
                    continue
                }
                let scrolling = ((fs[j].1.flags | fs[j - 1].1.flags) & MotionGateSnapFlags.scrolling) != 0
                let before = j >= 2 ? (d[j - 2] ?? 0.0) : 0.0
                let after = j < d.count ? (d[j] ?? 0.0) : 0.0
                let name = motionGateShort(t.path)
                func riders(_ entering: Bool) -> Int {
                    (clipped(j) || clipped(j - 1)) ? carried(i, k, axis, step, entering: entering) : 0
                }

                if abs(step) >= motionGateRule("jump") && abs(before) < 0.5 && abs(after) < 0.5 {
                    let cut = axis < 2 && inputBetween(k - 1, k) && abs(MotionGateCheckHelpers.ownEdge(fs[j].1, axis) - MotionGateCheckHelpers.ownEdge(fs[j - 1].1, axis)) < 0.25
                    if (scrolling && inputBetween(k - 1, k)) || cut || riding(i, k, axis, step) || pushed(i, k, axis, step) || grew(k) {
                        continue
                    }
                    let rc = riders(true)
                    if abs(vd(j)) < motionGateRule("jump") && rc == 0 { continue }
                    let appeared = born(t) == fs[j - 1].0 && fs[j - 1].0 > rec.start
                    let scrollContent = axis == 1 && fs[j].1.rect[3] > fs[j].1.vis[3] + 1.0 && rc >= 3
                    let kind = appeared ? "appear-then-jump" : (scrollContent ? "offset-jump" : "jump")
                    let extra = scrollContent ? ", carrying \(rc) elements" : ""
                    geo.append((i, MotionGateFinding(
                        kind: kind,
                        element: name,
                        frame: k,
                        detail: String(format: "%@ %.1f → %.1f (%+.1f pt) in one frame%@", MotionGateCheckHelpers.axes[axis], MotionGateCheckHelpers.edge(fs[j - 1].1, axis), MotionGateCheckHelpers.edge(fs[j].1, axis), step, extra)
                    )))
                } else if !scrolling && abs(step - before) > motionGateRule("jerk") && abs(before) >= 0.5 && abs(step) >= 0.5 {
                    if riding(i, k, axis, step) { continue }
                    if j >= 2 && abs(vd(j) - vd(j - 1)) <= motionGateRule("jerk") && riders(false) == 0 { continue }
                    geo.append((i, MotionGateFinding(
                        kind: "jerk",
                        element: name,
                        frame: k,
                        detail: String(format: "%@ step %+.1f → %+.1f pt/frame (%.0f → %.0f pt/s)", MotionGateCheckHelpers.axes[axis], before, step, Double(before) * rec.hz, Double(step) * rec.hz)
                    )))
                }
            }

            // Motion segments against scroll: overshoot, jiggle, reversal
            let dOwn: [Float?] = (1..<fs.count).map { j in
                fs[j].0 == fs[j - 1].0 + 1 ? (MotionGateCheckHelpers.ownEdge(fs[j].1, axis) - MotionGateCheckHelpers.ownEdge(fs[j - 1].1, axis)) : nil
            }
            func moving(_ j: Int) -> Bool {
                guard let x = dOwn[j - 1] else { return false }
                return abs(x) > 0.01
            }
            var j = 1
            while j < fs.count {
                if !moving(j) { j += 1; continue }
                let a = j
                var b = j
                while j < fs.count && dOwn[j - 1] != nil && (j - b) <= 3 {
                    if moving(j) { b = j }
                    j += 1
                }
                j = b + 1
                if b - a + 1 < 3 { continue }
                let seg = Array(fs[(a - 1)...b])
                let k0 = seg[0].0
                let k1 = seg[seg.count - 1].0
                if k1 <= rec.start ||
                    seg.allSatisfy({ !MotionGateCheckHelpers.seen($0.1, size) || $0.1.op < motionGateRule("faint") }) ||
                    seg.contains(where: { ($0.1.flags & (MotionGateSnapFlags.live | MotionGateSnapFlags.virtual)) != 0 }) {
                    continue
                }
                if inputBetween(k0 + 1, k1) { continue }
                let vals = seg.map { MotionGateCheckHelpers.ownEdge($0.1, axis) }
                let startVal = vals[0]
                let restVal = vals[vals.count - 1]
                let travel = restVal - startVal
                var signs: [Float] = []
                var last = startVal
                for v in vals.dropFirst() {
                    if abs(v - last) > 0.05 {
                        let s: Float = v > last ? 1.0 : -1.0
                        if signs.last != s { signs.append(s) }
                        last = v
                    }
                }
                let reversals = max(0, signs.count - 1)
                if reversals == 0 { continue }
                let dir: Float = abs(travel) > 0.5 ? (travel > 0 ? 1.0 : -1.0) : signs[0]
                let past = vals.map { ($0 - restVal) * dir }.reduce(0.0, max)
                let back = vals.map { (startVal - $0) * dir }.reduce(0.0, max)
                let amp = (vals.max() ?? 0) - (vals.min() ?? 0)
                let name = motionGateShort(t.path)

                let kind: String
                let detail: String
                if past >= motionGateRule("overshoot") && abs(travel) > 0.5 {
                    kind = "overshoot"
                    detail = String(format: "%@ %.1f → %.1f passes its rest by %.1f pt (%.0f%%)", MotionGateCheckHelpers.axes[axis], startVal, restVal, past, 100.0 * past / abs(travel))
                } else if reversals >= 2 && amp >= motionGateRule("jiggle") {
                    kind = "jiggle"
                    detail = String(format: "%@ reverses %d× over %.1f pt (%.1f → %.1f)", MotionGateCheckHelpers.axes[axis], reversals, amp, startVal, restVal)
                } else if back >= motionGateRule("reversal") {
                    kind = "reversal"
                    detail = String(format: "%@ %.1f → %.1f heads %.1f pt the wrong way first", MotionGateCheckHelpers.axes[axis], startVal, restVal, back)
                } else if abs(travel) <= 0.5 && amp >= motionGateRule("reversal") {
                    kind = "reversal"
                    detail = String(format: "%@ goes %.1f pt out from %.1f and back", MotionGateCheckHelpers.axes[axis], amp, startVal)
                } else {
                    continue
                }
                geo.append((i, MotionGateFinding(kind: kind, element: name, frame: k0 + 1, detail: "\(detail) over frames \(k0 + 1)–\(k1)")))
            }
        }

        // Opacity dips (flicker)
        var spans: [(Int, Int)] = []
        var j = 0
        while j < fs.count {
            let s = fs[j].1
            if fs[j].0 <= rec.start || s.op < 0.6 || (s.flags & MotionGateSnapFlags.exiting) != 0 ||
                (s.flags & MotionGateSnapFlags.ink) == 0 || !MotionGateCheckHelpers.seen(s, size) {
                j += 1
                continue
            }
            let horizon = fs[j].0 + Int(0.3 * rec.hz)
            var low = s.op
            var lowAt = j
            var backIdx: Int? = nil
            var m = j + 1
            while m < fs.count && fs[m].0 <= horizon && fs[m].0 == fs[m - 1].0 + 1 {
                if fs[m].1.op < low {
                    low = fs[m].1.op
                    lowAt = m
                }
                if low <= s.op - motionGateRule("flicker") && fs[m].1.op >= s.op - 0.1 {
                    backIdx = m
                    break
                }
                m += 1
            }
            if let m = backIdx {
                let answered = rec.inputs.filter { $0.0 > fs[j].0 && $0.0 <= fs[m].0 }.count >= 2
                if !answered {
                    geo.append((i, MotionGateFinding(
                        kind: "flicker",
                        element: motionGateShort(t.path),
                        frame: fs[lowAt].0,
                        detail: String(format: "opacity %.2f → %.2f → %.2f over frames %d–%d", s.op, low, fs[m].1.op, fs[j].0, fs[m].0)
                    )))
                    spans.append((fs[j].0, fs[m].0))
                }
                j = m + 1
            } else {
                j += 1
            }
        }

        // Words swap in place (text-swap)
        if t.words.count >= 2 {
            for idx in 1..<t.words.count {
                let old = t.words[idx - 1].1
                let k = t.words[idx].0
                let new = t.words[idx].1
                guard let a = t.at(max(0, k - 1)), let b = t.at(k) else { continue }
                if k <= rec.start || parents.contains(i) ||
                    MotionGateCheckHelpers.startsWithWords(new, old) ||
                    MotionGateCheckHelpers.startsWithWords(old, new) ||
                    (!rec.countsRoll && MotionGateCheckHelpers.ticks(old, new)) {
                    continue
                }
                if ((a.flags | b.flags) & (MotionGateSnapFlags.live | MotionGateSnapFlags.exiting | MotionGateSnapFlags.virtual)) != 0 ||
                    min(a.op, b.op) < motionGateRule("text-swap") ||
                    !MotionGateCheckHelpers.seen(b, size) {
                    continue
                }
                geo.append((i, MotionGateFinding(
                    kind: "text-swap",
                    element: motionGateShort(t.path),
                    frame: k,
                    detail: "\"\(old)\" → \"\(new)\" in one frame"
                )))
            }
        }

        // Opacity steps instead of fading (fade-snap)
        if fs.count >= 2 {
            for idx in 1..<fs.count {
                let a = fs[idx - 1].1
                let b = fs[idx].1
                let k = fs[idx].0
                if k != fs[idx - 1].0 + 1 || k <= rec.start || abs(a.op - b.op) < motionGateRule("fade-snap") {
                    continue
                }
                let shown = b.op > a.op ? b : a
                if spans.contains(where: { k >= $0.0 && k <= $0.1 }) { continue }
                if !MotionGateCheckHelpers.seen(shown, size) ||
                    (shown.flags & MotionGateSnapFlags.ink) == 0 ||
                    MotionGateCheckHelpers.rectArea(MotionGateCheckHelpers.onWindow(shown.vis, size)) < 16.0 ||
                    ((a.flags | b.flags) & (MotionGateSnapFlags.exiting | MotionGateSnapFlags.virtual)) != 0 {
                    continue
                }
                geo.append((i, MotionGateFinding(
                    kind: "fade-snap",
                    element: motionGateShort(t.path),
                    frame: k,
                    detail: String(format: "opacity %.2f → %.2f in one frame", a.op, b.op)
                )))
            }
        }
    }

    // Deduplicate child riding parent
    struct RepKey: Hashable { let i: Int; let kind: String; let frame: Int }
    let parentDupKinds: Set<String> = ["reversal", "overshoot", "jiggle", "flicker", "jerk", "fade-snap", "snap", "flash", "changes-twice"]
    let reported = Set(geo.map { RepKey(i: $0.0, kind: $0.1.kind, frame: $0.1.frame) })
    for (i, f) in geo {
        var p = tr[i].parent
        var dup = false
        while let j = p {
            if parentDupKinds.contains(f.kind) && (0...2).contains(where: { o in
                reported.contains(RepKey(i: j, kind: f.kind, frame: max(0, f.frame - o))) ||
                reported.contains(RepKey(i: j, kind: f.kind, frame: f.frame + o))
            }) {
                dup = true
                break
            }
            p = tr[j].parent
        }
        if !dup { out.append(f) }
    }

    // Load-motion
    for load in rec.loads {
        let quietUntil = (inputFrames + rec.loads).filter { $0 > load + 1 }.min() ?? n
        var hits: [(Int, MotionGateFinding)] = []
        for (i, t) in tr.enumerated() {
            guard let b = born(t), b >= load && b <= load + 2, !loops.contains(i) else { continue }
            guard let first = t.at(b + 1) else { continue }
            if b + 2 < min(quietUntil, n) {
                for k in (b + 2)..<min(quietUntil, n) {
                    guard let s = t.at(k) else { break }
                    let dy = (0..<4).map { abs(s.rect[$0] - first.rect[$0]) }.reduce(0.0, max)
                    let dop = abs(s.op - first.op)
                    if (dy > motionGateRule("load-motion") || dop > 0.1) && MotionGateCheckHelpers.seen(s, size) {
                        let desc = dy > motionGateRule("load-motion")
                            ? String(format: "moved %.1f pt", dy)
                            : String(format: "faded %.2f → %.2f", first.op, s.op)
                        hits.append((i, MotionGateFinding(kind: "load-motion", element: motionGateShort(t.path), frame: k, detail: "loaded at frame \(b), then \(desc) by frame \(k)")))
                        break
                    }
                }
            }
        }
        let hitSet = Set(hits.map(\.0))
        for (i, f) in hits where !(tr[i].parent.map { hitSet.contains($0) } ?? false) {
            out.append(f)
        }
    }

    // Never-settles
    let lastInput = inputFrames.max() ?? 0
    let tail = Int(0.5 * rec.hz)
    if n > tail && (n - tail) > lastInput + Int(0.5 * rec.hz) {
        var still: [(Int, Float)] = []
        for (i, t) in tr.enumerated() where !loops.contains(i) {
            let fs = t.frames.filter { $0.0 >= n - tail }
            var moved: Float = 0
            if fs.count >= 2 {
                for idx in 1..<fs.count {
                    var stepMax = abs(fs[idx].1.op - fs[idx - 1].1.op)
                    for a in 0..<4 {
                        stepMax = max(stepMax, abs(fs[idx].1.rect[a] - fs[idx - 1].1.rect[a]))
                    }
                    moved = max(moved, stepMax)
                }
            }
            if moved > motionGateRule("never-settles") && fs.contains(where: { MotionGateCheckHelpers.seen($0.1, size) }) {
                still.append((i, moved))
            }
        }
        let stillSet = Set(still.map(\.0))
        for (i, moved) in still where !(tr[i].parent.map { stillSet.contains($0) } ?? false) {
            out.append(MotionGateFinding(
                kind: "never-settles",
                element: motionGateShort(tr[i].path),
                frame: n - tail,
                detail: String(format: "still moving %.2f pt/frame in the last 0.5 s", moved)
            ))
        }
    }

    MotionGateLoops.checkJumps(rec, out: &out)
    MotionGateCommits.scrollCommits(rec, out: &out)
    MotionGateKicks.kicks(rec, loops: loops, out: &out)

    // Remount
    let remountWindow = Int(motionGateRule("remount"))
    func leaving(_ i: Int, _ k: Int) -> Bool {
        var p: Int? = i
        while let j = p {
            if let s = tr[j].at(k), (s.flags & MotionGateSnapFlags.exiting) != 0 { return true }
            p = tr[j].parent
        }
        return false
    }
    func wordsAt(_ t: MotionGateTrack, _ k: Int) -> String? {
        t.words.reversed().first(where: { $0.0 <= k })?.1 ?? t.text
    }
    func rekeyed(_ a: String, _ b: String) -> Bool {
        func trimLeaving(_ s: String) -> String {
            s.hasSuffix(" (leaving)") ? String(s.dropLast(" (leaving)".count)) : s
        }
        let sa = trimLeaving(a).split(separator: "/", omittingEmptySubsequences: false)
        let sb = trimLeaving(b).split(separator: "/", omittingEmptySubsequences: false)
        return sa.count == sb.count && zip(sa, sb).filter { $0 != $1 }.count == 1
    }
    for (i, t) in tr.enumerated() where t.frames.count >= 2 {
        var kLeave: Int? = nil
        for idx in 1..<t.frames.count {
            let w0 = t.frames[idx - 1]
            let w1 = t.frames[idx]
            if w1.0 == w0.0 + 1 && w0.0 > rec.start && !leaving(i, w0.0) && leaving(i, w1.0) && MotionGateCheckHelpers.seen(w0.1, size) {
                kLeave = w1.0
                break
            }
        }
        guard let k = kLeave,
              let words = wordsAt(t, k),
              words.trimmingCharacters(in: .whitespacesAndNewlines).count >= 8 else { continue }
        if let copy = tr.enumerated().first(where: { (j, o) in
            guard j != i, rekeyed(t.path, o.path), let b = born(o) else { return false }
            return b > rec.start && b + remountWindow >= k && b <= k + remountWindow && !leaving(j, b) && wordsAt(o, b) == words
        })?.element {
            out.append(MotionGateFinding(
                kind: "remount",
                element: motionGateShort(t.path),
                frame: k,
                detail: "\"\(String(words.prefix(40)))\" leaves as a copy mounts at \(motionGateShort(copy.path))"
            ))
        }
    }

    // Unpinned
    func touched(_ a: Int, _ b: Int) -> Bool {
        rec.inputs.contains { $0.0 >= a && $0.0 <= b && !$0.1.hasPrefix("event") }
    }
    for t in tr {
        guard let pIdx = t.parent else { continue }
        let parent = tr[pIdx]
        var pinned: Int? = nil
        for (k, s) in t.frames {
            let viewport = parent.at(k).map { v in (0..<4).allSatisfy { abs(v.rect[$0] - s.vis[$0]) < 0.5 } } ?? false
            if !viewport || s.rect[3] <= s.vis[3] + 1.0 {
                pinned = nil
                continue
            }
            let below = s.rect[1] + s.rect[3] - (s.vis[1] + s.vis[3])
            if abs(below) < 0.5 {
                pinned = k
                continue
            }
            if let p = pinned, k > rec.start && below >= motionGateRule("unpinned") && !touched(p, k) {
                out.append(MotionGateFinding(
                    kind: "unpinned",
                    element: motionGateShort(t.path),
                    frame: k,
                    detail: String(format: "its end, pinned at frame %d, is %.1f pt below the viewport", p, below)
                ))
                pinned = nil
            }
        }
    }

    // Twice (`#dup`)
    for t in tr where MotionGateCheckHelpers.lastSeg(t.path).contains("#dup") {
        if let f = t.frames.first(where: { $0.1.op >= motionGateRule("faint") && $0.1.vis[2] > 0.0 && $0.1.vis[3] > 0.0 }) {
            out.append(MotionGateFinding(kind: "twice", element: motionGateShort(t.path), frame: f.0, detail: "a second element under its key"))
        }
    }

    // Lands-unseen
    let unseenWindow = Int(1.5 * rec.hz)
    var unseen: [Int: Int] = [:]
    for (i, t) in tr.enumerated() where t.frames.count >= 2 {
        var hitIdx: Int? = nil
        for j in 1..<t.frames.count {
            let (ka, a) = t.frames[j - 1]
            let (kb, b) = t.frames[j]
            let whole = a.rect[2] >= 4.0 && a.rect[3] >= 4.0 && MotionGateCheckHelpers.rectArea(a.vis) >= 0.9 * MotionGateCheckHelpers.rectArea(a.rect)
            let still = (0..<4).allSatisfy { abs(a.rect[$0] - b.rect[$0]) < 0.5 }
            let shown = a.op >= motionGateRule("faint") && (a.flags & MotionGateSnapFlags.ink) != 0 && ((a.flags | b.flags) & MotionGateSnapFlags.exiting) == 0
            if kb != ka + 1 || !whole || !still || !shown || MotionGateCheckHelpers.rectArea(MotionGateCheckHelpers.onWindow(b.vis, size)) >= 1.0 {
                continue
            }
            let travelled = t.frames[..<j].reversed().prefix(while: { $0.0 + unseenWindow >= ka }).contains { f in
                let sameSize = (2..<4).allSatisfy { abs(f.1.rect[$0] - a.rect[$0]) < 1.0 }
                let travel = abs(f.1.rect[0] - a.rect[0]) + abs(f.1.rect[1] - a.rect[1])
                return sameSize && MotionGateCheckHelpers.seen(f.1, size) && travel >= motionGateRule("lands-unseen")
            }
            if travelled {
                hitIdx = j
                break
            }
        }
        guard let j = hitIdx else { continue }
        let k = t.frames[j].0
        unseen[i] = k
        if let p = t.parent, unseen[p] == k { continue }
        out.append(MotionGateFinding(kind: "lands-unseen", element: motionGateShort(t.path), frame: k, detail: "travelled in view, then its clip hid it where it rests"))
    }

    // Wakes-after-end
    if let q = rec.quietFrom {
        let from = q + Int(Double(motionGateRule("wakes-after-end")) * rec.hz)
        if from < n, let k = (from..<n).first(where: { $0 < rec.awake.count && rec.awake[$0] }) {
            out.append(MotionGateFinding(
                kind: "wakes-after-end",
                element: "frame",
                frame: k,
                detail: String(format: "asked for a frame %.2f s after the motion ended", Double(k - q) / rec.hz)
            ))
        }
    }

    // Load swap suppression
    let loadKinds: Set<String> = ["pop-in", "pop-out", "jump", "offset-jump", "appear-then-jump", "fade-snap"]
    out.removeAll { f in
        loadKinds.contains(f.kind) && rec.loads.contains(where: { f.frame >= $0 && f.frame <= $0 + 2 })
    }

    MotionGatePainted.filterIntended(rec, out: &out)
    out.append(contentsOf: MotionGateRegions.checkRegions(rec, loops: loops, found: out))
    out.sort { ($0.frame, $0.kind) < ($1.frame, $1.kind) }
    return out
}

// MARK: - Sub-Checkers (`loops`, `kicks`, `commits`, `painted`, `regions`)

private enum MotionGateLoops {
    static func playsOut(_ t: MotionGateTrack) -> Bool {
        guard t.frames.count >= 2 else { return false }
        for idx in 1..<t.frames.count {
            if t.frames[idx - 1].1.phase == 1.0 && t.frames[idx].1.phase == 1.0 {
                return true
            }
        }
        return false
    }

    static func periodicPhase(_ t: MotionGateTrack, frames n: Int) -> Bool {
        let ph = t.frames.filter { !$0.1.phase.isNaN }.map { ($0.0, $0.1.phase) }
        guard ph.count >= 2 else { return false }
        let steps = (1..<ph.count).compactMap { idx -> ((Int, Float), (Int, Float))? in
            ph[idx].0 == ph[idx - 1].0 + 1 ? (ph[idx - 1], ph[idx]) : nil
        }
        let wraps = steps.contains { $0.1.1 < $0.0.1 - 0.5 }
        let toEnd = (ph.last.map { $0.0 + 1 == n } ?? false) && (steps.last.map { $0.1.1 != $0.0.1 } ?? false)
        return (wraps || toEnd) && !playsOut(t)
    }

    static func findLoops(_ rec: MotionGateRecording) -> Set<Int> {
        let tr = rec.tracks
        let answer = Int(0.5 * rec.hz)
        func answering(_ k: Int) -> Bool { rec.inputs.contains { $0.0 <= k && k <= $0.0 + answer } }
        func changed(_ a: MotionGateSnap, _ b: MotionGateSnap) -> Bool {
            (0..<4).contains { abs(a.rect[$0] - b.rect[$0]) > 0.01 } || abs(a.op - b.op) > 0.002
        }
        var busy = Array(repeating: 0, count: tr.count)
        var groupBusy: [Int: Set<Int>] = [:]
        for (i, t) in tr.enumerated() where t.frames.count >= 2 {
            for idx in 1..<t.frames.count where t.frames[idx].0 == t.frames[idx - 1].0 + 1 {
                if changed(t.frames[idx - 1].1, t.frames[idx].1) {
                    busy[i] += 1
                    if let p = t.parent { groupBusy[p, default: []].insert(t.frames[idx].0) }
                }
            }
        }
        func periodic(_ t: MotionGateTrack) -> Bool {
            func turns(_ eps: Float, _ v: (MotionGateSnap) -> Float) -> Int {
                guard !t.frames.isEmpty else { return 0 }
                var n = 0
                var last = v(t.frames[0].1)
                var dir: Float = 0
                for f in t.frames.dropFirst() {
                    let x = v(f.1)
                    if abs(x - last) > eps {
                        let s: Float = x > last ? 1.0 : -1.0
                        if dir != 0 && s != dir && !answering(f.0) { n += 1 }
                        dir = s
                        last = x
                    }
                }
                return n
            }
            if turns(0.01, { $0.op }) >= 4 { return true }
            return (0..<4).contains { axis in turns(0.25, { $0.rect[axis] }) >= 4 }
        }
        func busyMost(_ i: Int, _ frames: Int) -> Bool {
            tr[i].frames.count >= 60 && frames * 10 >= tr[i].frames.count * 6
        }
        var loops = Set((0..<tr.count).filter { i in
            periodicPhase(tr[i], frames: rec.frames) || (busyMost(i, busy[i]) && periodic(tr[i]))
        })
        for (p, ks) in groupBusy {
            if busyMost(p, ks.count) && tr.contains(where: { $0.parent == p && $0.frames.count >= 2 && periodic($0) }) {
                for c in 0..<tr.count where tr[c].parent == p { loops.insert(c) }
            }
        }
        while true {
            let more = (0..<tr.count).filter { i in
                !loops.contains(i) && (tr[i].parent.map { loops.contains($0) } ?? false)
            }
            if more.isEmpty { break }
            loops.formUnion(more)
        }
        return loops
    }

    static func checkJumps(_ rec: MotionGateRecording, out: inout [MotionGateFinding]) {
        let blink = Int(0.1 * rec.hz)
        for t in rec.tracks where !playsOut(t) {
            let ph = t.frames.filter { !$0.1.phase.isNaN }.map { ($0.0, $0.1.phase) }
            guard ph.count >= 2 else { continue }
            var steps: [(Int, Int, Float)] = []
            for idx in 1..<ph.count {
                let df = ph[idx].0 - ph[idx - 1].0
                if df <= blink {
                    var delta = (ph[idx].1 - ph[idx - 1].1).truncatingRemainder(dividingBy: 1.0)
                    if delta < 0 { delta += 1.0 }
                    steps.append((ph[idx].0, df, delta))
                }
            }
            guard steps.count >= 2 else { continue }
            let moving = (1..<steps.count).compactMap { idx -> (Int, Int, Float)? in
                (steps[idx - 1].2 > 0.0 && steps[idx].2 > 0.0) ? steps[idx] : nil
            }
            let sorted = moving.filter { $0.1 == 1 }.map(\.2).sorted()
            if sorted.count < 4 { continue }
            let usual = sorted[sorted.count / 2]
            func off(_ s: (Int, Int, Float)) -> Float {
                var x = (s.2 - Float(s.1) * usual).truncatingRemainder(dividingBy: 1.0)
                if x < 0 { x += 1.0 }
                return min(x, 1.0 - x)
            }
            if let hit = moving.first(where: { off($0) > motionGateRule("loop-jump") }) {
                let over = hit.1 > 1 ? " over \(hit.1) frames" : ""
                out.append(MotionGateFinding(
                    kind: "loop-jump",
                    element: motionGateShort(t.path),
                    frame: hit.0,
                    detail: String(format: "phase stepped %.3f%@ where it steps %.3f a frame", hit.2, over, usual)
                ))
            }
        }
    }
}

private enum MotionGateCommits {
    static let minCommits = 6

    static func scrollCommits(_ rec: MotionGateRecording, out: inout [MotionGateFinding]) {
        let share = motionGateRule("scroll-commit")
        var k = 0
        while k < rec.scrolled.count {
            if !rec.scrolled[k].0 {
                k += 1
                continue
            }
            let from = k
            while k < rec.scrolled.count && rec.scrolled[k].0 { k += 1 }
            let runLen = k - from
            let committed = (from..<k).filter { rec.scrolled[$0].1 != 0 }
            if committed.count < minCommits || Float(committed.count) < share * Float(runLen) { continue }
            let why = (from..<k).reduce(UInt16(0)) { $0 | rec.scrolled[$1].1 }
            out.append(MotionGateFinding(
                kind: "scroll-commit",
                element: "frame",
                frame: committed[0],
                detail: "ran the view on \(committed.count) of the \(runLen) frames of a scroll (\(CommitWhy.names(why).joined(separator: ", "))): the debug build's `rune:` warning names the site"
            ))
        }
    }
}

private enum MotionGateKicks {
    static let still: Float = 0.005
    static let kickMin: Float = 0.25
    static let restFrames = 3
    static let pauseSecs = 0.5
    static let windowSecs = 2.0

    static func kicks(_ rec: MotionGateRecording, loops: Set<Int>, out: inout [MotionGateFinding]) {
        let tr = rec.tracks
        let pause = Int(pauseSecs * rec.hz)
        let window = Int(windowSecs * rec.hz)
        let need = Int(motionGateRule("stop-start"))
        func touched(_ a: Int, _ b: Int) -> Bool {
            rec.inputs.contains { $0.0 >= a && $0.0 <= b && !$0.1.hasPrefix("event") }
        }
        var hits: [(Int, MotionGateFinding)] = []
        for (i, t) in tr.enumerated() where !loops.contains(i) {
            for axis in 0..<2 {
                var restarts: [Int] = []
                var prev: (Int, Float)? = nil
                var dir: Float = 0
                var stillCount = 0
                var went: Float = 0
                for (k, s) in t.frames {
                    if k <= rec.start || s.op < motionGateRule("faint") || !MotionGateCheckHelpers.seen(s, rec.size) {
                        prev = nil
                        dir = 0
                        stillCount = 0
                        went = 0
                        continue
                    }
                    let at = MotionGateCheckHelpers.edge(s, axis)
                    if let p = prev, p.0 + 1 == k {
                        let d = at - p.1
                        if abs(d) < still {
                            stillCount += 1
                        } else {
                            if stillCount >= restFrames {
                                let dSign: Float = d > 0 ? 1.0 : -1.0
                                if stillCount <= pause && dSign == dir && went >= kickMin {
                                    restarts.append(k)
                                }
                                went = 0
                            }
                            went += abs(d)
                            dir = d > 0 ? 1.0 : -1.0
                            stillCount = 0
                        }
                    }
                    prev = (k, at)
                }
                if need >= 1 && restarts.count >= need,
                   let j = (0...(restarts.count - need)).first(where: { idx in
                       let last = restarts[idx + need - 1]
                       return last - restarts[idx] <= window && !touched(restarts[idx], last)
                   }) {
                    let k = restarts[j]
                    let n = restarts[j...].prefix(while: { $0 - k <= window }).count
                    let axisName = axis == 0 ? "x" : "y"
                    hits.append((i, MotionGateFinding(
                        kind: "stop-start",
                        element: motionGateShort(t.path),
                        frame: k,
                        detail: "\(axisName) rests and sets off again \(n) times in \(windowSecs) s"
                    )))
                    break
                }
            }
        }
        func family(_ i: Int) -> [Int] {
            var up = [i]
            var p = tr[i].parent
            while let j = p {
                up.append(j)
                p = tr[j].parent
            }
            return up
        }
        var kept: [(Int, Int)] = []
        hits.sort { (family($0.0).count, $0.1.frame) < (family($1.0).count, $1.1.frame) }
        for (i, f) in hits {
            let up = family(i)
            let near = kept.contains { (j, k) in
                abs(k - f.frame) <= window && (up.contains(j) || (tr[j].parent.map { up.contains($0) } ?? false))
            }
            if near { continue }
            kept.append((i, f.frame))
            out.append(f)
        }
    }
}

private enum MotionGatePainted {
    static func intentFor(_ kind: String) -> MotionIntent {
        switch kind {
        case "overshoot": return .overshoot
        case "reversal": return [.recoil, .jiggle]
        case "jiggle": return .jiggle
        case "jerk", "stop-start": return .impulse
        case "jump", "appear-then-jump", "offset-jump", "changes-twice": return .step
        case "pop-in", "pop-out", "cut-exit", "fade-snap", "text-swap": return .cut
        case "flicker", "flash": return .pulse
        case "snap": return [.step, .cut]
        default: return .none
        }
    }

    static func tune(hz: Double) -> MotionGateSeries.Tune {
        MotionGateSeries.Tune(
            snap: motionGateRule("snap"),
            flash: motionGateRule("flash"),
            still: 0.04,
            horizon: Int((0.4 * hz).rounded()),
            rest: (2, Int((Double(motionGateRule("changes-twice")) * hz).rounded()))
        )
    }

    static func marked(_ t: MotionGateTrack, frame k: Int, kind: String) -> Bool {
        let bits = intentFor(kind)
        if bits == .none { return false }
        return [max(0, k - 1), k].contains { t.paintAt($0)?.intends(bits) ?? false }
    }

    static func filterIntended(_ rec: MotionGateRecording, out: inout [MotionGateFinding]) {
        var byName: [String: [MotionGateTrack]] = [:]
        for t in rec.tracks where t.paint.contains(where: { ($0?.intent ?? 0) != 0 }) {
            byName[motionGateShort(t.path), default: []].append(t)
        }
        if byName.isEmpty { return }
        out.removeAll { f in
            byName[f.element]?.contains(where: { marked($0, frame: f.frame, kind: f.kind) }) ?? false
        }
    }

    private static func shows(_ s: MotionGateSnap, _ size: (Float, Float)) -> Bool {
        MotionGateCheckHelpers.seen(s, size) &&
        s.op >= motionGateRule("faint") &&
        (s.flags & (MotionGateSnapFlags.exiting | MotionGateSnapFlags.live)) == 0
    }

    static func checkPainted(_ rec: MotionGateRecording, loops: Set<Int>) -> [(Int, MotionGateFinding)] {
        let tTune = tune(hz: rec.hz)
        let n = rec.frames
        var out: [(Int, MotionGateFinding)] = []
        func inputCount(_ a: Int, _ b: Int) -> Int {
            rec.inputs.filter { $0.0 >= a && $0.0 <= b }.count
        }
        for (i, t) in rec.tracks.enumerated() {
            if loops.contains(i) || t.paint.isEmpty { continue }
            let at: [(MotionGateSnap, MotionGatePaint)?] = (0..<n).map { k in
                guard let s = t.at(k), let p = t.paintAt(k), k >= rec.start, shows(s, rec.size), !p.instant else {
                    return nil
                }
                return (s, p)
            }
            if at.allSatisfy({ $0 == nil }) { continue }
            for (c, ch) in MotionGatePaintUtils.channels.enumerated() {
                let vals: [MotionGateSeries.V6?] = at.map { pair in
                    guard let (_, p) = pair, !p.isAtOnce(c) else { return nil }
                    return ch.embed(p)
                }
                func weight(_ k: Int) -> Float {
                    func one(_ j: Int) -> Float {
                        guard j >= 0 && j < at.count, let (s, p) = at[j] else { return 0.0 }
                        let ow = MotionGateCheckHelpers.onWindow(s.vis, rec.size)
                        return ch.weight(p, SIMD4<Float>(ow[0], ow[1], ow[2], ow[3])) * min(s.op, 1.0)
                    }
                    return max(one(k), one(k - 1))
                }
                func pointerChanged(_ a: Int, _ b: Int) -> Bool {
                    guard ch.name == "fill" || ch.name == "text-color", max(a, 1) <= b else { return false }
                    return (max(a, 1)...b).contains { j in
                        guard let cur = at[j], let prev = at[j - 1] else { return false }
                        return cur.1.pointer != prev.1.pointer
                    }
                }
                for e in MotionGateSeries.events(vals, tune: tTune, weight: weight) {
                    let k = e.k
                    let skip: Bool
                    switch e.kind {
                    case "snap":
                        skip = inputCount(max(0, k - 1), k) > 0 || (k < rec.instant.count && rec.instant[k]) || pointerChanged(k, k)
                    case "flash":
                        skip = inputCount(e.span.0 + 1, e.span.1) >= 2 || pointerChanged(e.span.0 + 1, e.span.1)
                    default:
                        skip = inputCount(e.span.0 + 1, e.span.1) > 0 || pointerChanged(e.span.0 + 1, e.span.1)
                    }
                    if skip || marked(t, frame: k, kind: e.kind) || rec.loads.contains(where: { k >= $0 && k <= $0 + 2 }) {
                        continue
                    }
                    func vStr(_ j: Int) -> String {
                        guard j >= 0 && j < at.count, let (_, p) = at[j] else { return "–" }
                        return MotionGatePaintUtils.value(p, channel: ch.name)
                    }
                    let detail: String
                    switch e.kind {
                    case "snap":
                        detail = "\(ch.name) \(vStr(k - 1)) → \(vStr(k)) in one frame"
                    case "flash":
                        detail = "\(ch.name) \(vStr(e.span.0)) → \(vStr(k)) → \(vStr(e.span.1)) over frames \(e.span.0)–\(e.span.1)"
                    default:
                        detail = "\(ch.name) \(vStr(e.span.0)) → \(vStr(k - 1)), rests, then → \(vStr(e.span.1)) over frames \(e.span.0)–\(e.span.1)"
                    }
                    out.append((i, MotionGateFinding(kind: e.kind, element: motionGateShort(t.path), frame: k, detail: detail)))
                }
            }
        }
        out.append(contentsOf: checkZOrder(rec))
        return out
    }

    private static func checkZOrder(_ rec: MotionGateRecording) -> [(Int, MotionGateFinding)] {
        let n = rec.frames
        guard n > rec.start else { return [] }
        let horizon = Int((0.4 * rec.hz).rounded())
        let tr = rec.tracks
        func solid(_ k: Int) -> [(Int, UInt32, [Float])] {
            tr.enumerated().compactMap { (i, t) in
                guard let s = t.at(k), let p = t.paintAt(k) else { return nil }
                guard shows(s, rec.size),
                      (s.flags & MotionGateSnapFlags.growing) == 0,
                      s.op >= 0.5,
                      p.opaque,
                      MotionGateCheckHelpers.rectArea(s.vis) >= 64.0 else { return nil }
                return (i, p.rank, s.vis)
            }
        }
        func meets(_ a: [Float], _ b: [Float]) -> Bool {
            MotionGateCheckHelpers.rectArea(MotionGateCheckHelpers.meet(a, b)) >= 64.0
        }
        struct Pair: Hashable { let lo: Int; let hi: Int }
        var out: [(Int, MotionGateFinding)] = []
        var prev = solid(rec.start)
        var flipped: Set<Pair> = []
        if rec.start + 1 < n {
            for k in (rec.start + 1)..<n {
                let cur = solid(k)
                var before: [Int: (UInt32, [Float])] = [:]
                for (i, r, v) in prev { before[i] = (r, v) }
                for x in 0..<cur.count {
                    let (a, ra, va) = cur[x]
                    guard let (pa, pva) = before[a] else { continue }
                    for y in (x + 1)..<cur.count {
                        let (b, rb, vb) = cur[y]
                        guard let (pb, pvb) = before[b] else { continue }
                        if (ra > rb) == (pa > pb) || !meets(va, vb) || !meets(pva, pvb) ||
                            MotionGateCheckHelpers.inside(tr[a].path, tr[b].path) ||
                            MotionGateCheckHelpers.inside(tr[b].path, tr[a].path) { continue }
                        let pair = Pair(lo: min(a, b), hi: max(a, b))
                        if rec.inputs.contains(where: { $0.0 + 1 >= k && $0.0 <= k }) || flipped.contains(pair) { continue }
                        let back = ((k + 1)..<min(n, k + horizon + 1)).first { j in
                            guard let p = tr[a].paintAt(j), let q = tr[b].paintAt(j) else { return false }
                            return (p.rank > q.rank) == (pa > pb)
                        }
                        let kind = back != nil ? "flash" : "snap"
                        if kind == "snap" && k < rec.instant.count && rec.instant[k] { continue }
                        let (who, other) = abs(Int64(ra) - Int64(pa)) >= abs(Int64(rb) - Int64(pb)) ? (a, b) : (b, a)
                        if marked(tr[who], frame: k, kind: kind) { continue }
                        let over = who == a ? (ra > rb) : (rb > ra)
                        flipped.insert(pair)
                        let backNote = back.map { ", and back at frame \($0)" } ?? ""
                        out.append((who, MotionGateFinding(
                            kind: kind,
                            element: motionGateShort(tr[who].path),
                            frame: k,
                            detail: "z-order: paints \(over ? "over" : "under") \(motionGateShort(tr[other].path)) in one frame\(backNote)"
                        )))
                    }
                }
                prev = cur
            }
        }
        return out
    }
}

private enum MotionGateRegions {
    static let bitBlocked: UInt8 = 1
    static let bitPulse: UInt8 = 2
    static let bitCut: UInt8 = 4
    static let bitStep: UInt8 = 8
    static let bitChanged: UInt8 = 16

    static func moved(_ a: MotionGateSnap, _ b: MotionGateSnap) -> Float {
        var d: Float = 0
        for i in 0..<4 {
            d = max(d, abs(a.rect[i] - b.rect[i]), abs(a.vis[i] - b.vis[i]))
        }
        return max(d, abs(a.scale - b.scale) * 100.0)
    }

    static func paintedDiffers(_ t: MotionGateTrack, _ k: Int) -> Bool {
        guard let a = t.paintAt(k - 1), let b = t.paintAt(k) else { return false }
        return a.colors != b.colors || a.sizes != b.sizes || a.gradientEnd != b.gradientEnd || a.effect != b.effect ||
            a.image?.0 != b.image?.0 || a.image?.1 != b.image?.1
    }

    static func guardMask(_ rec: MotionGateRecording, loops: Set<Int>, frame k: Int, dims: (Int, Int)) -> [UInt8] {
        let (w, h) = dims
        let cell = MotionGateGrid.cellSize
        var m = Array(repeating: UInt8(0), count: w * h)
        func mark(_ r: [Float], _ pad: Float, _ bit: UInt8) {
            if r[2] <= 0.0 && r[3] <= 0.0 { return }
            let x0 = max(0, Int(floor((r[0] - pad) / cell)))
            let y0 = max(0, Int(floor((r[1] - pad) / cell)))
            let x1 = min(w, max(0, Int(ceil((r[0] + r[2] + pad) / cell))))
            let y1 = min(h, max(0, Int(ceil((r[1] + r[3] + pad) / cell))))
            if y0 < y1 && x0 < x1 {
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        m[y * w + x] |= bit
                    }
                }
            }
        }
        for (i, t) in rec.tracks.enumerated() {
            let pp = k >= 2 ? t.at(k - 2) : nil
            let p = t.at(k - 1)
            let c = t.at(k)
            let nx = t.at(k + 1)
            let pad = [k - 1, k].compactMap { t.paintAt($0) }.map {
                $0.sizes[MotionGatePaint.sShadow] + 3.0 * $0.sizes[MotionGatePaint.sBlur]
            }.reduce(0.0, max)
            func span(_ bit: UInt8) {
                for s in [p, c, nx].compactMap({ $0 }) { mark(s.vis, pad + cell, bit) }
            }
            func step(_ a: MotionGateSnap?, _ b: MotionGateSnap?) -> Float {
                guard let a, let b else { return 0.0 }
                return moved(a, b)
            }
            let d0 = step(pp, p)
            let d1 = step(p, c)
            let d2 = step(c, nx)
            let bornOrGone = (p != nil) != (c != nil)
            let faded: Bool = {
                guard let p, let c else { return false }
                return abs(p.op - c.op) > 0.001
            }()
            if bornOrGone || d1 > 0.01 || faded || paintedDiffers(t, k) {
                for s in [p, c].compactMap({ $0 }) { mark(s.vis, pad, bitChanged) }
            }
            let shown = [p, c].compactMap { $0 }.filter { $0.op > 0.02 }
            if shown.isEmpty { continue }
            let around = max(d0, d2)
            let travelling = d1 > 0.25 && around > 0.25 && d1 <= 3.0 * around + 2.0
            let words = (t.words + t.edits).contains { $0.0 + 1 >= k && $0.0 <= k + 1 }
            let live = shown.contains { ($0.flags & MotionGateSnapFlags.live) != 0 }
            if travelling || words || live || loops.contains(i) { span(bitBlocked) }
            if MotionGatePainted.marked(t, frame: k, kind: "flash") { span(bitPulse) }
            if MotionGatePainted.marked(t, frame: k, kind: "snap") { span(bitCut) }
            if MotionGatePainted.marked(t, frame: k, kind: "changes-twice") { span(bitStep) }
        }
        for j in [k - 1, k] where j >= 0 && j < rec.tips.count {
            if let tip = rec.tips[j] { mark(tip, cell, bitBlocked) }
        }
        return m
    }

    static func checkRegions(_ rec: MotionGateRecording, loops: Set<Int>, found: [MotionGateFinding]) -> [MotionGateFinding] {
        let n = rec.frames
        guard let g0 = rec.grids.compactMap({ $0 }).first, rec.grids.count >= n, !rec.grids[..<n].contains(where: { $0 == nil }) else {
            return []
        }
        let (w, h) = (g0.w, g0.h)
        func grid(_ k: Int) -> MotionGateGrid { rec.grids[k]! }
        var tune = MotionGatePainted.tune(hz: rec.hz)
        tune.still = 0.06
        func v(_ k: Int, _ i: Int) -> MotionGateSeries.V6 {
            let t = MotionGatePaintUtils.toe(grid(k).lab(i))
            return (t.x / 0.08, t.y / 0.08, t.z / 0.08, 0, 0, 0)
        }
        struct Key: Hashable { let kind: String; let frame: Int }
        var hits: [Key: [(Int, MotionGateSeries.Event)]] = [:]
        let floorThresh = min(tune.flash, tune.snap)
        for i in 0..<(w * h) {
            let changes = n > 1 && (1..<n).contains { k in
                grid(k) !== grid(k - 1) && MotionGateSeries.dist(v(k, i), v(k - 1, i)) >= floorThresh
            }
            if !changes { continue }
            let vals: [MotionGateSeries.V6?] = (0..<n).map { k in k >= rec.start ? v(k, i) : nil }
            for e in MotionGateSeries.events(vals, tune: tune, weight: { _ in 1.0 }) {
                hits[Key(kind: e.kind, frame: e.k), default: []].append((i, e))
            }
        }
        func inputIn(_ a: Int, _ b: Int) -> Bool {
            rec.inputs.contains { $0.0 >= a && $0.0 <= b }
        }
        var guards: [Int: [UInt8]] = [:]
        var out: [MotionGateFinding] = []
        let keys = hits.keys.sorted { ($0.frame, $0.kind) < ($1.frame, $1.kind) }
        for key in keys {
            let kind = key.kind
            let k = key.frame
            if k <= rec.start || inputIn(max(0, k - 1), k) || rec.loads.contains(where: { k >= $0 && k <= $0 + 2 }) {
                continue
            }
            if kind == "snap" && k < rec.instant.count && rec.instant[k] { continue }
            func framesRange(_ e: MotionGateSeries.Event) -> ClosedRange<Int> {
                min(max(e.span.0, 1), k)...max(e.span.1, k)
            }
            for (_, e) in hits[key]! {
                for j in framesRange(e) where guards[j] == nil {
                    guards[j] = guardMask(rec, loops: loops, frame: j, dims: (w, h))
                }
            }
            let veto: UInt8 = bitBlocked | (kind == "flash" ? bitPulse : (kind == "snap" ? bitCut : bitStep))
            var cells: [Int: MotionGateSeries.Event] = [:]
            for (i, e) in hits[key]! {
                let vetoed = (kind != "flash" && (guards[k]![i] & bitChanged) != 0) ||
                    framesRange(e).contains { (guards[$0]![i] & veto) != 0 }
                if !vetoed && !(kind == "changes-twice" && inputIn(e.span.0, e.span.1)) {
                    cells[i] = e
                }
            }
            var seenCells: Set<Int> = []
            for s in cells.keys.sorted() {
                if !seenCells.insert(s).inserted { continue }
                var region = [s]
                var q = [s]
                while let c = q.popLast() {
                    let x = c % w
                    let y = c / w
                    let neighbors = [
                        x > 0 ? c - 1 : nil,
                        x + 1 < w ? c + 1 : nil,
                        y > 0 ? c - w : nil,
                        y + 1 < h ? c + w : nil
                    ].compactMap { $0 }
                    for nb in neighbors where cells[nb] != nil && seenCells.insert(nb).inserted {
                        region.append(nb)
                        q.append(nb)
                    }
                }
                if region.count < 2 { continue }
                let x0 = region.map { $0 % w }.min()!
                let y0 = region.map { $0 / w }.min()!
                let x1 = region.map { $0 % w }.max()! + 1
                let y1 = region.map { $0 / w }.max()! + 1
                let cellPt = MotionGateGrid.cellSize
                let rect: [Float] = [Float(x0) * cellPt, Float(y0) * cellPt, Float(x1 - x0) * cellPt, Float(y1 - y0) * cellPt]
                if explained(rec, found: found, kind: kind, k: k, rect: rect) { continue }
                let worst = region.max { cells[$0]!.size < cells[$1]!.size }!
                let e = cells[worst]!
                func hex(_ j: Int) -> String { grid(j).color(worst).hexString() }
                let colors = kind == "snap" ? "\(hex(k - 1)) → \(hex(k))" : "\(hex(e.span.0)) → \(hex(k)) → \(hex(e.span.1))"
                let was = topTrack(rec, frame: k - 1, rect: rect)
                let now = topTrack(rec, frame: k, rect: rect)
                func changed(_ t: MotionGateTrack) -> Bool {
                    let a = t.at(k - 1)
                    let b = t.at(k)
                    return a?.rect != b?.rect || a?.op != b?.op || paintedDiffers(t, k)
                }
                let who = [was, now].compactMap { $0 }.first(where: changed).map { motionGateShort($0.path) }
                    ?? (was ?? now).map { motionGateShort($0.path) }
                    ?? "window"
                out.append(MotionGateFinding(
                    kind: kind,
                    element: "\(who) (pixels)",
                    frame: k,
                    detail: String(format: "%d cells (%.0f×%.0f pt at %.0f,%.0f) %@ over frames %d–%d", region.count, rect[2], rect[3], rect[0], rect[1], colors, e.span.0, e.span.1)
                ))
            }
        }
        return out
    }

    private static func explained(_ rec: MotionGateRecording, found: [MotionGateFinding], kind: String, k: Int, rect: [Float]) -> Bool {
        let kinds: Set<String>
        switch kind {
        case "flash": kinds = ["flash", "flicker"]
        case "snap": kinds = ["snap", "fade-snap", "pop-in", "pop-out", "cut-exit", "jump", "offset-jump", "appear-then-jump", "text-swap"]
        default: kinds = ["changes-twice", "stop-start"]
        }
        return found.contains { f in
            guard kinds.contains(f.kind), f.frame + 1 >= k, f.frame <= k + 1 else { return false }
            return rec.tracks.filter { motionGateShort($0.path) == f.element }.contains { t in
                [max(0, k - 1), k].compactMap { t.at($0) }.contains { s in
                    MotionGateCheckHelpers.rectArea(MotionGateCheckHelpers.meet(s.vis, rect)) > 0.0
                }
            }
        }
    }

    private static func topTrack(_ rec: MotionGateRecording, frame k: Int, rect: [Float]) -> MotionGateTrack? {
        let cx = rect[0] + rect[2] * 0.5
        let cy = rect[1] + rect[3] * 0.5
        return rec.tracks.compactMap { t -> (UInt32, MotionGateTrack)? in
            guard let s = t.at(k), let p = t.paintAt(k) else { return nil }
            let paints = p.colors.contains { $0.a > 0.05 } || p.image != nil
            let over = s.vis[0] <= cx && cx <= s.vis[0] + s.vis[2] && s.vis[1] <= cy && cy <= s.vis[1] + s.vis[3]
            return (paints && over && s.op > 0.02) ? (p.rank, t) : nil
        }.max(by: { $0.0 < $1.0 })?.1
    }
}
