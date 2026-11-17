import Foundation
import RuneMotion

public typealias Rewind = RewindRecorder
public typealias Clip = RewindClip
public typealias Scrub = RewindScrubber
public typealias RewindShot = RewindElementSnapshot

// MARK: - Rewind Bundle (`rune::rewind::Bundle`)

/// Written bundle of a frozen rewind clip slice (`trace.jsonl`, `contact.png`, `summary.md`).
public struct RewindBundle: Sendable, Equatable {
    public let dir: URL
    public let summary: String
    public let frames: Range<Int>

    public var files: [URL] {
        ["summary.md", "trace.jsonl", "contact.png"].map { dir.appendingPathComponent($0) }
    }

    public init(dir: URL, summary: String, frames: Range<Int>) {
        self.dir = dir
        self.summary = summary
        self.frames = frames
    }
}

/// Selected frame range + note emitted by `RewindScrubber` (`rune::rewind::Sent`).
public struct RewindSent: Sendable, Equatable {
    public let clip: RewindClip
    public let frames: Range<Int>
    public let note: String

    public init(clip: RewindClip, frames: Range<Int>, note: String) {
        self.clip = clip
        self.frames = frames
        self.note = note
    }

    public func write(to dir: URL) throws -> RewindBundle {
        try clip.writeBundle(to: dir, range: frames, note: note)
    }
}

/// Outcome of routing a key event to `RewindScrubber.key(_:)` (`rune::rewind::Keyed`).
public enum RewindKeyed: Sendable, Equatable {
    case ignored
    case handled
    case closed
    case send(RewindSent)
}

private enum BundleContactConfig {
    static let tileW: Int = 320
    static let maxTiles: Int = 12
    static let cols: Int = 4
}

private struct BundleMotionSummary {
    struct ElementPeak {
        var framesCount = 0
        var maxDistance: Float = -1
        var bestFrame = 0
        var bestLabel = ""
    }

    var peaks: [UInt32: ElementPeak] = [:]
    var jumps: [String] = []

    mutating func record(_ changes: [RewindChange], frame: Int, time: Double) {
        for change in changes {
            if change.jump {
                jumps.append(String(format: "- frame %d (%.2f s): %@", frame, time, change.label()))
            }
            var peak = peaks[change.id] ?? ElementPeak()
            peak.framesCount += 1
            let distance = change.distance
            if distance > peak.maxDistance {
                peak.maxDistance = distance
                peak.bestFrame = frame
                peak.bestLabel = change.label()
            }
            peaks[change.id] = peak
        }
    }
}

extension RewindClip {
    /// Writes `trace.jsonl`, `contact.png`, and `summary.md` for `range` into `dir`.
    @discardableResult
    public func writeBundle(
        to dir: URL,
        range: Range<Int>,
        note: String = ""
    ) throws -> RewindBundle {
        let count = len
        let clampedEnd = max(min(range.upperBound, count), count > 0 ? 1 : 0)
        let clampedStart = max(0, min(range.lowerBound, clampedEnd - 1))
        let clampedRange = clampedStart..<clampedEnd

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let hz = (1 / frameIntervalSeconds()).rounded()
        let motion = try writeTraceJSONL(to: dir.appendingPathComponent("trace.jsonl"), range: clampedRange, hz: hz)
        let tiles = pickTiles(in: clampedRange)
        try writeContactPNG(to: dir.appendingPathComponent("contact.png"), tiles: tiles)

        let summary = buildSummaryMarkdown(
            range: clampedRange,
            note: note,
            motion: motion,
            hz: hz,
            tiles: tiles
        )
        try Data(summary.utf8).write(to: dir.appendingPathComponent("summary.md"))
        return RewindBundle(dir: dir, summary: summary, frames: clampedRange)
    }

    private func frameIntervalSeconds() -> Double {
        guard len > 1 else { return 1.0 / 60.0 }
        let intervals = (1..<len).map { absoluteTime($0) - absoluteTime($0 - 1) }.filter { $0 > 0 }.sorted()
        return intervals.isEmpty ? 1.0 / 60.0 : intervals[intervals.count / 2]
    }

    private func jsonEscape(_ s: String) throws -> String {
        String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
    }

