#if canImport(CRuneDesktopImages)
import CRuneDesktopImages
import Foundation

internal enum DesktopImageCodec {
    private final class Frames {
        var values: [AnimatedImageFrame] = []
        var totalBytes = 0

        func append(width: UInt32, height: UInt32, pixels: UnsafePointer<UInt8>,
                    rowBytes: Int, duration: Double) -> Bool {
            let w = Int(width), h = Int(height)
            guard w > 0, h > 0, w <= LinearMipGenerator.maxDecodeDimension,
                  h <= LinearMipGenerator.maxDecodeDimension, rowBytes >= w * 4,
                  rowBytes <= Int.max / h, duration.isFinite else { return false }
            let stride = w * 4
            let byteCount = h * stride
            guard byteCount <= LinearMipGenerator.maxDecodedBytes - totalBytes else { return false }

            let rgba: Data
            if rowBytes == stride {
                rgba = Data(bytes: pixels, count: byteCount)
            } else {
                var tightlyPacked = Data(capacity: byteCount)
                for row in 0..<h {
                    tightlyPacked.append(pixels.advanced(by: row * rowBytes), count: stride)
                }
                rgba = tightlyPacked
            }
            values.append(AnimatedImageFrame(decodedWidth: width, height: height, rgba: rgba, durationSeconds: duration))
            totalBytes += byteCount
            return true
        }
    }

    static func decode(_ data: Data, id: String, maxDimension: Int?) throws -> DecodedImage {
        let frames = Frames()
        let limit = UInt32(clamping: min(LinearMipGenerator.maxDecodeDimension, maxDimension ?? 0))
        var loopCount: UInt32 = 0
        var error = [CChar](repeating: 0, count: 384)
        let capacity = error.count
        let result = data.withUnsafeBytes { raw in
            rune_image_decode(raw.bindMemory(to: UInt8.self).baseAddress, raw.count, limit, &loopCount, {
                context, w, h, pixels, stride, duration in
                guard let context, let pixels else { return 0 }
                let frames = Unmanaged<Frames>.fromOpaque(context).takeUnretainedValue()
                return frames.append(width: w, height: h, pixels: pixels, rowBytes: stride, duration: duration) ? 1 : 0
            }, Unmanaged.passUnretained(frames).toOpaque(), &error, capacity)
        }
        guard result != 0, let first = frames.values.first else {
            let message = String(decoding: error.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)), as: UTF8.self)
            throw ImageError(message.isEmpty ? "Image decoder returned no frames" : message)
        }
        let mips = DecodedImage.generateMipChain(width: first.width, height: first.height, rgba: first.rgba)
        let isGIF = data.starts(with: "GIF87a".utf8) || data.starts(with: "GIF89a".utf8)
        let plays: Int
        if isGIF {
            // A GIF counts repetitions after the initial presentation, and plays once
            // when it omits the loop extension. ImageIO exposes total presentations.
            plays = loopCount == .max ? 1 : (loopCount == 0 ? 0 : Int(loopCount) + 1)
        } else {
            plays = Int(loopCount)
        }
        return DecodedImage(id: id, width: first.width, height: first.height, mips: mips,
                            frames: frames.values, loopCount: plays)
    }
}
#endif
