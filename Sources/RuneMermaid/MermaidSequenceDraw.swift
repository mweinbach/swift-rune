import Foundation
import Rune

enum SequenceDrawer {
    private static let barWidth: Float = 10.0

    private struct Frame {
        var kind: Measured?
        var label: Measured
        var fill: Color?
        var top: Float
        var dividers: [(Float, Measured)]
        var minX: Float
        var maxX: Float
    }

    static func draw(_ s: SequenceDiagram, paint: MermaidTheme) -> MermaidScene? {
        let font = paint.font
        var small = font
        small.size = font.size - 1.0
        small.lineHeight = font.resolvedLineHeight - 2.0
        var bold = small
        bold.weight = 600.0
        var numFont = font
        numFont.size = 10.0
        numFont.lineHeight = 12.0
        numFont.weight = 600.0

        let n = s.participants.count
        guard n > 0 else { return nil }
        let heads = s.participants.map { measureText($0.label, font: font) }
        let boxes = zip(s.participants, heads).map { headSize($0.kind, $1.size) }
        let boxTitles = s.boxes.map { measureText($0.title, font: bold) }
        let boxLead: Float
        if s.boxes.isEmpty {
            boxLead = 0.0
        } else {
            let th = boxTitles.map(\.size.y).max() ?? 0.0
            boxLead = th > 0.0 ? th + 18.0 : 10.0
        }
        let maxHeadH = boxes.map(\.y).max() ?? 0.0
        let topH = boxLead + maxHeadH

        let texts: [Measured?] = s.events.map { e in
            switch e {
            case let .message(m): measureText(m.text, font: small)
            case let .note(_, t): measureText(t, font: small)
            case let .open(_, t, _), let .elseBranch(t):
                measureText(t.isEmpty ? "" : "[\(t)]", font: small)
            default: nil
            }
        }
        func widthOf(_ i: Int) -> Float { texts[i]?.size.x ?? 0.0 }

        let numberPad: Float = s.autonumber ? 20.0 : 0.0
        var need: [(Int, Int, Float)] = []
        for (i, e) in s.events.enumerated() {
            switch e {
            case let .message(m) where m.from != m.to:
                need.append((min(m.from, m.to), max(m.from, m.to), widthOf(i) + 32.0 + numberPad))
            case let .message(m) where m.from + 1 < n:
                need.append((m.from, m.from + 1, widthOf(i) + 48.0))
            case let .note(.right(a), _) where a + 1 < n:
                need.append((a, a + 1, widthOf(i) + 40.0))
            case let .note(.left(a), _) where a > 0:
                need.append((a - 1, a, widthOf(i) + 40.0))
            default:
                break
            }
        }

        var cx = Array(repeating: boxes[0].x * 0.5 + (s.participants[0].group != nil ? 10.0 : 0.0), count: n)
        for j in 1..<n {
            let boundaryGap: Float = s.participants[j - 1].group != s.participants[j].group ? 20.0 : 0.0
            cx[j] = cx[j - 1] + (boxes[j - 1].x + boxes[j].x) * 0.5 + 24.0 + boundaryGap
            for (a, b, d) in need where b == j {
                cx[j] = max(cx[j], cx[a] + d)
            }
        }

        var groupsBg = Canvas()
        var back = Canvas()
        var lifelines = Canvas()
        var bars = Canvas()
        var front = Canvas()
        var tops = Canvas()
        var tabs = Canvas()

        var active: [[Float]] = Array(repeating: [], count: n)
        var frames: [Frame] = []
        var y = topH + 20.0
        var number: (UInt32, UInt32)? = nil
        var starts = Array(repeating: topH, count: n)
        var ends: [Float?] = Array(repeating: nil, count: n)
        var doomed: [Int] = []

        func edgeX(_ i: Int, right: Bool) -> Float {
            let d = active[i].count
            if d == 0 { return cx[i] }
            return cx[i] + Float(d - 1) * 4.0 + (right ? barWidth * 0.5 : -barWidth * 0.5)
        }
        func closeBar(_ i: Int, at yPos: Float) {
            let d = active[i].count
            guard let top = active[i].popLast() else { return }
            let x = cx[i] + Float(d - 1) * 4.0
            let k = bars.marks.count
            bars.part(.key(.frame, "bar\(k)"))
            bars.shape(CanvasMath.roundedRect(x0: x - barWidth * 0.5, y0: top, x1: x + barWidth * 0.5, y1: max(yPos, top + 8.0), r: 1.0), fill: paint.nodeFill, border: paint.nodeBorder, width: 1.0)
        }
        func touch(_ x0: Float, _ x1: Float) {
            for i in frames.indices {
                frames[i].minX = min(frames[i].minX, x0)
                frames[i].maxX = max(frames[i].maxX, x1)
            }
        }

        for (i, e) in s.events.enumerated() {
            switch e {
            case let .message(m):
                front.part(.key(.edge, "m\(i)"))
                let t = texts[i]!
                if m.activate {
                    active[m.to].append(y + t.size.y + 6.0)
                }
                let lineY: Float
                if m.from == m.to {
                    let x = edgeX(m.from, right: true)
                    front.labelAt(t, at: Vec2(x + 8.0, y), font: small, color: paint.muted, align: .leading)
                    lineY = y + t.size.y + 6.0
                    let pts = [Vec2(x, lineY), Vec2(x + 30.0, lineY), Vec2(x + 30.0, lineY + 18.0), Vec2(x + 2.0 + tipLen(m.tip), lineY + 18.0)]
                    stroke(&front, pts, dotted: m.dotted, paint: paint)
                    drawTip(&front, m.tip, at: Vec2(x, lineY + 18.0), dir: Vec2(-1.0, 0.0), paint: paint)
                    touch(cx[m.from] - barWidth, max(x + 30.0, x + 8.0 + t.size.x))
                    y = lineY + 18.0 + 16.0
                } else {
                    let right = m.to > m.from
                    let sx = edgeX(m.from, right: right)
                    let ex = edgeX(m.to, right: !right)
                    let dir: Float = right ? 1.0 : -1.0
                    let mid = (sx + ex) * 0.5
                    let hasText = !t.text.isEmpty
                    front.label(t, center: Vec2(mid, y + t.size.y * 0.5), font: small, color: paint.muted, align: .center)
                    lineY = y + (hasText ? t.size.y + 6.0 : 4.0)
                    let a = m.both ? sx + dir * tipLen(m.tip) : sx
                    stroke(&front, [Vec2(a, lineY), Vec2(ex - dir * tipLen(m.tip), lineY)], dotted: m.dotted, paint: paint)
                    drawTip(&front, m.tip, at: Vec2(ex, lineY), dir: Vec2(dir, 0.0), paint: paint)
                    if m.both {
                        drawTip(&front, m.tip, at: Vec2(sx, lineY), dir: Vec2(-dir, 0.0), paint: paint)
                    }
                    if let (k, step) = number {
                        let nm = measureText("\(k)", font: numFont)
                        let hw = max(nm.size.x * 0.5 + 4.0, 8.0)
                        front.shape(CanvasMath.roundedRect(x0: sx - hw, y0: lineY - 8.0, x1: sx + hw, y1: lineY + 8.0, r: 8.0), fill: paint.line, border: paint.line, width: 1.0)
                        front.label(nm, center: Vec2(sx, lineY), font: numFont, color: paint.surface, align: .center)
                        number = (k &+ step, step)
                    }
                    let lo = min(cx[m.from], cx[m.to]) - barWidth
                    let hi = max(cx[m.from], cx[m.to]) + barWidth
                    touch(min(lo, mid - t.size.x * 0.5), max(hi, mid + t.size.x * 0.5))
                    y = lineY + 16.0
                }
                if m.deactivate {
                    closeBar(m.from, at: lineY)
                }
                let endY = m.from == m.to ? lineY + 18.0 : lineY
                var remainingDoomed: [Int] = []
                for d in doomed {
                    if d == m.from || d == m.to {
                        ends[d] = endY + 14.0
                        drawCross(&front, at: Vec2(cx[d], endY + 14.0), paint: paint)
                        y = max(y, endY + 30.0)
                    } else {
                        remainingDoomed.append(d)
                    }
                }
                doomed = remainingDoomed
            case let .create(a):
                let sz = boxes[a]
                let top = y
                tops.part(.key(.node, "p\(a)"))
                drawHead(&tops, kind: s.participants[a].kind, label: heads[a], top: Vec2(cx[a], top), size: sz, paint: paint)
                starts[a] = top + sz.y
                touch(cx[a] - sz.x * 0.5, cx[a] + sz.x * 0.5)
                y = top + sz.y + 14.0
            case let .destroy(a):
                doomed.append(a)
            case let .number(on):
                number = on
            case let .note(pos, _):
                let t = texts[i]!
                let w = t.size.x + 20.0
                let x0: Float
                let x1: Float
                switch pos {
                case let .left(a):
                    x0 = cx[a] - 12.0 - w
                    x1 = cx[a] - 12.0
                case let .right(a):
                    x0 = cx[a] + 12.0
                    x1 = cx[a] + 12.0 + w
                case let .over(a, b):
                    let span = max(cx[b] - cx[a] + 40.0, w)
                    let mid = (cx[a] + cx[b]) * 0.5
                    x0 = mid - span * 0.5
                    x1 = mid + span * 0.5
                }
                let h = t.size.y + 14.0
                y += 2.0
                front.part(.key(.node, "note\(i)"))
                front.shape(CanvasMath.roundedRect(x0: x0, y0: y, x1: x1, y1: y + h, r: 2.0), fill: paint.noteFill, border: paint.noteBorder, width: 1.0)
                front.label(t, center: Vec2((x0 + x1) * 0.5, y + h * 0.5), font: small, color: paint.text, align: .center)
                touch(x0, x1)
                y += h + 14.0
            case let .activate(a):
                active[a].append(y - 8.0)
            case let .deactivate(a):
                closeBar(a, at: y - 8.0)
            case let .open(kindName, _, fill):
                let label = texts[i]!
                let kindM = kindName.map { measureText($0, font: bold) }
                let h: Float = kindM.map { max($0.size.y, label.size.y) + 14.0 } ?? (fill != nil ? 8.0 : 0.0)
                frames.append(Frame(kind: kindM, label: label, fill: fill, top: y, dividers: [], minX: Float.greatestFiniteMagnitude, maxX: -Float.greatestFiniteMagnitude))
                y += h
            case .elseBranch:
                let label = texts[i]!
                let h = label.size.y + 14.0
                if !frames.isEmpty {
                    frames[frames.count - 1].dividers.append((y, label))
                }
                y += h
            case .end:
                guard var f = frames.popLast() else { continue }
                if f.minX > f.maxX {
                    f.minX = cx[0]
                    f.maxX = cx[n - 1]
                }
                let x0 = f.minX - 12.0
                let tabW = f.kind.map { $0.size.x + 18.0 } ?? 0.0
                let x1 = max(f.maxX + 12.0, x0 + tabW + f.label.size.x + 20.0)
                let bottom = y - 4.0
                let key = "frame\(back.marks.count)"
                back.part(.key(.frame, key))
                tabs.part(.key(.frame, key))
                if let kind = f.kind {
                    let th = max(kind.size.y, f.label.size.y) + 6.0
                    back.stroke([Vec2(x0, f.top), Vec2(x1, f.top), Vec2(x1, bottom), Vec2(x0, bottom)], closed: true, width: 1.0, color: paint.nodeBorder)
                    let tab = [Vec2(x0, f.top), Vec2(x0 + tabW, f.top), Vec2(x0 + tabW, f.top + th - 6.0), Vec2(x0 + tabW - 6.0, f.top + th), Vec2(x0, f.top + th)]
                    tabs.shape(tab, fill: paint.nodeFill, border: paint.nodeBorder, width: 1.0)
                    tabs.labelAt(kind, at: Vec2(x0 + 9.0, f.top + 3.0), font: bold, color: paint.text, align: .leading)
                    tabs.labelAt(f.label, at: Vec2(x0 + tabW + 8.0, f.top + 3.0), font: small, color: paint.muted, align: .leading)
                    for (dy, dLabel) in f.dividers {
                        back.dashed([Vec2(x0, dy), Vec2(x1, dy)], width: 1.0, color: paint.nodeBorder, on: 4.0, off: 3.0)
                        tabs.labelAt(dLabel, at: Vec2(x0 + 9.0, dy + 4.0), font: small, color: paint.muted, align: .leading)
                    }
                } else if let rectCol = f.fill {
                    let band = adaptFill(base: paint.surface, color: rectCol, darkLift: 0.04, lightDrop: 0.03).alpha(0.55)
                    back.fill(CanvasMath.roundedRect(x0: x0, y0: f.top - 2.0, x1: x1, y1: bottom, r: 4.0), color: band)
                }
                touch(x0, x1)
                y = bottom + 16.0
            }
        }

        let endY = y + 4.0
        for a in 0..<n {
            while !active[a].isEmpty {
                closeBar(a, at: endY - 8.0)
            }
        }

        let boxBorder = groupBorder(paint)
        for (bIdx, b) in s.boxes.enumerated() {
            let members = (0..<n).filter { s.participants[$0].group == bIdx }
            guard let first = members.first, let last = members.last else { continue }
            var x0 = cx[first] - boxes[first].x * 0.5 - 10.0
            var x1 = cx[last] + boxes[last].x * 0.5 + 10.0
            let title = boxTitles[bIdx]
            if x1 - x0 < title.size.x + 20.0 {
                let mid = (x0 + x1) * 0.5
                x0 = mid - title.size.x * 0.5 - 10.0
                x1 = mid + title.size.x * 0.5 + 10.0
            }
            let fill = b.color.map { adaptFill(base: paint.surface, color: $0, darkLift: 0.035, lightDrop: 0.03) } ?? paint.clusterFill
            groupsBg.part(.key(.frame, "box\(bIdx)"))
            groupsBg.shape(CanvasMath.roundedRect(x0: x0, y0: 0.0, x1: x1, y1: endY + maxHeadH + 10.0, r: 6.0), fill: fill, border: boxBorder, width: 1.0)
            groupsBg.label(title, center: Vec2((x0 + x1) * 0.5, 7.0 + title.size.y * 0.5), font: bold, color: paint.muted, align: .center)
        }

        let created: [Bool] = (0..<n).map { i in
            s.events.contains { if case let .create(a) = $0 { return a == i } else { return false } }
        }
        for (i, p) in s.participants.enumerated() {
            let sz = boxes[i]
            let stop = ends[i] ?? endY
            lifelines.part(.key(.frame, "life\(i)"))
            lifelines.stroke([Vec2(cx[i], starts[i]), Vec2(cx[i], stop)], closed: false, width: 1.0, color: paint.nodeBorder)
            if !created[i] {
                tops.part(.key(.node, "p\(i)"))
                drawHead(&tops, kind: p.kind, label: heads[i], top: Vec2(cx[i], topH - sz.y), size: sz, paint: paint)
            }
            if ends[i] == nil {
                tops.part(.key(.node, "p\(i).end"))
                drawHead(&tops, kind: p.kind, label: heads[i], top: Vec2(cx[i], endY), size: sz, paint: paint)
            }
        }

        var c = groupsBg
        for layer in [back, lifelines, bars, tabs, front, tops] {
            c.append(layer)
        }
        return c.finishFit(paint: paint)
    }

