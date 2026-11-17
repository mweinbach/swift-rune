import Foundation

internal enum LuauOpCode {
    case loadNil
    case loadBool(Bool)
    case loadConst(Int)
    case loadVararg(expected: Int) // -1 = all

    case getLocal(Int)
    case setLocal(Int)
    case getUpvalue(Int)
    case setUpvalue(Int)
    case getGlobal(Int) // const string index
    case setGlobal(Int)

    case newTable(arrayHint: Int, hashHint: Int)
    case getTable
    case setTable
    case initTableField
    case getField(Int) // const string index
    case setField(Int) // const string index
    case setList(startIndex: Int, count: Int) // pops count items into table below them
    case setListMulti(startIndex: Int, stackBaseMark: Int) // not used; we use mark-based

    case selfMethod(Int) // pops obj, pushes method, pushes obj

    case add, sub, mul, div, idiv, mod, pow, concat
    case neg, not, len
    case eq, neq, lt, le, gt, ge

    case jump(Int)
    case jumpIfFalse(Int) // pops cond, jumps if falsy
    case jumpIfTruePop(Int)
    case andJump(Int) // peeks top; if falsy jumps (leaving it), else pops
    case orJump(Int)  // peeks top; if truthy jumps (leaving it), else pops

    case closure(protoIndex: Int)
    case closeUpvalues(fromSlot: Int)

    case call(argCount: Int, expectedResults: Int) // expectedResults: -1 = all
    case callMulti(fixedArgsBefore: Int, expectedResults: Int) // uses mark stack
    case pushMark
    case popMarkAndReturn
    case `return`(count: Int)

    case numericForPrep(varSlot: Int, jumpOffset: Int)
    case numericForLoop(varSlot: Int, jumpOffset: Int)
    case genericForPrep(baseSlot: Int) // normalizes table generalized iteration
    case genericForCall(baseSlot: Int, varCount: Int, jumpOffset: Int)

    case interp(partsCount: Int) // pops `partsCount - 1` expr values, formats & concats with literals
}

internal struct LuauInstruction {
    let op: LuauOpCode
    let line: Int
}

internal enum LuauUpvalueDesc {
    case local(Int)
    case upvalue(Int)
}

internal final class LuauProto: @unchecked Sendable {
    let name: String
    let sourceName: String
    let paramsCount: Int
    let isVariadic: Bool
    let numLocals: Int
    let constants: [LuauValue]
    let upvalues: [LuauUpvalueDesc]
    let protos: [LuauProto]
    let code: [LuauInstruction]

    init(
        name: String,
        sourceName: String,
        paramsCount: Int,
        isVariadic: Bool,
        numLocals: Int,
        constants: [LuauValue],
        upvalues: [LuauUpvalueDesc],
        protos: [LuauProto],
        code: [LuauInstruction]
    ) {
        self.name = name
        self.sourceName = sourceName
        self.paramsCount = paramsCount
        self.isVariadic = isVariadic
        self.numLocals = numLocals
        self.constants = constants
        self.upvalues = upvalues
        self.protos = protos
        self.code = code
    }

    static let bytecodeMagic: [UInt8] = [0x52, 0x4C, 0x42, 0x43] // "RLBC"
    static let bytecodeVersion: UInt32 = 1
    static let bytecodeHeader = bytecodeMagic + withUnsafeBytes(of: bytecodeVersion.littleEndian) { Array($0) }

    func encode() -> Data {
        var buf = ByteWriter()
        buf.writeBytes(Self.bytecodeHeader)
        encodeProto(into: &buf)
        return Data(buf.bytes)
    }

    static func decode(_ data: Data, sourceName: String) -> LuauProto? {
        var reader = ByteReader([UInt8](data))
        guard reader.readBytes(count: Self.bytecodeHeader.count) == Self.bytecodeHeader else {
            return nil
        }
        guard let proto = decodeProto(from: &reader, sourceName: sourceName), reader.isAtEnd else {
            return nil
        }
        return proto
    }

