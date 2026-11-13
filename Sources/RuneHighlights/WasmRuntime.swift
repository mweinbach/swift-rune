import Foundation

typealias V128 = SIMD16<UInt8>

let wasmPageSize = 65536
private let wasmMaxPages = 65536

enum WasmTrap: Error {
    case trap
}

@inline(never)
func trap() throws -> Never {
    throw WasmTrap.trap
}

@inline(__always)
func bitmask(_ v: V128) -> Int32 {
    var result: Int32 = 0
    for i in 0..<16 {
        result |= Int32(v[i] >> 7) << i
    }
    return result
}

@inline(__always)
func lanesEq(_ a: V128, _ b: V128) -> V128 {
    V128(repeating: 0).replacing(with: V128(repeating: 0xff), where: a .== b)
}

@inline(__always)
func lanesNe(_ a: V128, _ b: V128) -> V128 {
    V128(repeating: 0).replacing(with: V128(repeating: 0xff), where: a .!= b)
}

@inline(__always)
func lanesLeU(_ a: V128, _ b: V128) -> V128 {
    V128(repeating: 0).replacing(with: V128(repeating: 0xff), where: a .<= b)
}

@inline(__always)
func lanesGeU(_ a: V128, _ b: V128) -> V128 {
    V128(repeating: 0).replacing(with: V128(repeating: 0xff), where: a .>= b)
}

@inline(__always)
func lanesGtS(_ a: V128, _ b: V128) -> V128 {
    let sa = SIMD16<Int8>(truncatingIfNeeded: a)
    let sb = SIMD16<Int8>(truncatingIfNeeded: b)
    var out = V128.zero
    for i in 0..<16 {
        if sa[i] > sb[i] { out[i] = 0xff }
    }
    return out
}

@inline(__always)
func rotl32(_ x: Int32, _ n: Int32) -> Int32 {
    let k = UInt32(bitPattern: n) & 31
    let u = UInt32(bitPattern: x)
    return Int32(bitPattern: (u &<< k) | (u &>> ((32 &- k) & 31)))
}

@inline(__always)
func rotl64(_ x: Int64, _ n: Int64) -> Int64 {
    let k = UInt64(bitPattern: n) & 63
    let u = UInt64(bitPattern: x)
    return Int64(bitPattern: (u &<< k) | (u &>> ((64 &- k) & 63)))
}

extension WasmHighlightsModule {
    @inline(__always)
    private func addr(_ a: Int32, _ off: UInt64, _ width: Int) throws -> Int {
        let idx = Int(UInt32(bitPattern: a)) + Int(off)
        guard idx >= 0, idx + width <= mem.count else {
            try trap()
        }
        return idx
    }

    @inline(__always)
    func ld8u(_ a: Int32, _ off: UInt64) throws -> Int32 {
        let i = try addr(a, off, 1)
        return Int32(mem[i])
    }

    @inline(__always)
    func ld16u(_ a: Int32, _ off: UInt64) throws -> Int32 {
        let i = try addr(a, off, 2)
        return Int32(UInt16(mem[i]) | (UInt16(mem[i &+ 1]) << 8))
    }

    @inline(__always)
    func ld16s(_ a: Int32, _ off: UInt64) throws -> Int32 {
        let i = try addr(a, off, 2)
        return Int32(Int16(bitPattern: UInt16(mem[i]) | (UInt16(mem[i &+ 1]) << 8)))
    }

    @inline(__always)
    func ld32(_ a: Int32, _ off: UInt64) throws -> Int32 {
        let i = try addr(a, off, 4)
        let raw = UInt32(mem[i])
            | (UInt32(mem[i &+ 1]) << 8)
            | (UInt32(mem[i &+ 2]) << 16)
            | (UInt32(mem[i &+ 3]) << 24)
        return Int32(bitPattern: raw)
    }

    @inline(__always)
    func ld64(_ a: Int32, _ off: UInt64) throws -> Int64 {
        let i = try addr(a, off, 8)
        let raw = UInt64(mem[i])
            | (UInt64(mem[i &+ 1]) << 8)
            | (UInt64(mem[i &+ 2]) << 16)
            | (UInt64(mem[i &+ 3]) << 24)
            | (UInt64(mem[i &+ 4]) << 32)
            | (UInt64(mem[i &+ 5]) << 40)
            | (UInt64(mem[i &+ 6]) << 48)
            | (UInt64(mem[i &+ 7]) << 56)
        return Int64(bitPattern: raw)
    }

    @inline(__always)
    func ld128(_ a: Int32, _ off: UInt64) throws -> V128 {
        let i = try addr(a, off, 16)
        return V128(
            mem[i], mem[i &+ 1], mem[i &+ 2], mem[i &+ 3],
            mem[i &+ 4], mem[i &+ 5], mem[i &+ 6], mem[i &+ 7],
            mem[i &+ 8], mem[i &+ 9], mem[i &+ 10], mem[i &+ 11],
            mem[i &+ 12], mem[i &+ 13], mem[i &+ 14], mem[i &+ 15]
        )
    }

    @inline(__always)
    func st8(_ a: Int32, _ off: UInt64, _ v: Int32) throws {
        let i = try addr(a, off, 1)
        mem[i] = UInt8(truncatingIfNeeded: v)
    }

