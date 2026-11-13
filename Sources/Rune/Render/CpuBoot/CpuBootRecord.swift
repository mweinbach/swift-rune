import Foundation
#if canImport(simd)
import simd
#endif

/// Binary frame recording for `CpuBoot` (`RCB1` magic, little-endian, `cpu_boot/record.rs`).
public enum CpuBootRecord {
    public static let magic: [UInt8] = Array("RCB1".utf8)

    public struct Recording: Sendable {
        public let instances: [RenderInstance]
        public let glyphPages: [[UInt8]]
        public let glyphPageWidth: Int
        public let glyphPageHeight: Int
        public let images: [(Int, [UInt8])]
        public let size: (Int, Int)
        public let clear: SIMD4<Float>
        public let lcd: Bool

        public func scene() -> CpuBootScene {
            CpuBootScene(
                instances: instances,
                glyphPages: glyphPages,
                glyphPageWidth: glyphPageWidth,
                glyphPageHeight: glyphPageHeight,
                images: images.map { CpuBootImage(width: $0.0, data: $0.1) },
                size: size,
                clear: clear,
                lcd: lcd,
                srgbBlend: true,
                nativeSurfaces: false,
                compositor: false,
                smoothing: nil,
                outlines: nil,
                atlasResets: 0,
                half: .towardZero
            )
        }
    }

    private static func appendU32LE(_ v: UInt32, to out: inout [UInt8]) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }

    public static func encode(_ scene: CpuBootScene) -> [UInt8] {
        var out: [UInt8] = []
        out.append(contentsOf: magic)
        appendU32LE(UInt32(max(0, scene.size.0)), to: &out)
        appendU32LE(UInt32(max(0, scene.size.1)), to: &out)
        appendU32LE(scene.clear.x.bitPattern, to: &out)
        appendU32LE(scene.clear.y.bitPattern, to: &out)
        appendU32LE(scene.clear.z.bitPattern, to: &out)
        appendU32LE(scene.clear.w.bitPattern, to: &out)
        appendU32LE(scene.lcd ? 1 : 0, to: &out)
        appendU32LE(UInt32(scene.instances.count), to: &out)
        scene.instances.withUnsafeBytes { raw in
            out.append(contentsOf: raw)
        }
        appendU32LE(UInt32(scene.glyphPages.count), to: &out)
        appendU32LE(UInt32(max(0, scene.glyphPageWidth)), to: &out)
        appendU32LE(UInt32(max(0, scene.glyphPageHeight)), to: &out)
        for page in scene.glyphPages {
            out.append(contentsOf: page)
        }
        appendU32LE(UInt32(scene.images.count), to: &out)
        for img in scene.images {
            let rowBytes = max(1, img.width * 4)
            let h = img.data.count / rowBytes
            appendU32LE(UInt32(max(0, img.width)), to: &out)
            appendU32LE(UInt32(max(0, h)), to: &out)
            out.append(contentsOf: img.data)
        }
        return out
    }

    public static func decode(_ bytes: [UInt8]) -> Recording? {
        var at = 0
        func take(_ n: Int) -> ArraySlice<UInt8>? {
            guard n >= 0, at <= bytes.count - n else { return nil }
            let s = bytes[at..<(at + n)]
            at += n
            return s
        }
        func readU32() -> UInt32? {
            guard let slice = take(4) else { return nil }
            let i = slice.startIndex
            return UInt32(slice[i])
                | (UInt32(slice[i + 1]) << 8)
                | (UInt32(slice[i + 2]) << 16)
                | (UInt32(slice[i + 3]) << 24)
        }
        guard let hdr = take(4), Array(hdr) == magic else { return nil }
        guard let w = readU32(), let h = readU32() else { return nil }
        guard let c0 = readU32(), let c1 = readU32(), let c2 = readU32(), let c3 = readU32() else { return nil }
        guard let flags = readU32() else { return nil }
        guard let instCount = readU32() else { return nil }
        let instBytesLen = Int(instCount) * MemoryLayout<RenderInstance>.stride
        guard let instSlice = take(instBytesLen) else { return nil }
        var instances = [RenderInstance](repeating: .zero, count: Int(instCount))
        if instCount > 0 {
            let instArr = Array(instSlice)
            instances.withUnsafeMutableBytes { dst in
                instArr.withUnsafeBytes { src in
                    dst.copyBytes(from: src)
                }
            }
        }
        guard let pageCount = readU32(),
              let pageW = readU32(),
              let pageH = readU32() else {
            return nil
        }
        let pageLen = Int(pageW) * Int(pageH)
        var glyphPages: [[UInt8]] = []
        glyphPages.reserveCapacity(Int(pageCount))
        for _ in 0..<pageCount {
            guard let slice = take(pageLen) else { return nil }
            glyphPages.append(Array(slice))
        }
        guard let imgCount = readU32() else { return nil }
        var images: [(Int, [UInt8])] = []
        images.reserveCapacity(Int(imgCount))
        for _ in 0..<imgCount {
            guard let iw = readU32(), let ih = readU32() else { return nil }
            let byteCount = Int(iw) * Int(ih) * 4
            guard let slice = take(byteCount) else { return nil }
            images.append((Int(iw), Array(slice)))
        }
        return Recording(
            instances: instances,
            glyphPages: glyphPages,
            glyphPageWidth: Int(pageW),
            glyphPageHeight: Int(pageH),
            images: images,
            size: (Int(w), Int(h)),
            clear: SIMD4<Float>(
                Float(bitPattern: c0),
                Float(bitPattern: c1),
                Float(bitPattern: c2),
                Float(bitPattern: c3)
            ),
            lcd: (flags & 1) != 0
        )
    }
}