    private func writeTraceJSONL(to url: URL, range: Range<Int>, hz: Double) throws -> BundleMotionSummary {
        try Data().write(to: url)
        let handle = try FileHandle(forWritingTo: url)
        func number<T: BinaryFloatingPoint>(_ value: T) -> String {
            Int(exactly: value).map(String.init) ?? String(describing: value)
        }
        let header = "{\"type\":\"header\",\"launch\":\"rune-rewind\",\"width\":\(number(viewport.x)),\"height\":\(number(viewport.y)),\"hz\":\(number(hz)),\"scale\":1,\"platform\":\"rune\",\"units\":\"pt\",\"clock\":\"wall\"}\n"
        var output = Data(header.utf8)
        var summary = BundleMotionSummary()
        var described = [Bool](repeating: false, count: names.count)
        let startTime = time(range.lowerBound)
        do {
            try forEachFrameChanges(in: range) { k, changes in
                summary.record(changes, frame: k, time: time(k))
                var metas: [String] = []
                var elems: [String] = []
                var gone: [String] = []

                func emit(_ id: UInt32, rect: MotionRect, opacity: Float) throws {
                    let index = Int(id)
                    let traceID = index + 1
                    if !described[index] {
                        let label = try jsonEscape(name(id))
                        metas.append("{\"id\":\(traceID),\"cls\":\"rune\",\"nm\":\(label),\"host\":\"rune\"}")
                        described[index] = true
                    }
                    elems.append("[\(traceID),\(fmtNum(rect.x)),\(fmtNum(rect.y)),\(fmtNum(rect.width)),\(fmtNum(rect.height)),\(fmtNum(opacity)),0,0]")
                }

                if k == range.lowerBound {
                    // The first row is independently replayable even when the selection starts mid-clip.
                    for (id, shot) in frame(k) {
                        try emit(id, rect: shot.rect, opacity: shot.opacity)
                    }
                } else {
                    for change in changes.sorted(by: { $0.id < $1.id }) {
                        if let rect = change.toRect, let opacity = change.toOpacity {
                            try emit(change.id, rect: rect, opacity: opacity)
                        } else {
                            gone.append(String(Int(change.id) + 1))
                        }
                    }
                }

                var line = String(format: "{\"t\":%.3f,\"n\":1", (time(k) - startTime) * 1000)
                if !metas.isEmpty { line += ",\"m\":[\(metas.joined(separator: ","))]" }
                if !elems.isEmpty { line += ",\"e\":[\(elems.joined(separator: ","))]" }
                if !gone.isEmpty { line += ",\"g\":[\(gone.joined(separator: ","))]" }
                line += "}\n"
                output.append(contentsOf: line.utf8)
                if output.count >= 64 * 1024 {
                    try handle.write(contentsOf: output)
                    output.removeAll(keepingCapacity: true)
                }
            }
            if !output.isEmpty { try handle.write(contentsOf: output) }
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
        return summary
    }

    private func fmtNum(_ v: Float) -> String {
        if abs(v - v.rounded()) < 1e-4, let n = Int(exactly: v.rounded()) {
            return String(n)
        }
        var s = String(format: "%.3f", v)
        while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) {
            let last = s.removeLast()
            if last == "." { break }
        }
        return s
    }

    private func pickTiles(in range: Range<Int>) -> [Int] {
        var picked = Array(range.filter { hasJump($0) }.prefix(BundleContactConfig.maxTiles))
        var rest = range.filter { !hasJump($0) && activity($0) > 0 }
        rest.sort { activity($0) > activity($1) }
        let rem = max(0, BundleContactConfig.maxTiles - picked.count)
        picked.append(contentsOf: rest.prefix(rem))
        if picked.isEmpty {
            picked.append(max(0, range.upperBound - 1))
        }
        picked.sort()
        return picked
    }