    @inline(__always)
    func st16(_ a: Int32, _ off: UInt64, _ v: Int32) throws {
        let i = try addr(a, off, 2)
        let u = UInt16(truncatingIfNeeded: v)
        mem[i] = UInt8(truncatingIfNeeded: u)
        mem[i &+ 1] = UInt8(truncatingIfNeeded: u >> 8)
    }

    @inline(__always)
    func st32(_ a: Int32, _ off: UInt64, _ v: Int32) throws {
        let i = try addr(a, off, 4)
        let u = UInt32(bitPattern: v)
        mem[i] = UInt8(truncatingIfNeeded: u)
        mem[i &+ 1] = UInt8(truncatingIfNeeded: u >> 8)
        mem[i &+ 2] = UInt8(truncatingIfNeeded: u >> 16)
        mem[i &+ 3] = UInt8(truncatingIfNeeded: u >> 24)
    }

    @inline(__always)
    func st64(_ a: Int32, _ off: UInt64, _ v: Int64) throws {
        let i = try addr(a, off, 8)
        let u = UInt64(bitPattern: v)
        mem[i] = UInt8(truncatingIfNeeded: u)
        mem[i &+ 1] = UInt8(truncatingIfNeeded: u >> 8)
        mem[i &+ 2] = UInt8(truncatingIfNeeded: u >> 16)
        mem[i &+ 3] = UInt8(truncatingIfNeeded: u >> 24)
        mem[i &+ 4] = UInt8(truncatingIfNeeded: u >> 32)
        mem[i &+ 5] = UInt8(truncatingIfNeeded: u >> 40)
        mem[i &+ 6] = UInt8(truncatingIfNeeded: u >> 48)
        mem[i &+ 7] = UInt8(truncatingIfNeeded: u >> 56)
    }

    @inline(__always)
    func st128(_ a: Int32, _ off: UInt64, _ v: V128) throws {
        let i = try addr(a, off, 16)
        for lane in 0..<16 {
            mem[i &+ lane] = v[lane]
        }
    }

    func grow(_ pages: Int32) -> Int32 {
        let old = mem.count / wasmPageSize
        let add = Int(UInt32(bitPattern: pages))
        let next = old + add
        if next > wasmMaxPages {
            return -1
        }
        mem.append(contentsOf: repeatElement(0 as UInt8, count: add * wasmPageSize))
        return Int32(truncatingIfNeeded: old)
    }

    func copy(_ dst: Int32, _ src: Int32, _ n: Int32) throws {
        let d = Int(UInt32(bitPattern: dst))
        let s = Int(UInt32(bitPattern: src))
        let count = Int(UInt32(bitPattern: n))
        guard max(d, s) + count <= mem.count else {
            try trap()
        }
        guard count > 0, d != s else { return }
        mem.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let srcPtr = UnsafeRawPointer(base.advanced(by: s))
            base.advanced(by: d).copyMemory(from: srcPtr, byteCount: count)
        }
    }

    func fill(_ dst: Int32, _ v: Int32, _ n: Int32) throws {
        let d = Int(UInt32(bitPattern: dst))
        let count = Int(UInt32(bitPattern: n))
        guard d + count <= mem.count else {
            try trap()
        }
        guard count > 0 else { return }
        let byte = UInt8(truncatingIfNeeded: v)
        mem.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            UnsafeMutableRawBufferPointer(start: base.advanced(by: d), count: count)
                .initializeMemory(as: UInt8.self, repeating: byte)
        }
    }
}

enum WasmHost {
    private static let idStartOnly: Set<UInt32> = [
        0x037a, 0x0e33, 0x0eb3, 0x309b, 0x309c, 0xfc5e, 0xfc5f, 0xfc60,
        0xfc61, 0xfc62, 0xfc63, 0xfdfa, 0xfdfb, 0xfe70, 0xfe72, 0xfe74,
        0xfe76, 0xfe78, 0xfe7a, 0xfe7c, 0xfe7e, 0xff9e, 0xff9f,
    ]

    private static let idContinueOnly: Set<UInt32> = [
        0x037a, 0x309b, 0x309c, 0xfc5e, 0xfc5f, 0xfc60, 0xfc61, 0xfc62,
        0xfc63, 0xfdfa, 0xfdfb, 0xfe70, 0xfe72, 0xfe74, 0xfe76, 0xfe78,
        0xfe7a, 0xfe7c, 0xfe7e,
    ]

    private static func scalarAt(_ mem: [UInt8], _ ptr: Int32, _ len: Int32) -> Unicode.Scalar? {
        let at = Int(UInt32(bitPattern: ptr))
        let n = Int(UInt32(bitPattern: len))
        guard at + n <= mem.count,
              let s = String(bytes: mem[at..<(at + n)], encoding: .utf8)
        else { return nil }
        return s.unicodeScalars.first
    }

    static func isIdStart(_ mem: inout [UInt8], _ ptr: Int32, _ len: Int32) -> Int32 {
        guard let c = scalarAt(mem, ptr, len) else { return 0 }
        return (c.properties.isXIDStart || c.properties.isIDStart || idStartOnly.contains(c.value)) ? 1 : 0
    }

    static func isIdContinue(_ mem: inout [UInt8], _ ptr: Int32, _ len: Int32) -> Int32 {
        guard let c = scalarAt(mem, ptr, len) else { return 0 }
        return (c.value == 0x200C || c.value == 0x200D || c.properties.isXIDContinue || c.properties.isIDContinue || idContinueOnly.contains(c.value)) ? 1 : 0
    }
}
