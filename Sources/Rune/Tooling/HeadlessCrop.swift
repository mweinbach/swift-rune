import RuneRef

extension HeadlessRunner {
    /// Resolve keys while the captured frame's layout is current (tooling/crop.rs).
    static func snapshotCrop<State>(_ frame: Frame, runtime: Runtime<State>, args: ToolingArgs) throws -> Frame {
        let searchStage = args.hasPlayground && !args.wholeWindow
        let key = args.cropKey
        if args.snapPath == nil, !args.cropRects.isEmpty {
            // The in-memory result can include strip crops. An out-only run writes whole
            // frames, so a rectangle outside the frame cannot fail that capture.
            return (try? tileCrops(frame, cropRectsPt: args.cropRects, scale: args.pixelScale)) ?? frame
        }
        guard key != nil || searchStage else { return frame }

        let all = runtime.elements()
        let stage = searchStage
            ? all.first { !$0.exiting && Runtime<State>.isPlaygroundStageKey($0.key) }
            : nil
        guard let key else {
            guard let stage else { return frame }
            return clippedFrame(frame, rectPt: stage.rect, scale: args.pixelScale) ?? frame
        }

        let element: ElementInfo
        if stage != nil {
            guard let i = Runtime<State>.stageElementIndex(in: all, key: key) else {
                throw ToolingError.invalidArgument("--crop \(key): no element on the playground's stage has that key or path; --whole-window searches the whole window")
            }
            element = all[i]
        } else {
            guard let match = all.first(where: { !$0.exiting && ($0.key == key || $0.path == key) }) else {
                throw ToolingError.invalidArgument("--crop \(key): no element has that key or path")
            }
            element = match
        }
        guard let cropped = clippedFrame(frame, rectPt: element.rect, scale: args.pixelScale) else {
            throw ToolingError.invalidArgument("--crop \(key): the element is empty or outside the frame")
        }
        return cropped
    }

    /// Round outward in the scene's f32 coordinate space and intersect with the readback.
    static func clippedFrame(_ frame: Frame, rectPt: [Float], scale: Float) -> Frame? {
        guard rectPt.count == 4, scale.isFinite, scale > 0 else { return nil }
        func bound(_ pt: Float, to edge: Int, _ rule: FloatingPointRoundingRule) -> Int {
            let px = (pt * scale).rounded(rule)
            if !(px > 0) { return 0 }
            if px >= Float(edge) { return edge }
            return Int(px)
        }
        let x0 = bound(rectPt[0], to: frame.width, .down)
        let y0 = bound(rectPt[1], to: frame.height, .down)
        let x1 = bound(rectPt[0] + rectPt[2], to: frame.width, .up)
        let y1 = bound(rectPt[1] + rectPt[3], to: frame.height, .up)
        guard x0 < x1, y0 < y1 else { return nil }
        if x0 == 0, y0 == 0, x1 == frame.width, y1 == frame.height { return frame }
        let width = x1 - x0
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * (y1 - y0) * 4)
        for y in y0..<y1 {
            let start = (y * frame.width + x0) * 4
            pixels.append(contentsOf: frame.rgba[start..<(start + width * 4)])
        }
        return Frame(width: width, height: y1 - y0, rgba: pixels)
    }
}