    private func writeContactPNG(to url: URL, tiles: [Int]) throws {
        let vw = max(viewport.x, 1.0)
        let vh = max(viewport.y, 1.0)
        let scale = Float(BundleContactConfig.tileW) / vw
        let tileH = max(1, Int((vh * scale).rounded()))
        let cols = max(1, min(BundleContactConfig.cols, tiles.count))
        let rows = max(1, (tiles.count + cols - 1) / cols)
        let gap = 8
        let width = cols * (BundleContactConfig.tileW + gap) + gap
        let height = rows * (tileH + gap) + gap

        var px = [UInt8](repeating: 0, count: width * height * 4)
        for i in Swift.stride(from: 0, to: px.count, by: 4) {
            px[i] = 10
            px[i + 1] = 10
            px[i + 2] = 12
            px[i + 3] = 255
        }

        func fillRect(x: Int, y: Int, w: Int, h: Int, rgb: (UInt8, UInt8, UInt8)) {
            let x0 = max(0, x)
            let y0 = max(0, y)
            let x1 = min(width, x + w)
            let y1 = min(height, y + h)
            guard x0 < x1, y0 < y1 else { return }
            for py in y0..<y1 {
                for pxIdx in x0..<x1 {
                    let off = (py * width + pxIdx) * 4
                    px[off] = rgb.0
                    px[off + 1] = rgb.1
                    px[off + 2] = rgb.2
                    px[off + 3] = 255
                }
            }
        }

        func outlineRect(_ rect: MotionRect, clip: (Int, Int, Int, Int), rgb: (UInt8, UInt8, UInt8)) {
            let left = Float(clip.0)
            let top = Float(clip.1)
            let right = Float(clip.0 + clip.2)
            let bottom = Float(clip.1 + clip.3)
            let x0 = max(left, rect.left)
            let y0 = max(top, rect.top)
            let x1 = min(right - 1, rect.right)
            let y1 = min(bottom - 1, rect.bottom)
            guard x1 >= x0, y1 >= y0 else { return }
            let ax = Int(x0.rounded()), ay = Int(y0.rounded())
            let bx = Int(x1.rounded()), by = Int(y1.rounded())
            if rect.top >= top { fillRect(x: ax, y: ay, w: bx - ax + 1, h: 1, rgb: rgb) }
            if rect.bottom <= bottom { fillRect(x: ax, y: by, w: bx - ax + 1, h: 1, rgb: rgb) }
            if rect.left >= left { fillRect(x: ax, y: ay, w: 1, h: by - ay + 1, rgb: rgb) }
            if rect.right <= right { fillRect(x: bx, y: ay, w: 1, h: by - ay + 1, rgb: rgb) }
        }

        for (n, k) in tiles.enumerated() {
            let ox = (n % cols) * (BundleContactConfig.tileW + gap) + gap
            let oy = (n / cols) * (tileH + gap) + gap
            fillRect(x: ox, y: oy, w: BundleContactConfig.tileW, h: tileH, rgb: (24, 24, 28))
            let clip = (ox, oy, BundleContactConfig.tileW, tileH)
            let scaleRect: (MotionRect) -> MotionRect = { r in
                MotionRect.fromXYWH(
                    Float(ox) + r.left * scale,
                    Float(oy) + r.top * scale,
                    r.width * scale,
                    r.height * scale
                )
            }
            for (_, s) in frame(k) {
                let grey = UInt8(40.0 + 80.0 * s.opacity.clamped(to: 0...1))
                outlineRect(scaleRect(s.rect), clip: clip, rgb: (grey, grey, min(255, grey + 6)))
            }
            for c in changes(atFrame: k).reversed() {
                guard let nowR = c.toRect ?? c.fromRect else { continue }
                let color: (UInt8, UInt8, UInt8) = c.jump ? (255, 84, 84) : (255, 204, 64)
                if let beforeR = c.fromRect, c.toRect != nil {
                    outlineRect(scaleRect(beforeR), clip: clip, rgb: (110, 90, 40))
                }
                outlineRect(scaleRect(nowR), clip: clip, rgb: color)
            }
        }

        let pngData = ClipboardImage.encodeRGBAAsPNG(
            width: width,
            height: height,
            rgba: Data(px)
        )
        guard let pngData else {
            throw CocoaError(.fileWriteUnknown)
        }
        try pngData.write(to: url)
    }