    private static func tipLen(_ t: SequenceTip) -> Float {
        t == .filled ? 8.0 : 0.0
    }

    private static func stroke(_ c: inout Canvas, _ pts: [Vec2], dotted: Bool, paint: MermaidTheme) {
        if dotted {
            c.dashed(pts, width: 1.25, color: paint.line, on: 4.0, off: 3.0)
        } else {
            c.stroke(pts, closed: false, width: 1.25, color: paint.line)
        }
    }

    private static func drawTip(_ c: inout Canvas, _ t: SequenceTip, at: Vec2, dir d: Vec2, paint: MermaidTheme) {
        func back(_ by: Float, _ side: Float) -> Vec2 {
            Vec2(at.x - d.x * by - d.y * side, at.y - d.y * by + d.x * side)
        }
        switch t {
        case .none:
            break
        case .filled:
            c.fill(CanvasMath.arrowhead(tip: at, dir: d, len: 9.0, width: 8.0), color: paint.line)
        case .open:
            c.stroke([back(8.0, 4.5), at, back(8.0, -4.5)], closed: false, width: 1.25, color: paint.line)
        case .cross:
            c.stroke([back(9.0, 4.0), back(1.0, -4.0)], closed: false, width: 1.5, color: paint.line)
            c.stroke([back(9.0, -4.0), back(1.0, 4.0)], closed: false, width: 1.5, color: paint.line)
        }
    }

