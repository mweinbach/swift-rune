import Foundation

/// A resting browser keeps the last full GPU paint. Its cycle updates carry just a
/// stable slot number, four premultiplied channels and the opacity for that slot.
enum WebCyclePacket {
    static let magic: UInt32 = 0x31435352 // RSC1
    static func size(slotCount: Int) -> Int { 24 + slotCount * 24 }

    static func markFullPaint(_ buffer: UnsafeMutableRawPointer, byteCount: Int, serial: UInt64) {
        let header = buffer.assumingMemoryBound(to: UInt32.self)
        header[3] |= 64
        // The final atlas or surface payload may have an odd byte count.
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: serial).littleEndian) { source in
            (buffer + byteCount).copyMemory(from: source.baseAddress!, byteCount: 4)
        }
    }

    static func write(scene: RenderFrame, paint: CyclePaint, to buffer: UnsafeMutableRawPointer) {
        let words = buffer.assumingMemoryBound(to: UInt32.self)
        words[0] = magic
        words[1] = UInt32(scene.width)
        words[2] = UInt32(scene.height)
        words[3] = UInt32(truncatingIfNeeded: paint.serial)
        words[4] = UInt32(scene.instances.count)
        words[5] = UInt32(paint.slots.count)
        var offset = 6
        for slot in paint.slots {
            let q = scene.instances[slot.index]
            words[offset] = UInt32(slot.index)
            words[offset + 1] = q.fill.x.bitPattern
            words[offset + 2] = q.fill.y.bitPattern
            words[offset + 3] = q.fill.z.bitPattern
            words[offset + 4] = q.fill.w.bitPattern
            words[offset + 5] = q.params.w.bitPattern
            offset += 6
        }
    }
}