    private func buildSummaryMarkdown(
        range: Range<Int>,
        note: String,
        motion: BundleMotionSummary,
        hz: Double,
        tiles: [Int]
    ) -> String {
        var s = "# Rewind clip\n\n"
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty {
            let quoted = trimmedNote.replacingOccurrences(of: "\n", with: "\n> ")
            s += "> \(quoted)\n\n"
        }
        let startIdx = range.lowerBound
        let endIdx = max(startIdx, range.upperBound - 1)
        s += String(
            format: "Frames %d–%d of %d (%.2f s to %.2f s before the freeze, %d frames at %.0f Hz), window %@×%@ pt.\n\n",
            startIdx, endIdx, len, time(startIdx), time(endIdx), range.count, hz,
            fmtNum(viewport.x), fmtNum(viewport.y)
        )

        if !motion.jumps.isEmpty {
            s += "## Jumps\n\nMoved much further in one frame than in the frames either side.\n\n"
            s += motion.jumps.joined(separator: "\n") + "\n\n"
        }

        let movedMost = motion.peaks
            .sorted { lhs, rhs in
                if lhs.value.maxDistance != rhs.value.maxDistance {
                    return lhs.value.maxDistance > rhs.value.maxDistance
                }
                return lhs.key < rhs.key
            }
            .prefix(12)
        if !movedMost.isEmpty {
            s += "## Moved most\n\n"
            for (_, peak) in movedMost {
                s += "- \(peak.bestLabel) at frame \(peak.bestFrame) (changed in \(peak.framesCount) frames)\n"
            }
            s += "\n"
        }

        let tileList = tiles.map(String.init).joined(separator: ", ")
        s += "## Files\n\n"
        s += "- `trace.jsonl`: every element's rect and opacity per frame, motion-lint's format (`motion-lint analyze trace.jsonl`).\n"
        s += "- `contact.png`: frames \(tileList) drawn from the recorded rects, left to right. Grey: on screen. Yellow: changed in that frame, its old place dimmer. Red: jumped.\n"
        return s
    }
}

// MARK: - Rewind Scrubber Interactions & UI (`rune::rewind::Scrub`)

private enum ScrubMetrics {
    static let barH: Float = 92.0
    static let trackH: Float = 34.0
    static let pad: Float = 12.0
    static let pathSpan: Int = 90
    static let hintMinW: Float = 760.0
    static let barPitch: Float = 3.0
    static let trackFull: Float = 40.0

    static var movedColor: Color { Color.oklch(0.86, 0.15, 85.0) }
    static var jumpColor: Color { Color.oklch(0.68, 0.2, 25.0) }
}

extension RewindScrubber {
    /// Selected frame range (`[anchor..playhead]` inclusive, or `[frame..frame+1)`).
    public var selection: Range<Int> {
        let lo = min(selectionStartFrame, selectionEndFrame)
        let hi = max(selectionStartFrame, selectionEndFrame)
        return lo..<(hi + 1)
    }

    public func pick(_ id: UInt32?) {
        pickedId = id
    }

    public var note: String { noteEdit.text }

    public func setNote(_ value: String) {
        noteEdit = TextEdit("")
        noteEdit.insert(value)
    }

    public func sent() -> RewindSent? {
        guard let clip else { return nil }
        return RewindSent(clip: clip, frames: selection, note: noteEdit.text)
    }

    /// Handles navigation keys (`←`/`→`, `⇧` select, `⌥` next active, `Home`/`End`, `Return`, `Escape`).
    public func key(_ ev: KeyEvent) -> RewindKeyed {
        guard let clip else { return .ignored }
        let extend = ev.mods.shift
        let stepDir: (Int) -> Int? = { dir in
            if ev.mods.alt {
                return clip.nextActive(from: self.currentFrameIndex, step: dir)
            }
            let next = self.currentFrameIndex + dir
            return (next >= 0 && next < clip.len) ? next : nil
        }

        switch ev.key {
        case .arrowLeft:
            if let k = stepDir(-1) { seek(k, extend: extend) }
            return .handled
        case .arrowRight:
            if let k = stepDir(1) { seek(k, extend: extend) }
            return .handled
        case .home:
            seek(0, extend: extend)
            return .handled
        case .end:
            seek(max(0, clip.len - 1), extend: extend)
            return .handled
        case .escape:
            close()
            return .closed
        case .enter:
            if let s = sent() { return .send(s) }
            return .handled
        default:
            return .ignored
        }
    }

