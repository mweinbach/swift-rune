#if canImport(CoreText) && canImport(CoreGraphics)
import Foundation

/// Zeno's nonzero-winding A8 scan conversion for a glyph already flattened to lines.
/// The fixed-point reciprocals match the Rust renderer, including its rounding at cell edges.
///
/// Adapted from Zeno. Copyright (c) 2020 Chad Brokaw.
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy of this software
/// and associated documentation files (the "Software"), to deal in the Software without restriction,
/// including without limitation the rights to use, copy, modify, merge, publish, distribute,
/// sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions: The above copyright notice and this
/// permission notice shall be included in all copies or substantial portions of the Software.
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
/// BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
/// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
/// DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
enum AppleClassicCoverage {
    static func mask(_ contours: [[SIMD2<Double>]], shiftY: Float, maximumSide: Int) -> AppleClassicGlyph.Bitmap? {
        var xmin = Float.infinity, ymin = Float.infinity, xmax = -Float.infinity, ymax = -Float.infinity
        func point(_ p: SIMD2<Double>) -> SIMD2<Float> { SIMD2(Float(p.x), Float(p.y - Double(shiftY))) }
        for contour in contours {
            for p in contour {
                let v = point(p)
                guard v.x.isFinite, v.y.isFinite else { return nil }
                xmin = min(xmin, v.x)
                ymin = min(ymin, v.y)
                xmax = max(xmax, v.x)
                ymax = max(ymax, v.y)
            }
        }
        let left = floor(xmin), bottom = floor(ymin), top = ceil(ymax)
        let width = ceil(xmax) - left, height = top - bottom
        guard width > 0 && height > 0 else {
            return .init(bytes: [], width: 0, height: 0, bearing: .zero)
        }
        guard width <= Float(maximumSide), height <= Float(maximumSide) else { return nil }
        var scan = Scan(width: Int(width), height: Int(height))
        func fixed(_ p: SIMD2<Double>) -> SIMD2<Int> {
            let v = (point(p) - SIMD2(left, bottom)) * 256
            return SIMD2(Int(v.x), Int(v.y))
        }
        for contour in contours {
            guard let first = contour.first else { continue }
            var prev = fixed(first)
            for p in contour.dropFirst() {
                let next = fixed(p)
                scan.line(from: prev, to: next)
                prev = next
            }
            scan.line(from: prev, to: fixed(first))
        }
        return .init(bytes: scan.coverage(), width: scan.width, height: scan.height, bearing: SIMD2(left, -top))
    }

    private struct Cell {
        var cover = 0, area = 0
    }

    private struct Scan {
        let width: Int, height: Int
        private var cells: [Cell]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            cells = Array(repeating: Cell(), count: width * height)
        }

        private mutating func add(x: Int, y: Int, dy: Int, sumX: Int) {
            guard x >= 0 && x < width && y >= 0 && y < height else { return }
            let i = y * width + x
            cells[i].cover += dy
            cells[i].area += dy * sumX
        }

        mutating func line(from: SIMD2<Int>, to: SIMD2<Int>) {
            let dx = to.x - from.x, dy = to.y - from.y
            guard dy != 0 else { return }
            var x = from.x >> 8, y = from.y >> 8, fx = from.x & 255, fy = from.y & 255
            let endX = to.x >> 8, endY = to.y >> 8
            let dxInv = x == endX ? 0 : 0x00ffffff / dx
            let dyInv = y == endY ? 0 : 0x00ffffff / dy
            var cross = dx * fy - dy * fx
            while x != endX || y != endY {
                if dx == 0 {
                    let nextY = dy > 0 ? 256 : 0
                    add(x: x, y: y, dy: nextY - fy, sumX: fx * 2)
                    fy = 256 - nextY
                    y += dy > 0 ? 1 : -1
                } else if cross <= 0 && cross - dx * 256 > 0 {
                    let nextY = (-cross * -dxInv) >> 24
                    cross -= dy * 256
                    add(x: x, y: y, dy: nextY - fy, sumX: fx)
                    fx = 256; fy = nextY; x -= 1
                } else if cross - dx * 256 <= 0 && cross - dx * 256 + dy * 256 > 0 {
                    cross -= dx * 256
                    let nextX = (-cross * dyInv) >> 24
                    add(x: x, y: y, dy: 256 - fy, sumX: fx + nextX)
                    fx = nextX; fy = 0; y += 1
                } else if cross - dx * 256 + dy * 256 <= 0 && cross + dy * 256 >= 0 {
                    cross += dy * 256
                    let nextY = (cross * dxInv) >> 24
                    add(x: x, y: y, dy: nextY - fy, sumX: fx + 256)
                    fx = 0; fy = nextY; x += 1
                } else {
                    let nextX = (cross * -dyInv) >> 24
                    cross += dx * 256
                    add(x: x, y: y, dy: -fy, sumX: fx + nextX)
                    fx = nextX; fy = 256; y -= 1
                }
            }
            add(x: x, y: y, dy: (to.y & 255) - fy, sumX: fx + (to.x & 255))
        }

        func coverage() -> [UInt8] {
            var bitmap = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                var cover = 0
                for x in 0..<width {
                    let cell = cells[y * width + x]
                    cover += cell.cover * 512
                    let v = (cover - cell.area) >> 9
                    bitmap[(height - y - 1) * width + x] = UInt8(min(255, v < 0 ? ~v : v))
                }
            }
            return bitmap
        }
    }
}
#endif
