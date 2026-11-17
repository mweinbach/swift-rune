import Foundation

/// Bounds are in texels with exclusive right and bottom edges.
enum WebAtlasUpdate: Equatable, Sendable {
    case none
    case full
    case patch(SIMD4<Int>)

    /// The caller supplies the resident image only when its width, height and format match.
    /// Known bounds must describe every write since that resident revision.
    static func update(width: Int, height: Int, channels: Int, texels: [UInt8],
                       previous: [UInt8]?, changed: Bool, knownEdges: SIMD4<Int>? = nil) -> Self {
        guard let previous, previous.count == texels.count, width > 0, height > 0,
              channels == 1 || channels == 4 else { return .full }
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: channels)
        let (size, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !sizeOverflow, size == texels.count else { return .full }
        guard changed else { return .none }

        func upload(_ edges: SIMD4<Int>) -> Self {
            let payload = (edges.z - edges.x) * channels * (edges.w - edges.y)
            // A rectangle costs four additional UInt32s on the wire.
            return size - payload <= 16 ? .full : .patch(edges)
        }

        return previous.withUnsafeBufferPointer { old in
            texels.withUnsafeBufferPointer { new in
                guard let oldBase = old.baseAddress, let newBase = new.baseAddress,
                      oldBase != newBase else { return .none }
                if let edges = knownEdges, edges.x >= 0, edges.y >= 0,
                   edges.z <= width, edges.w <= height, edges.x < edges.z, edges.y < edges.w {
                    return upload(edges)
                }

                // Compare entire rows in libc. Only differing rows can extend the dirty edges.
                var leftByte = rowBytes, rightByte = 0, top = height, bottom = 0
                for y in 0..<height {
                    let a = oldBase + y * rowBytes
                    let b = newBase + y * rowBytes
                    guard memcmp(a, b, rowBytes) != 0 else { continue }
                    top = min(top, y)
                    bottom = y + 1
                    var left = 0
                    while left < leftByte && a[left] == b[left] { left += 1 }
                    leftByte = left
                    var right = rowBytes
                    while right > rightByte && a[right - 1] == b[right - 1] { right -= 1 }
                    rightByte = right
                }
                guard top < bottom else { return .none }
                return upload(SIMD4(leftByte / channels, top, (rightByte - 1) / channels + 1, bottom))
            }
        }
    }
}