    private static func headSize(_ kind: SequenceParticipant.Kind, _ t: Vec2) -> Vec2 {
        switch kind {
        case .box: Vec2(max(t.x + 24.0, 72.0), t.y + 16.0)
        case .actor: Vec2(max(t.x, 40.0), 40.0 + t.y)
        case .boundary, .control, .entity: Vec2(max(t.x, 44.0), 36.0 + t.y)
        case .database: ShapeRenderer.nodeSize(.cylinder, labelSize: t)
        case .collections: ShapeRenderer.nodeSize(.stackedRect, labelSize: t)
        case .queue: ShapeRenderer.nodeSize(.hCylinder, labelSize: t)
        }
    }

    private static func drawHead(
        _ c: inout Canvas,
        kind: SequenceParticipant.Kind,
        label: Measured,
        top: Vec2,
        size: Vec2,
        paint: MermaidTheme
    ) {
        let x = top.x, y = top.y, w = size.x, h = size.y
        func ring(_ at: Vec2, _ r: Float) {
            c.shape(CanvasMath.ellipse(center: at, rx: r, ry: r), fill: paint.nodeFill, border: paint.line, width: 1.25)
        }
        func under(_ glyph: Float) {
            c.label(label, center: Vec2(x, y + glyph + label.size.y * 0.5), font: paint.font, color: paint.text, align: .center)
        }
        let colors = (paint.nodeFill, paint.nodeBorder, paint.text)
        switch kind {
        case .box:
            c.shape(CanvasMath.roundedRect(x0: x - w * 0.5, y0: y, x1: x + w * 0.5, y1: y + h, r: 4.0), fill: paint.nodeFill, border: paint.nodeBorder, width: 1.0)
            c.label(label, center: Vec2(x, y + h * 0.5), font: paint.font, color: paint.text, align: .center)
        case .actor:
            drawActor(&c, top: top, paint: paint)
            under(40.0)
        case .boundary:
            ring(Vec2(x + 5.0, y + 15.0), 11.0)
            c.stroke([Vec2(x - 14.0, y + 4.0), Vec2(x - 14.0, y + 26.0)], closed: false, width: 1.25, color: paint.line)
            c.stroke([Vec2(x - 14.0, y + 15.0), Vec2(x - 6.0, y + 15.0)], closed: false, width: 1.25, color: paint.line)
            under(36.0)
        case .control:
            ring(Vec2(x, y + 17.0), 12.0)
            c.stroke([Vec2(x + 4.0, y + 1.0), Vec2(x - 1.0, y + 5.0), Vec2(x + 4.0, y + 9.0)], closed: false, width: 1.25, color: paint.line)
            under(36.0)
        case .entity:
            ring(Vec2(x, y + 14.0), 12.0)
            c.stroke([Vec2(x - 12.0, y + 29.0), Vec2(x + 12.0, y + 29.0)], closed: false, width: 1.25, color: paint.line)
            under(36.0)
        case .database:
            ShapeRenderer.draw(into: &c, shape: .cylinder, label: label, center: Vec2(x, y + h * 0.5), size: size, colors: colors, paint: paint)
        case .collections:
            ShapeRenderer.draw(into: &c, shape: .stackedRect, label: label, center: Vec2(x, y + h * 0.5), size: size, colors: colors, paint: paint)
        case .queue:
            ShapeRenderer.draw(into: &c, shape: .hCylinder, label: label, center: Vec2(x, y + h * 0.5), size: size, colors: colors, paint: paint)
        }
    }

