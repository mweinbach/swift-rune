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
}
