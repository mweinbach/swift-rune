import Foundation
import Testing
import RuneMotion
import RuneRef
@testable import Rune

@Suite("Shape Parity Tests (shape.rs + shape_fade.rs)")
struct ShapeParityTests {
    private static func area(_ points: [Vec2], _ tris: [([Int], UInt8)]) -> Float {
        tris.reduce(0) { acc, entry in
            let (idx, _) = entry
            let a = points[idx[0]]
            let b = points[idx[1]]
            let c = points[idx[2]]
            return acc + abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) * 0.5
        }
    }

    private static func strokes(_ s: Shape) -> [[Vec2]] {
        s.ops.compactMap { op in
            if case let .stroke(points, _, _, _, _) = op { return points }
            return nil
        }
    }

    private static func fillAlpha(_ s: Shape) -> Float? {
        for op in s.ops {
            if case let .fill(_, color) = op { return color.a }
        }
        return nil
    }

    @Test("a_concave_polygon_triangulates_to_its_area_with_boundary_edges_marked")
    func concavePolygonTriangulatesToAreaWithBoundaryEdgesMarked() {
        let l: [Vec2] = [
            Vec2(0, 0),
            Vec2(20, 0),
            Vec2(20, 10),
            Vec2(10, 10),
            Vec2(10, 30),
            Vec2(0, 30),
        ]
        let tris = Shape.triangulate(l)
        #expect(tris.count == 4)
        #expect(abs(Self.area(l, tris) - 400.0) < 1e-3)
        let boundaryEdges = tris.reduce(0) { $0 + $1.1.nonzeroBitCount }
        #expect(boundaryEdges == 6)
    }

    @Test("a_waveform_envelope_triangulates_completely")
    func waveformEnvelopeTriangulatesCompletely() {
        let top: [Vec2] = (0..<200).map { i in
            Vec2(Float(i), 20.0 - abs(sinf(Float(i) * 0.2)) * 18.0 - 1.0)
        }
        var env = top
        env.append(contentsOf: top.reversed().map { Vec2($0.x, 40.0 - $0.y) })
        let tris = Shape.triangulate(env)
        #expect(tris.count == env.count - 2)
        var exact2: Float = 0
        for i in 0..<env.count {
            let a = env[i]
            let b = env[(i + 1) % env.count]
            exact2 += a.x * b.y - b.x * a.y
        }
        let exact = abs(exact2) * 0.5
        #expect(abs(Self.area(env, tris) - exact) < exact * 1e-3)
    }

    @Test("curves_flatten_within_tolerance_and_end_on_their_points")
    func curvesFlattenWithinToleranceAndEndOnPoints() {
        let p = Path.new()
            .moveTo([0.0, 0.0])
            .cubicTo([0.0, 50.0], [100.0, 50.0], [100.0, 0.0])
            .close()
        let s = p.subpaths[0]
        #expect(s.closed)
        #expect(s.points.last == Vec2(100.0, 0.0))
        let mid = s.points[s.points.count / 2]
        #expect(abs(mid.y - 37.5) < 1.0)
    }

    @Test("a_drawn_shape_traces_its_strokes_in_order_and_lands_its_head_last")
    func drawnShapeTracesStrokesInOrderAndLandsHeadLast() {
        let s = Shape.new()
            .stroke([[0.0, 0.0], [0.0, 60.0], [40.0, 60.0]], width: 1.0, color: .white)
            .stroke([[40.0, 70.0], [40.0, 90.0]], width: 1.0, color: .white)
            .fill([[36.0, 90.0], [44.0, 90.0], [40.0, 96.0]], color: .white)
        #expect(Self.strokes(s.drawn(0.0)).isEmpty)
        #expect(Self.fillAlpha(s.drawn(0.0)) == nil)
        #expect(Self.strokes(s.drawn(0.5)) == [[Vec2(0, 0), Vec2(0, 60)]])
        #expect(Self.strokes(s.drawn(80.0 / 120.0)) == [[Vec2(0, 0), Vec2(0, 60), Vec2(20, 60)]])
        #expect(Self.fillAlpha(s.drawn(108.0 / 120.0)) == nil)
        let a = Self.fillAlpha(s.drawn(116.0 / 120.0))!
        #expect(abs(a - 0.5) < 1e-4)
        #expect(s.drawn(1.0) == s)
        #expect(s.drawn(.nan) == s)
    }

    @Test("a_closed_stroke_draws_on_round_to_its_start_and_fills_alone_fade")
    func closedStrokeDrawsOnRoundToStartAndFillsAloneFade() {
        let square: [Vec2] = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)]
        let s = Shape.new().strokeWith(square, closed: true, width: 1.0, cap: .round, color: .white)
        #expect(Self.strokes(s.drawn(0.875)) == [[Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10), Vec2(0, 5)]])
        let dot = Shape.new().fill([[0.0, 0.0], [4.0, 0.0], [2.0, 4.0]], color: .white)
        #expect(Self.fillAlpha(dot.drawn(0.25)) == 0.25)
    }

    @Test("a_trimmed_shape_keeps_the_stretch_between_start_and_end")
    func trimmedShapeKeepsStretchBetweenStartAndEnd() {
        let s = Shape.new()
            .stroke([[0.0, 0.0], [0.0, 60.0], [40.0, 60.0]], width: 1.0, color: .white)
            .stroke([[40.0, 70.0], [40.0, 90.0]], width: 1.0, color: .white)
        #expect(Self.strokes(s.trimmed(start: 0.25, end: 0.875)) == [
            [Vec2(0, 30), Vec2(0, 60), Vec2(40, 60)],
            [Vec2(40, 70), Vec2(40, 75)],
        ])
        #expect(Self.strokes(s.trimmed(start: 0.5, end: 0.875)) == [
            [Vec2(0, 60), Vec2(40, 60)],
            [Vec2(40, 70), Vec2(40, 75)],
        ])
        #expect(Self.strokes(s.trimmed(start: 0.6, end: 0.6)).isEmpty)
        #expect(Self.strokes(s.trimmed(start: 0.7, end: 0.2)).isEmpty)
        #expect(s.trimmed(start: 0.0, end: 1.0) == s)
        #expect(s.trimmed(start: .nan, end: .nan) == s)
        #expect(s.trimmed(start: 0.0, end: 0.5) == s.drawn(0.5))
    }

    @Test("a_closed_stroke_trims_across_its_closing_edge")
    func closedStrokeTrimsAcrossClosingEdge() {
        let square: [Vec2] = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)]
        let s = Shape.new().strokeWith(square, closed: true, width: 1.0, cap: .round, color: .white)
        #expect(Self.strokes(s.trimmed(start: 0.625, end: 1.0)) == [
            [Vec2(5, 10), Vec2(0, 10), Vec2(0, 0)]
        ])
    }

    @Test("empty_and_degenerate_ops_are_dropped")
    func emptyAndDegenerateOpsAreDropped() {
        let s = Shape.new()
            .stroke([[0.0, 0.0]], width: 1.0, color: .white)
            .fill([[0.0, 0.0], [1.0, 1.0]], color: .white)
        #expect(s.isEmpty)
    }

    // MARK: - shape_fade.rs + viewBox

    private static func frameScene(shape: Shape, opacity: Float) -> RefScene {
        struct S {}
        let rt = Runtime(
            state: S(),
            viewport: Vec2(40, 40),
            pixelScale: 2.0
        ) { _, _ in
            El<S>(direction: .row)
                .size(40, 40)
                .child(canvas(shape).size(40, 40).opacity(opacity))
        }
        return rt.frame(at: 0)
    }

    private static func isLayered(_ scene: RefScene) -> Bool {
        scene.primitives.contains { $0.kind == .layerBegin }
    }

    private static func cross() -> Shape {
        Shape.new()
            .stroke([[0.0, 20.0], [40.0, 20.0]], width: 8.0, color: .white)
            .stroke([[20.0, 0.0], [20.0, 40.0]], width: 8.0, color: .white)
    }

    private static func corner() -> Shape {
        Shape.new()
            .stroke([[4.0, 20.0], [20.0, 20.0], [20.0, 36.0]], width: 8.0, color: .white)
    }

    @Test("only_a_fading_shape_of_several_pieces_paints_through_a_layer")
    func onlyFadingShapeOfSeveralPiecesPaintsThroughLayer() {
        for shape in [Self.cross(), Self.corner()] {
            #expect(!Self.isLayered(Self.frameScene(shape: shape, opacity: 1.0)))
            #expect(Self.isLayered(Self.frameScene(shape: shape, opacity: 0.5)))
            #expect(!Self.isLayered(Self.frameScene(shape: shape, opacity: 0.0)))
        }
        let line = Shape.new().line([0.0, 20.0], [40.0, 20.0], width: 8.0, cap: .round, color: .white)
        #expect(!Self.isLayered(Self.frameScene(shape: line, opacity: 0.5)))
    }

    @Test("where_faded_pieces_meet_is_no_darker_than_one")
    func whereFadedPiecesMeetIsNoDarkerThanOne() throws {
        let renderer = try MetalRenderer()
        func px(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
            let i = (y * 80 + x) * 4
            return Array(bytes[i..<(i + 4)])
        }
        for (shape, alone) in [(Self.cross(), (8, 40)), (Self.corner(), (16, 40))] {
            var halfScene = Self.frameScene(shape: shape, opacity: 0.5)
            halfScene.clearColor = .zero
            let half = try renderer.renderOffscreen(halfScene).rgba
            let jointHalf = px(half, 40, 40)
            let aloneHalf = px(half, alone.0, alone.1)
            for c in 0..<4 {
                #expect(abs(Int(jointHalf[c]) - Int(aloneHalf[c])) <= 1)
            }
            #expect((UInt8(120)...UInt8(136)).contains(jointHalf[3]))

            var fullScene = Self.frameScene(shape: shape, opacity: 1.0)
            fullScene.clearColor = .zero
            let full = try renderer.renderOffscreen(fullScene).rgba
            let jointFull = px(full, 40, 40)
            let aloneFull = px(full, alone.0, alone.1)
            #expect(jointFull == aloneFull)
        }
    }

    @Test("viewBox stretches coordinates to element size while stroke width stays in points")
    func viewBoxStretchesCoordinatesAndKeepsStrokeWidthInPoints() {
        struct S {}
        let s = Shape.new()
            .line([0.0, 5.0], [10.0, 5.0], width: 2.0, cap: .butt, color: .white)
            .viewBox(10, 10)
        let rt = Runtime(state: S(), viewport: Vec2(200, 40), pixelScale: 2.0) { _, _ in
            canvas(s).size(200, 40)
        }
        let scene = rt.frame(at: 0)
        let seg = scene.primitives.first { $0.kind == .segment }!
        // Endpoint a=(0, 20pt * 2x = 40px), b=(200pt * 2x = 400px, 40px); full stroke width = 2pt * 2x = 4px
        #expect(abs(seg.uv.x - 0.0) < 0.1)
        #expect(abs(seg.uv.y - 40.0) < 0.1)
        #expect(abs(seg.uv.z - 400.0) < 0.1)
        #expect(abs(seg.uv.w - 40.0) < 0.1)
        #expect(abs(seg.params.x - 4.0) < 0.05)
        #expect(seg.params.z == 0.0) // butt cap
    }
}