    /// Overlays the frozen clip outlines, track bins, note field, and Send button (`Scrub::view`).
    public func view<State>(
        _ keyPath: WritableKeyPath<State, RewindScrubber>,
        onSend: @escaping (inout State, RewindSent, inout Tx) -> Void
    ) -> El<State> {
        guard let clip else { return el() }
        let vw = clip.viewport.x
        let vh = clip.viewport.y
        let rect = MemoScope.readLayout("rewind") ?? [0, 0, vw, vh]
        let ox = rect.count >= 4 ? (rect[0] * 2.0).rounded() / 2.0 : 0.0
        let oy = rect.count >= 4 ? (rect[1] * 2.0).rounded() / 2.0 : 0.0
        let w = rect.count >= 4 ? (rect[2] * 2.0).rounded() / 2.0 : vw

        let k = min(max(0, currentFrameIndex), max(0, clip.len - 1))
        let changes = clip.changes(atFrame: k)
        let changedIds = Set(changes.map(\.id))

        let dim: El<State> = el()
            .key("rewind-dim")
            .pin(top: 0, right: 0, bottom: 0, left: 0)
            .bg(Color.black.alpha(0.55))
            .onClick { state in
                state[keyPath: keyPath].pickedId = nil
            }

        var markChildren: [El<State>] = []
        let shown = clip.frame(k)
        for (id, shot) in shown where !changedIds.contains(id) {
            let r = shot.rect
            markChildren.append(
                el()
                    .key("rewind-el-\(id)")
                    .absolute(x: r.left, y: r.top)
                    .size(max(1.0, r.width), max(1.0, r.height))
                    .border(0.5, Color.white.alpha(0.08 + 0.14 * shot.opacity.clamped(to: 0...1)))
            )
        }

        if let pid = pickedId {
            markChildren.append(contentsOf: pathElements(clip: clip, frame: k, id: pid))
        }

        for c in changes.reversed() {
            guard let nowR = c.toRect ?? c.fromRect else { continue }
            let col = c.jump ? ScrubMetrics.jumpColor : ScrubMetrics.movedColor
            let id = c.id
            if let beforeR = c.fromRect, c.toRect != nil {
                markChildren.append(
                    el()
                        .key("rewind-was-\(id)")
                        .absolute(x: beforeR.left, y: beforeR.top)
                        .size(max(1.0, beforeR.width), max(1.0, beforeR.height))
                        .border(1.0, col.alpha(0.35))
                )
            }
            markChildren.append(
                el()
                    .key("rewind-box-\(id)")
                    .absolute(x: nowR.left, y: nowR.top)
                    .size(max(1.0, nowR.width), max(1.0, nowR.height))
                    .border(c.toRect != nil ? 1.5 : 1.0, col.alpha(c.toRect != nil ? 1.0 : 0.5))
                    .role(.button)
                    .label("Show \(c.key)'s path")
                    .onClick { state in
                        let cur = state[keyPath: keyPath].pickedId
                        state[keyPath: keyPath].pickedId = (cur == id) ? nil : id
                    }
            )
            let labelY = nowR.top >= 20.0 ? nowR.top - 19.0 : nowR.bottom + 2.0
            let pillLabel: El<State> = text(c.label()).font(Tok.Typography.label).color(.black)
            let labelRow: El<State> = row()
                .key("rewind-label-\(id)")
                .absolute(x: nowR.left, y: labelY)
                .h(17.0)
                .px(5.0)
                .centerY()
                .rounded(3.0)
                .bg(col)
                .child(pillLabel)
            markChildren.append(labelRow)
        }

        if let pid = pickedId, !changedIds.contains(pid),
           let match = shown.first(where: { $0.id == pid }) {
            let r = match.snapshot.rect
            markChildren.append(
                el()
                    .key("rewind-picked")
                    .absolute(x: r.left, y: r.top)
                    .size(max(1.0, r.width), max(1.0, r.height))
                    .border(1.0, Color.white.alpha(0.7))
            )
        }

        let marks: El<State> = el()
            .key("rewind-marks")
            .absolute(x: -ox, y: -oy)
            .size(vw, vh)
            .animateLayout(.none)
            .animate(.none)
            .children(markChildren)

        let bar = buildBar(
            clip: clip,
            frame: k,
            width: w,
            changes: changes,
            keyPath: keyPath,
            onSend: onSend
        )

        return el()
            .key("rewind")
            .pin(top: 0, right: 0, bottom: 0, left: 0)
            .child(dim)
            .child(marks)
            .child(bar)
    }