    private func encodeProto(into buf: inout ByteWriter) {
        buf.writeString(name)
        buf.writeString(sourceName)
        buf.writeInt64(Int64(paramsCount))
        buf.writeUInt8(isVariadic ? 1 : 0)
        buf.writeInt64(Int64(numLocals))

        buf.writeInt64(Int64(constants.count))
        for c in constants {
            switch c {
            case .nil:
                buf.writeUInt8(0)
            case .bool(let b):
                buf.writeUInt8(1)
                buf.writeUInt8(b ? 1 : 0)
            case .number(let n):
                buf.writeUInt8(2)
                buf.writeUInt64(n.bitPattern)
            case .string(let s):
                buf.writeUInt8(3)
                buf.writeString(s)
            case .byteString(let bytes):
                buf.writeUInt8(4)
                buf.writeInt64(Int64(bytes.count))
                buf.writeBytes(bytes)
            case .vector(let v):
                buf.writeUInt8(5)
                buf.writeUInt64(v.x.bitPattern)
                buf.writeUInt64(v.y.bitPattern)
                buf.writeUInt64(v.z.bitPattern)
            default:
                buf.writeUInt8(0)
            }
        }

        buf.writeInt64(Int64(upvalues.count))
        for uv in upvalues {
            switch uv {
            case .local(let slot):
                buf.writeUInt8(0)
                buf.writeInt64(Int64(slot))
            case .upvalue(let idx):
                buf.writeUInt8(1)
                buf.writeInt64(Int64(idx))
            }
        }

        buf.writeInt64(Int64(protos.count))
        for p in protos {
            p.encodeProto(into: &buf)
        }

        buf.writeInt64(Int64(code.count))
        for insn in code {
            buf.writeInt64(Int64(insn.line))
            Self.encodeOp(insn.op, into: &buf)
        }
    }

    private static func decodeProto(from reader: inout ByteReader, sourceName: String) -> LuauProto? {
        guard let name = reader.readString(),
              reader.readString() != nil, // The loaded module path names every nested function.
              let paramsCount = reader.readInt(),
              let isVarByte = reader.readUInt8(),
              let numLocals = reader.readInt(),
              let constCount = reader.readInt(), constCount >= 0 else {
            return nil
        }
        var constants: [LuauValue] = []
        constants.reserveCapacity(constCount)
        for _ in 0..<constCount {
            guard let tag = reader.readUInt8() else { return nil }
            switch tag {
            case 0:
                constants.append(.nil)
            case 1:
                guard let b = reader.readUInt8() else { return nil }
                constants.append(.bool(b != 0))
            case 2:
                guard let bits = reader.readUInt64() else { return nil }
                constants.append(.number(Double(bitPattern: bits)))
            case 3:
                guard let s = reader.readString() else { return nil }
                constants.append(.string(s))
            case 4:
                guard let len = reader.readInt(), len >= 0,
                      let bytes = reader.readBytes(count: len) else { return nil }
                constants.append(.byteString(bytes))
            case 5:
                guard let bx = reader.readUInt64(),
                      let by = reader.readUInt64(),
                      let bz = reader.readUInt64() else { return nil }
                constants.append(.vector(SIMD3<Double>(Double(bitPattern: bx), Double(bitPattern: by), Double(bitPattern: bz))))
            default:
                return nil
            }
        }

        guard let uvCount = reader.readInt(), uvCount >= 0 else { return nil }
        var upvalues: [LuauUpvalueDesc] = []
        upvalues.reserveCapacity(uvCount)
        for _ in 0..<uvCount {
            guard let tag = reader.readUInt8(), let idx = reader.readInt() else { return nil }
            switch tag {
            case 0: upvalues.append(.local(idx))
            case 1: upvalues.append(.upvalue(idx))
            default: return nil
            }
        }

        guard let protoCount = reader.readInt(), protoCount >= 0 else { return nil }
        var protos: [LuauProto] = []
        protos.reserveCapacity(protoCount)
        for _ in 0..<protoCount {
            guard let p = decodeProto(from: &reader, sourceName: sourceName) else { return nil }
            protos.append(p)
        }

        guard let codeCount = reader.readInt(), codeCount >= 0 else { return nil }
        var code: [LuauInstruction] = []
        code.reserveCapacity(codeCount)
        for _ in 0..<codeCount {
            guard let line = reader.readInt(), let op = decodeOp(from: &reader) else { return nil }
            code.append(LuauInstruction(op: op, line: line))
        }

        return LuauProto(
            name: name,
            sourceName: sourceName,
            paramsCount: paramsCount,
            isVariadic: isVarByte != 0,
            numLocals: numLocals,
            constants: constants,
            upvalues: upvalues,
            protos: protos,
            code: code
        )
    }

