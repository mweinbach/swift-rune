import Foundation

internal indirect enum LuauStmt {
    case block([LuauStmt], line: Int)
    case localDecl(names: [String], values: [LuauExpr], line: Int)
    case localFunction(name: String, params: [String], isVariadic: Bool, body: [LuauStmt], line: Int)
    case functionDecl(path: [String], method: String?, params: [String], isVariadic: Bool, body: [LuauStmt], line: Int)
    case assign(targets: [LuauLValue], values: [LuauExpr], line: Int)
    case compoundAssign(target: LuauLValue, op: LuauCompoundOp, value: LuauExpr, line: Int)
    case call(LuauExpr, line: Int)
    case ifStmt(branches: [(cond: LuauExpr, body: [LuauStmt])], elseBody: [LuauStmt]?, line: Int)
    case whileStmt(cond: LuauExpr, body: [LuauStmt], line: Int)
    case repeatStmt(body: [LuauStmt], cond: LuauExpr, line: Int)
    case numericFor(varName: String, start: LuauExpr, limit: LuauExpr, step: LuauExpr?, body: [LuauStmt], line: Int)
    case genericFor(names: [String], iterators: [LuauExpr], body: [LuauStmt], line: Int)
    case returnStmt([LuauExpr], line: Int)
    case breakStmt(line: Int)
    case continueStmt(line: Int)
    case typeAlias(line: Int)
}

internal enum LuauCompoundOp {
    case add, sub, mul, div, idiv, mod, pow, concat
}

internal enum LuauLValue {
    case variable(String, line: Int)
    case index(table: LuauExpr, key: LuauExpr, line: Int)
    case member(table: LuauExpr, name: String, line: Int)
}

internal indirect enum LuauExpr {
    case `nil`(line: Int)
    case bool(Bool, line: Int)
    case number(Double, line: Int)
    case string(String, line: Int)
    case vararg(line: Int)
    case variable(String, line: Int)
    case table([(key: LuauExpr?, value: LuauExpr)], line: Int)
    case function(params: [String], isVariadic: Bool, body: [LuauStmt], line: Int)
    case unary(LuauUnaryOp, LuauExpr, line: Int)
    case binary(LuauBinaryOp, LuauExpr, LuauExpr, line: Int)
    case index(table: LuauExpr, key: LuauExpr, line: Int)
    case member(table: LuauExpr, name: String, line: Int)
    case call(callee: LuauExpr, args: [LuauExpr], line: Int)
    case methodCall(receiver: LuauExpr, method: String, args: [LuauExpr], line: Int)
    case ifExpr(branches: [(cond: LuauExpr, value: LuauExpr)], elseValue: LuauExpr, line: Int)
    case interpString(parts: [String], exprs: [LuauExpr], line: Int)
    case group(LuauExpr, line: Int) // `(expr)` — forces single return value in Lua!
}

internal enum LuauUnaryOp {
    case neg, not, len
}

internal enum LuauBinaryOp {
    case add, sub, mul, div, idiv, mod, pow, concat
    case eq, neq, lt, le, gt, ge
    case and, or
}