    private func pathElements<State>(clip: RewindClip, frame k: Int, id: UInt32) -> [El<State>] {
        let sel = selection
        let range: Range<Int> = sel.count > 1
            ? sel
            : max(0, k - ScrubMetrics.pathSpan)..<min(clip.len, k + ScrubMetrics.pathSpan + 1)
        let path = clip.path(id: id, range: range)
        var lastRect: MotionRect? = nil
        var out: [El<State>] = []
        for (idx, snap) in path {
            let moved = lastRect.map { $0 != snap.rect } ?? true
            lastRect = snap.rect
            if !moved && idx != k { continue }
            let cx = snap.rect.left + snap.rect.width * 0.5
            let cy = snap.rect.top + snap.rect.height * 0.5
            let r: Float = idx == k ? 3.5 : 1.5
            let col = clip.hasJump(idx)
                ? ScrubMetrics.jumpColor
                : Color.white.alpha(idx == k ? 1.0 : 0.55)
            out.append(
                el()
                    .key("rewind-path-\(idx)")
                    .absolute(x: cx - r, y: cy - r)
                    .size(r * 2.0, r * 2.0)
                    .rounded(r)
                    .bg(col)
            )
        }
        return out
    }

    private func buildBar<State>(
        clip: RewindClip,
        frame k: Int,
        width w: Float,
        changes: [RewindChange],
        keyPath: WritableKeyPath<State, RewindScrubber>,
        onSend: @escaping (inout State, RewindSent, inout Tx) -> Void
    ) -> El<State> {
        let theme = Tok.theme(dark: true)
        let sel = selection
        let moved = changes.filter { $0.fromRect != nil && $0.toRect != nil }.count
        var facts = [
            String(format: "%+.2f s", clip.time(k)),
            "frame \(k + 1) of \(max(1, clip.len))"
        ]
        if moved > 0 { facts.append("\(moved) moved") }
        if sel.count > 1 { facts.append("\(sel.count) frames selected") }

        let trackW = max(1.0, w - ScrubMetrics.pad * 2.0)
        let len = max(1, clip.len)
        let bins = min(len, max(1, Int(trackW / ScrubMetrics.barPitch)))
        let pitch = trackW / Float(bins)
        let xOf: (Int) -> Float = { Float($0) / Float(len) * trackW }

        var trackChildren: [El<State>] = []
        if sel.count > 1 {
            let sx = xOf(sel.lowerBound)
            let sw = max(1.0, xOf(sel.upperBound) - sx)
            trackChildren.append(
                el()
                    .key("rewind-selection")
                    .absolute(x: sx, y: 0)
                    .size(sw, ScrubMetrics.trackH)
                    .bg(Color.white.alpha(0.1))
            )
        }
        for b in 0..<bins {
            let bStart = b * len / bins
            let bEnd = max(bStart + 1, (b + 1) * len / bins)
            let frameRange = bStart..<min(len, bEnd)
            let most = frameRange.map { clip.activity($0) }.max() ?? 0
            if most <= 0 { continue }
            let anyJump = frameRange.contains { clip.hasJump($0) }
            let level = (logf(1.0 + most) / logf(1.0 + ScrubMetrics.trackFull)).clamped(to: 0.08...1.0)
            let bh = 3.0 + (ScrubMetrics.trackH - 6.0) * level
            let col = anyJump ? ScrubMetrics.jumpColor : ScrubMetrics.movedColor.alpha(0.35 + 0.65 * level)
            trackChildren.append(
                el()
                    .key("rewind-bin-\(b)")
                    .absolute(x: Float(b) * pitch, y: ScrubMetrics.trackH - 3.0 - bh)
                    .size(max(1.0, pitch - 1.0), bh)
                    .rounded(1.0)
                    .bg(col)
            )
        }
        let phX = (xOf(k) + xOf(k + 1)) * 0.5 - 1.0
        trackChildren.append(
            el()
                .key("rewind-playhead")
                .absolute(x: phX, y: 0)
                .size(2.0, ScrubMetrics.trackH)
                .bg(.white)
        )

        let trackEl: El<State> = el()
            .key("rewind-track")
            .size(trackW, ScrubMetrics.trackH)
            .rounded(4.0)
            .bg(Color.white.alpha(0.04))
            .role(.slider)
            .label("Frame")
            .onDrag { state, drag, _ in
                let scrub = state[keyPath: keyPath]
                guard let c = scrub.clip, !c.isEmpty else { return }
                let frac = (drag.local.x / max(1.0, drag.size.x)).clamped(to: 0...1)
                let targetFrame = min(c.len - 1, Int(frac * Float(c.len)))
                scrub.seek(targetFrame, extend: drag.mods.shift)
            }
            .children(trackChildren)

        let sendLabel: El<State> = text("Send").font(Tok.Typography.label).color(theme.text)
        let sendBtn: El<State> = row()
            .key("rewind-send")
            .h(24.0)
            .px(10.0)
            .centerY()
            .rounded(Tok.Radius.sm)
            .bg(theme.card)
            .border(0.5, theme.cardBorder)
            .hover(theme.hover)
            .press(theme.press)
            .role(.button)
            .label("Send these frames")
            .child(sendLabel)
            .onClick { state, tx in
                if let s = state[keyPath: keyPath].sent() {
                    onSend(&state, s, &tx)
                }
            }

        let notePath = keyPath.appending(path: \RewindScrubber.noteEdit)
        let noteInput: El<State> = textInput(key: "rewind-note", notePath)
            .font(Tok.Typography.body)
            .grow(1.0)
            .placeholder("What's wrong here?", color: theme.textSecondary)
            .onSubmit { state, _, tx in
                if let s = state[keyPath: keyPath].sent() {
                    onSend(&state, s, &tx)
                }
            }

        let factsText: El<State> = text(facts.joined(separator: "  ·  "))
            .font(Tok.Typography.monoCaption)
            .color(theme.textSecondary)
        var controls: El<State> = row()
            .wFull()
            .h(24.0)
            .gap(12.0)
            .centerY()
            .child(factsText)
            .child(noteInput)
        if w >= ScrubMetrics.hintMinW {
            let hintText: El<State> = text("←→ step  ⇧ select  ⌥ next move  esc resume")
                .font(Tok.Typography.label)
                .color(theme.textSecondary)
            controls = controls.child(hintText)
        }
        controls = controls.child(sendBtn)

        let sp: El<State> = spacer()
        return col()
            .key("rewind-bar")
            .pin(right: 0, bottom: 0, left: 0)
            .h(ScrubMetrics.barH)
            .px(ScrubMetrics.pad)
            .pt(8.0)
            .gap(8.0)
            .bg(theme.bg.alpha(0.96))
            .border(0.5, theme.separator)
            .child(trackEl)
            .child(controls)
            .child(sp)
    }
}

// MARK: - Tx & Runtime Rewind Helpers

extension Tx {
    /// Attaches or detaches a `RewindRecorder` on the runtime (`Tx::record_rewind`).
    public mutating func recordRewind(_ recorder: RewindRecorder?) {
        if let recorder {
            runtimeActions["rewindRecorder"] = recorder
            runtimeActions.removeValue(forKey: "detachRewind")
        } else {
            runtimeActions.removeValue(forKey: "rewindRecorder")
            runtimeActions["detachRewind"] = true
        }
    }
}

extension Runtime {
    /// Returns the attached `RewindRecorder`, if any (`Runtime::rewind`).
    public func rewind() -> RewindRecorder? {
        rewindRecorder
    }

    /// Manually samples a rewind frame if a recorder is attached (`Runtime::record_rewind`).
    public func recordRewind() {
        guard rewindRecorder != nil else { return }
        captureRewindFrame(at: currentTime)
    }
}