    private static func encodeOp(_ op: LuauOpCode, into buf: inout ByteWriter) {
        switch op {
        case .loadNil: buf.writeUInt8(0)
        case .loadBool(let b): buf.writeUInt8(1); buf.writeUInt8(b ? 1 : 0)
        case .loadConst(let a): buf.writeUInt8(2); buf.writeInt64(Int64(a))
        case .loadVararg(let a): buf.writeUInt8(3); buf.writeInt64(Int64(a))
        case .getLocal(let a): buf.writeUInt8(4); buf.writeInt64(Int64(a))
        case .setLocal(let a): buf.writeUInt8(5); buf.writeInt64(Int64(a))
        case .getUpvalue(let a): buf.writeUInt8(6); buf.writeInt64(Int64(a))
        case .setUpvalue(let a): buf.writeUInt8(7); buf.writeInt64(Int64(a))
        case .getGlobal(let a): buf.writeUInt8(8); buf.writeInt64(Int64(a))
        case .setGlobal(let a): buf.writeUInt8(9); buf.writeInt64(Int64(a))
        case .newTable(let a, let b): buf.writeUInt8(10); buf.writeInt64(Int64(a)); buf.writeInt64(Int64(b))
        case .getTable: buf.writeUInt8(11)
        case .setTable: buf.writeUInt8(12)
        case .initTableField: buf.writeUInt8(13)
        case .getField(let a): buf.writeUInt8(14); buf.writeInt64(Int64(a))
        case .setField(let a): buf.writeUInt8(15); buf.writeInt64(Int64(a))
        case .setList(let a, let b): buf.writeUInt8(16); buf.writeInt64(Int64(a)); buf.writeInt64(Int64(b))
        case .setListMulti(let a, let b): buf.writeUInt8(17); buf.writeInt64(Int64(a)); buf.writeInt64(Int64(b))
        case .selfMethod(let a): buf.writeUInt8(18); buf.writeInt64(Int64(a))
        case .add: buf.writeUInt8(19)
        case .sub: buf.writeUInt8(20)
        case .mul: buf.writeUInt8(21)
        case .div: buf.writeUInt8(22)
        case .idiv: buf.writeUInt8(23)
        case .mod: buf.writeUInt8(24)
        case .pow: buf.writeUInt8(25)
        case .concat: buf.writeUInt8(26)
        case .neg: buf.writeUInt8(27)
        case .not: buf.writeUInt8(28)
        case .len: buf.writeUInt8(29)
        case .eq: buf.writeUInt8(30)
        case .neq: buf.writeUInt8(31)
        case .lt: buf.writeUInt8(32)
        case .le: buf.writeUInt8(33)
        case .gt: buf.writeUInt8(34)
        case .ge: buf.writeUInt8(35)
        case .jump(let a): buf.writeUInt8(36); buf.writeInt64(Int64(a))
        case .jumpIfFalse(let a): buf.writeUInt8(37); buf.writeInt64(Int64(a))
        case .jumpIfTruePop(let a): buf.writeUInt8(38); buf.writeInt64(Int64(a))
        case .andJump(let a): buf.writeUInt8(39); buf.writeInt64(Int64(a))
        case .orJump(let a): buf.writeUInt8(40); buf.writeInt64(Int64(a))
        case .closure(let a): buf.writeUInt8(41); buf.writeInt64(Int64(a))
        case .closeUpvalues(let a): buf.writeUInt8(42); buf.writeInt64(Int64(a))
        case .call(let a, let b): buf.writeUInt8(43); buf.writeInt64(Int64(a)); buf.writeInt64(Int64(b))
        case .callMulti(let a, let b): buf.writeUInt8(44); buf.writeInt64(Int64(a)); buf.writeInt64(Int64(b))
        case .pushMark: buf.writeUInt8(45)
        case .popMarkAndReturn: buf.writeUInt8(46)
        case .return(let a): buf.writeUInt8(47); buf.writeInt64(Int64(a))
        case .numericForPrep(let a, let b): buf.writeUInt8(48); buf.writeInt64(Int64(a)); buf.writeInt64(Int64(b))
        case .numericForLoop(let a, let b): buf.writeUInt8(49); buf.writeInt64(Int64(a)); buf.writeInt64(Int64(b))
        case .genericForPrep(let a): buf.writeUInt8(50); buf.writeInt64(Int64(a))
        case .genericForCall(let a, let b, let c): buf.writeUInt8(51); buf.writeInt64(Int64(a)); buf.writeInt64(Int64(b)); buf.writeInt64(Int64(c))
        case .interp(let a): buf.writeUInt8(52); buf.writeInt64(Int64(a))
        }
    }

