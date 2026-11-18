import Testing
@testable import Rune

@MainActor
@Suite struct PerSideBorderTests {
    @Test func modifiersReplacePriorEdges() {
        let box = El<Int>()
        let edges = box.borderSides(top: .nan, right: -2, bottom: 1.5, left: .infinity, color: .white)
        #expect(edges.borderWidth == 1.5)
        #expect(edges.borderSides == Sides(top: 0, right: 0, bottom: 1.5, left: 0))
        #expect(edges.borderColor == .white)

        let equal = edges.borderSides(top: 2, right: 2, bottom: 2, left: 2, color: .black)
        #expect(equal.borderWidth == 2)
        #expect(equal.borderSides == nil)
        let cleared = equal.borderSides(color: .white)
        #expect(cleared.borderWidth == 0)
        #expect(cleared.borderSides == nil)

        let uniform = edges.border(3, .black)
        #expect(uniform.borderWidth == 3)
        #expect(uniform.borderSides == nil)
        #expect(uniform.borderColor == .black)

        let gradient = edges.borderGradient(width: 2, top: .black, bottom: .white)
        #expect(gradient.borderWidth == 2)
        #expect(gradient.borderSides == nil)
        #expect(gradient.runtimeExtra(RenderExtrasKey.borderGradient) != nil)
        let restored = gradient.borderSides(left: 3, color: .white)
        #expect(restored.borderWidth == 3)
        #expect(restored.borderSides == Sides(top: 0, right: 0, bottom: 0, left: 3))
        #expect(restored.runtimeExtra(RenderExtrasKey.borderGradient) == nil)
    }

    private func browserFrame(_ box: El<Int>) throws -> RenderFrame {
        let app = AppSpec<Int>(title: "Border", size: Vec2(16, 12), state: 0) { _, _ in
            col().wFull().hFull().bg(.black).child(box.size(16, 12))
        }.srgbBlend(true)
        let host = WebAppHost(spec: app, devicePixelRatio: 2)
        return try #require(try WebBrowserSession(host).renderFrame(at: 0))
    }

    private func pixels(_ frame: RenderFrame) throws -> [UInt8] {
        var target = CpuBootTarget(width: frame.width, height: frame.height)
        _ = try CpuPainter(threads: 1).paint(CpuBootScene(frame: frame), into: &target)
        return target.toRGBA8Tight()
    }

    private func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int, width: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }

    @Test func borderOnlyBrowserFramePaintsOneEdge() throws {
        let frame = try browserFrame(el().borderSides(bottom: 1, color: .white))
        try #require(frame.width == 32 && frame.height == 24)
        let rect = try #require(frame.instances.first { $0.params.y == KIND_RECT && $0.uv == SIMD4(0, 0, 2, 0) })
        #expect(rect.params.x == 2)
        #expect(rect.border.w == 1)
        #expect(rect.fill.w == 0)
        let actual = try pixels(frame)
        for y in 0..<frame.height {
            let expected: [UInt8] = y >= 22 ? [255, 255, 255, 255] : [0, 0, 0, 255]
            #expect(pixel(actual, 16, y, width: frame.width) == expected)
        }
        #expect(pixel(actual, 0, 12, width: frame.width) == [0, 0, 0, 255])
        #expect(pixel(actual, 31, 12, width: frame.width) == [0, 0, 0, 255])
    }

    @Test func translucentBorderBlendsOverItsFill() throws {
        let blue = Color(r: 0, g: 0, b: 1, a: 0.5)
        let red = Color(r: 1, g: 0, b: 0, a: 0.5)
        let frame = try browserFrame(el().bg(blue).borderSides(bottom: 1, color: red))
        try #require(frame.width == 32 && frame.height == 24)
        let actual = try pixels(frame)
        let inside = pixel(actual, 16, 10, width: frame.width)
        let edge = pixel(actual, 16, 23, width: frame.width)
        #expect(inside[0] == 0 && inside[1] == 0 && (127...128).contains(inside[2]) && inside[3] == 255)
        #expect((127...128).contains(edge[0]) && edge[1] == 0 && (63...64).contains(edge[2]) && edge[3] == 255)
    }

    @Test func gradientBackgroundPreservesAsymmetricBorder() throws {
        let box = El<Int>().bg(.black).gradient(.black, .white)
        let base = try browserFrame(box)
        let bordered = try browserFrame(box.borderSides(right: 2, bottom: 1, color: Color(r: 1, g: 0, b: 0)))
        try #require(bordered.width == 32 && bordered.height == 24 && base.width == 32 && base.height == 24)
        let plain = try pixels(base)
        let actual = try pixels(bordered)
        #expect(pixel(plain, 12, 4, width: 32) != pixel(plain, 12, 20, width: 32))
        for y in 0..<24 {
            for x in 0..<32 {
                let expected: [UInt8] = x >= 28 || y >= 22 ? [255, 0, 0, 255] : pixel(plain, x, y, width: 32)
                let observed = pixel(actual, x, y, width: 32)
                if observed != expected {
                    Issue.record("Pixel (\(x), \(y)) was \(observed), expected \(expected)")
                    return
                }
            }
        }
    }
}
