import Foundation

/// Content-addressed placements on one atlas shelf. A hash hit must also match all R8 bytes.
struct BrowserCoverageShelf {
    private var rectangles: [Int: SIMD4<Int>] = [:]

    static func fingerprint(_ pixels: [UInt8], size: SIMD2<Int>) -> Int {
        var hasher = Hasher()
        hasher.combine(size)
        pixels.withUnsafeBytes { hasher.combine(bytes: $0) }
        return hasher.finalize()
    }

    mutating func remember(_ fingerprint: Int, origin: SIMD2<Int>, size: SIMD2<Int>) {
        rectangles[fingerprint] = SIMD4(origin.x, origin.y, size.x, size.y)
    }

    mutating func reset() {
        rectangles.removeAll()
    }

    func origin(_ fingerprint: Int, pixels: [UInt8], size: SIMD2<Int>, page: [UInt8], stride: Int) -> SIMD2<Int>? {
        guard let rect = rectangles[fingerprint], rect.z == size.x, rect.w == size.y else { return nil }
        let origin = SIMD2(rect.x, rect.y)
        let (count, overflow) = size.x.multipliedReportingOverflow(by: size.y)
        guard !overflow, count == pixels.count, size.x > 0, size.y > 0, stride >= size.x,
              origin.x >= 0, origin.y >= 0, origin.x <= stride - size.x,
              size.y <= page.count / stride, origin.y <= page.count / stride - size.y else { return nil }
        let matches = pixels.withUnsafeBytes { tile in
            page.withUnsafeBytes { sheet in
                guard let tileBase = tile.baseAddress, let pageBase = sheet.baseAddress else { return false }
                for row in 0..<size.y {
                    let start = (origin.y + row) * stride + origin.x
                    if memcmp(tileBase + row * size.x, pageBase + start, size.x) != 0 { return false }
                }
                return true
            }
        }
        return matches ? origin : nil
    }
}