    private static func decodeOp(from reader: inout ByteReader) -> LuauOpCode? {
        guard let tag = reader.readUInt8() else { return nil }
        switch tag {
        case 0: return .loadNil
        case 1: guard let b = reader.readUInt8() else { return nil }; return .loadBool(b != 0)
        case 2: guard let a = reader.readInt() else { return nil }; return .loadConst(a)
        case 3: guard let a = reader.readInt() else { return nil }; return .loadVararg(expected: a)
        case 4: guard let a = reader.readInt() else { return nil }; return .getLocal(a)
        case 5: guard let a = reader.readInt() else { return nil }; return .setLocal(a)
        case 6: guard let a = reader.readInt() else { return nil }; return .getUpvalue(a)
        case 7: guard let a = reader.readInt() else { return nil }; return .setUpvalue(a)
        case 8: guard let a = reader.readInt() else { return nil }; return .getGlobal(a)
        case 9: guard let a = reader.readInt() else { return nil }; return .setGlobal(a)
        case 10: guard let a = reader.readInt(), let b = reader.readInt() else { return nil }; return .newTable(arrayHint: a, hashHint: b)
        case 11: return .getTable
        case 12: return .setTable
        case 13: return .initTableField
        case 14: guard let a = reader.readInt() else { return nil }; return .getField(a)
        case 15: guard let a = reader.readInt() else { return nil }; return .setField(a)
        case 16: guard let a = reader.readInt(), let b = reader.readInt() else { return nil }; return .setList(startIndex: a, count: b)
        case 17: guard let a = reader.readInt(), let b = reader.readInt() else { return nil }; return .setListMulti(startIndex: a, stackBaseMark: b)
        case 18: guard let a = reader.readInt() else { return nil }; return .selfMethod(a)
        case 19: return .add
        case 20: return .sub
        case 21: return .mul
        case 22: return .div
        case 23: return .idiv
        case 24: return .mod
        case 25: return .pow
        case 26: return .concat
        case 27: return .neg
        case 28: return .not
        case 29: return .len
        case 30: return .eq
        case 31: return .neq
        case 32: return .lt
        case 33: return .le
        case 34: return .gt
        case 35: return .ge
        case 36: guard let a = reader.readInt() else { return nil }; return .jump(a)
        case 37: guard let a = reader.readInt() else { return nil }; return .jumpIfFalse(a)
        case 38: guard let a = reader.readInt() else { return nil }; return .jumpIfTruePop(a)
        case 39: guard let a = reader.readInt() else { return nil }; return .andJump(a)
        case 40: guard let a = reader.readInt() else { return nil }; return .orJump(a)
        case 41: guard let a = reader.readInt() else { return nil }; return .closure(protoIndex: a)
        case 42: guard let a = reader.readInt() else { return nil }; return .closeUpvalues(fromSlot: a)
        case 43: guard let a = reader.readInt(), let b = reader.readInt() else { return nil }; return .call(argCount: a, expectedResults: b)
        case 44: guard let a = reader.readInt(), let b = reader.readInt() else { return nil }; return .callMulti(fixedArgsBefore: a, expectedResults: b)
        case 45: return .pushMark
        case 46: return .popMarkAndReturn
        case 47: guard let a = reader.readInt() else { return nil }; return .return(count: a)
        case 48: guard let a = reader.readInt(), let b = reader.readInt() else { return nil }; return .numericForPrep(varSlot: a, jumpOffset: b)
        case 49: guard let a = reader.readInt(), let b = reader.readInt() else { return nil }; return .numericForLoop(varSlot: a, jumpOffset: b)
        case 50: guard let a = reader.readInt() else { return nil }; return .genericForPrep(baseSlot: a)
        case 51: guard let a = reader.readInt(), let b = reader.readInt(), let c = reader.readInt() else { return nil }; return .genericForCall(baseSlot: a, varCount: b, jumpOffset: c)
        case 52: guard let a = reader.readInt() else { return nil }; return .interp(partsCount: a)
        default: return nil
        }
    }
}

private struct ByteWriter {
    var bytes: [UInt8] = []
    mutating func writeUInt8(_ v: UInt8) { bytes.append(v) }
    mutating func writeUInt64(_ v: UInt64) {
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { bytes.append(contentsOf: $0) }
    }
    mutating func writeInt64(_ v: Int64) {
        writeUInt64(UInt64(bitPattern: v))
    }
    mutating func writeBytes(_ data: [UInt8]) { bytes.append(contentsOf: data) }
    mutating func writeString(_ s: String) {
        let utf8 = Array(s.utf8)
        writeInt64(Int64(utf8.count))
        bytes.append(contentsOf: utf8)
    }
}

private struct ByteReader {
    let bytes: [UInt8]
    var offset: Int = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var isAtEnd: Bool { offset == bytes.count }
    mutating func readUInt8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        let v = bytes[offset]; offset += 1; return v
    }
    mutating func readUInt64() -> UInt64? {
        guard let slice = readBytes(count: 8) else { return nil }
        return slice.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian
    }
    mutating func readInt() -> Int? {
        guard let u = readUInt64() else { return nil }
        let i64 = Int64(bitPattern: u)
        return Int(exactly: i64)
    }
    mutating func readBytes(count: Int) -> [UInt8]? {
        guard count >= 0, offset + count <= bytes.count else { return nil }
        let res = Array(bytes[offset..<(offset + count)])
        offset += count
        return res
    }
    mutating func readString() -> String? {
        guard let count = readInt(), count >= 0, let slice = readBytes(count: count) else { return nil }
        return String(bytes: slice, encoding: .utf8)
    }
}