    private static func drawCross(_ c: inout Canvas, at: Vec2, paint: MermaidTheme) {
        c.stroke([Vec2(at.x - 7.0, at.y - 7.0), Vec2(at.x + 7.0, at.y + 7.0)], closed: false, width: 2.0, color: paint.line)
        c.stroke([Vec2(at.x - 7.0, at.y + 7.0), Vec2(at.x + 7.0, at.y - 7.0)], closed: false, width: 2.0, color: paint.line)
    }

    private static func drawActor(_ c: inout Canvas, top: Vec2, paint: MermaidTheme) {
        let x = top.x, y = top.y
        c.shape(CanvasMath.ellipse(center: Vec2(x, y + 7.0), rx: 7.0, ry: 7.0), fill: paint.nodeFill, border: paint.line, width: 1.25)
        c.stroke([Vec2(x, y + 14.0), Vec2(x, y + 26.0)], closed: false, width: 1.25, color: paint.line)
        c.stroke([Vec2(x - 10.0, y + 18.0), Vec2(x + 10.0, y + 18.0)], closed: false, width: 1.25, color: paint.line)
        c.stroke([Vec2(x - 8.0, y + 36.0), Vec2(x, y + 26.0), Vec2(x + 8.0, y + 36.0)], closed: false, width: 1.25, color: paint.line)
    }
}
