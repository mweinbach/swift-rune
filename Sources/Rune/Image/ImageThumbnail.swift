import Foundation

/// Area-weighted thumbnails of a decoded, straight-alpha RGBA canvas.
internal enum ImageThumbnail {
    static func size(width: Int, height: Int, maxDimension: Int?) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard let limit = maxDimension, limit > 0, limit < longest else { return (width, height) }
        return (max(1, (width * limit + longest / 2) / longest),
                max(1, (height * limit + longest / 2) / longest))
    }

    static func resize(_ canvas: Data, width: Int, height: Int, to target: (width: Int, height: Int)) -> Data {
        guard width != target.width || height != target.height else { return canvas }
        var output = Data(count: target.width * target.height * 4)
        output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            canvas.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                for y in 0..<target.height {
                    let top = Double(y * height) / Double(target.height)
                    let bottom = Double((y + 1) * height) / Double(target.height)
                    for x in 0..<target.width {
                        let left = Double(x * width) / Double(target.width)
                        let right = Double((x + 1) * width) / Double(target.width)
                        var color = SIMD3<Double>.zero
                        var alpha = 0.0
                        for sy in Int(top)..<Int(bottom.rounded(.up)) {
                            let dy = min(bottom, Double(sy + 1)) - max(top, Double(sy))
                            for sx in Int(left)..<Int(right.rounded(.up)) {
                                let dx = min(right, Double(sx + 1)) - max(left, Double(sx))
                                let index = (sy * width + sx) * 4
                                let weightedAlpha = dx * dy * Double(src[index + 3])
                                alpha += weightedAlpha
                                for channel in 0..<3 {
                                    color[channel] += weightedAlpha * Double(src[index + channel])
                                }
                            }
                        }
                        let offset = (y * target.width + x) * 4
                        if alpha > 0 {
                            for channel in 0..<3 {
                                dst[offset + channel] = UInt8(clamping: Int((color[channel] / alpha).rounded()))
                            }
                        }
                        let area = (right - left) * (bottom - top)
                        dst[offset + 3] = UInt8(clamping: Int((alpha / area).rounded()))
                    }
                }
            }
        }
        return output
    }
}
