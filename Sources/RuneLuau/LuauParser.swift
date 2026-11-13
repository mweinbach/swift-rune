import Foundation

internal final class LuauParser {
    private let sourceName: String
    private let tokens: [LuauToken]
    private var pos: Int = 0

    init(tokens: [LuauToken], sourceName: String = "chunk") {
        self.tokens = tokens
        self.sourceName = sourceName
    }

    func parseChunk() throws -> [LuauStmt] {
        let stmts = try parseBlock(until: { $0 == .eof })
        if current.kind != .eof {
            throw syntaxError("unexpected token '\(describe(current.kind))' near end of file", line: current.line)
        }
        return stmts
    }

    // MARK: - Cursor

    private var current: LuauToken {
        pos < tokens.count ? tokens[pos] : LuauToken(kind: .eof, line: 1, column: 1)
    }

    private func peek(_ offset: Int = 0) -> LuauToken {
        let i = pos + offset
        return i < tokens.count ? tokens[i] : LuauToken(kind: .eof, line: current.line, column: 1)
    }

    @discardableResult
    private func advance() -> LuauToken {
        let tok = current
        if pos < tokens.count { pos += 1 }
        return tok
    }

    private func match(_ kind: LuauTokenKind) -> Bool {
        if current.kind == kind {
            advance()
            return true
        }
        return false
    }

    private func expect(_ kind: LuauTokenKind, _ msg: String? = nil) throws -> LuauToken {
        if current.kind == kind {
            return advance()
        }
        throw syntaxError(msg ?? "expected '\(describe(kind))', got '\(describe(current.kind))'", line: current.line)
    }

    private func syntaxError(_ msg: String, line: Int) -> ScriptError {
        ScriptError(kind: .syntax, message: "\(sourceName):\(line): \(msg)")
    }

    // MARK: - Blocks & Statements

    private func parseBlock(until stop: (LuauTokenKind) -> Bool) throws -> [LuauStmt] {
        var stmts: [LuauStmt] = []
        while !stop(current.kind) && current.kind != .eof {
            if match(.semicolon) { continue }
            let stmt = try parseStatement()
            stmts.append(stmt)
            _ = match(.semicolon)
            if case .returnStmt = stmt {
                while match(.semicolon) {}
                break
            }
        }
        return stmts
    }

    private func isBlockEnd(_ kind: LuauTokenKind) -> Bool {
        switch kind {
        case .eof, .kwEnd, .kwElse, .kwElseif, .kwUntil:
            return true
        default:
            return false
        }
    }

    private func parseStatement() throws -> LuauStmt {
        let tok = current
        switch tok.kind {
        case .kwLocal:
            return try parseLocal()
        case .kwFunction:
            return try parseFunctionDecl()
        case .kwIf:
            return try parseIfStmt()
        case .kwWhile:
            return try parseWhileStmt()
        case .kwRepeat:
            return try parseRepeatStmt()
        case .kwFor:
            return try parseForStmt()
        case .kwDo:
            advance()
            let body = try parseBlock(until: isBlockEnd)
            _ = try expect(.kwEnd, "expected 'end' to close 'do'")
            return .block(body, line: tok.line)
        case .kwReturn:
            return try parseReturnStmt()
        case .kwBreak:
            advance()
            return .breakStmt(line: tok.line)
        case .identifier("continue"):
            if isContinueStatement() {
                advance()
                return .continueStmt(line: tok.line)
            }
            return try parseExprStatement()
        case .identifier("type"):
            if case .identifier = peek(1).kind {
                return try parseTypeAlias(exported: false)
            }
            return try parseExprStatement()
        case .identifier("export"):
            if case .identifier("type") = peek(1).kind, case .identifier = peek(2).kind {
                advance() // export
                return try parseTypeAlias(exported: true)
            }
            return try parseExprStatement()
        case .at:
            try skipAttributes()
            if current.kind == .kwFunction {
                return try parseFunctionDecl()
            } else if current.kind == .kwLocal && peek(1).kind == .kwFunction {
                return try parseLocal()
            }
            throw syntaxError("expected function declaration after attribute", line: current.line)
        default:
            return try parseExprStatement()
        }
    }

    private func skipAttributes() throws {
        while match(.at) {
            if current.kind == .lbracket {
                advance()
                var depth = 1
                while depth > 0 && current.kind != .eof {
                    if current.kind == .lbracket { depth += 1 }
                    else if current.kind == .rbracket { depth -= 1 }
                    advance()
                }
            } else if case .identifier = current.kind {
                advance()
                if current.kind == .lparen {
                    advance()
                    var depth = 1
                    while depth > 0 && current.kind != .eof {
                        if current.kind == .lparen { depth += 1 }
                        else if current.kind == .rparen { depth -= 1 }
                        advance()
                    }
                } else if current.kind == .lbrace {
                    advance()
                    var depth = 1
                    while depth > 0 && current.kind != .eof {
                        if current.kind == .lbrace { depth += 1 }
                        else if current.kind == .rbrace { depth -= 1 }
                        advance()
                    }
                } else if case .string = current.kind {
                    advance()
                } else if case .byteString = current.kind {
                    advance()
                }
            } else {
                throw syntaxError("expected attribute name after '@'", line: current.line)
            }
        }
    }

    private func isContinueStatement() -> Bool {
        switch peek(1).kind {
        case .assign, .plusAssign, .minusAssign, .starAssign, .slashAssign, .doubleSlashAssign, .percentAssign, .caretAssign, .dotDotAssign,
             .lparen, .lbrace, .lbracket, .dot, .colon, .comma, .string, .interpString:
            return false
        default:
            return true
        }
    }

    private func parseTypeAlias(exported: Bool) throws -> LuauStmt {
        let line = current.line
        advance() // 'type'
        guard case .identifier = current.kind else {
            throw syntaxError("expected type name", line: current.line)
        }
        advance() // name
        if current.kind == .lt {
            try skipGenericParams()
        }
        _ = try expect(.assign, "expected '=' in type alias")
        try skipTypeAnnotation()
        return .typeAlias(line: line)
    }

    private func parseLocal() throws -> LuauStmt {
        let line = advance().line // 'local'
        if match(.kwFunction) {
            guard case .identifier(let name) = current.kind else {
                throw syntaxError("expected function name", line: current.line)
            }
            advance()
            let (params, isVar, body) = try parseFuncBody()
            return .localFunction(name: name, params: params, isVariadic: isVar, body: body, line: line)
        }
        var names: [String] = []
        while true {
            guard case .identifier(let name) = current.kind else {
                throw syntaxError("expected variable name", line: current.line)
            }
            advance()
            names.append(name)
            if match(.colon) {
                try skipTypeAnnotation()
            }
            if !match(.comma) { break }
        }
        var values: [LuauExpr] = []
        if match(.assign) {
            values = try parseExprList()
        }
        return .localDecl(names: names, values: values, line: line)
    }

    private func parseFunctionDecl() throws -> LuauStmt {
        let line = advance().line // 'function'
        guard case .identifier(let first) = current.kind else {
            throw syntaxError("expected function name", line: current.line)
        }
        advance()
        var path = [first]
        while match(.dot) {
            guard case .identifier(let seg) = current.kind else {
                throw syntaxError("expected field name", line: current.line)
            }
            advance()
            path.append(seg)
        }
        var method: String? = nil
        if match(.colon) {
            guard case .identifier(let m) = current.kind else {
                throw syntaxError("expected method name", line: current.line)
            }
            advance()
            method = m
        }
        let (params, isVar, body) = try parseFuncBody()
        return .functionDecl(path: path, method: method, params: params, isVariadic: isVar, body: body, line: line)
    }

    private func parseFuncBody() throws -> ([String], Bool, [LuauStmt]) {
        if current.kind == .lt {
            try skipGenericParams()
        }
        _ = try expect(.lparen)
        var params: [String] = []
        var isVariadic = false
        if current.kind != .rparen {
            while true {
                if match(.dotDotDot) {
                    isVariadic = true
                    if match(.colon) {
                        try skipTypeAnnotation()
                    }
                    break
                }
                guard case .identifier(let name) = current.kind else {
                    throw syntaxError("expected parameter name", line: current.line)
                }
                advance()
                params.append(name)
                if match(.colon) {
                    try skipTypeAnnotation()
                }
                if !match(.comma) { break }
            }
        }
        _ = try expect(.rparen)
        if match(.colon) {
            try skipReturnTypeAnnotation()
        }
        let body = try parseBlock(until: isBlockEnd)
        _ = try expect(.kwEnd, "expected 'end' to close function")
        return (params, isVariadic, body)
    }

    private func parseIfStmt() throws -> LuauStmt {
        let line = advance().line // 'if'
        var branches: [(cond: LuauExpr, body: [LuauStmt])] = []
        let cond = try parseExpr()
        _ = try expect(.kwThen)
        let body = try parseBlock(until: isBlockEnd)
        branches.append((cond, body))
        while match(.kwElseif) {
            let econd = try parseExpr()
            _ = try expect(.kwThen)
            let ebody = try parseBlock(until: isBlockEnd)
            branches.append((econd, ebody))
        }
        var elseBody: [LuauStmt]? = nil
        if match(.kwElse) {
            elseBody = try parseBlock(until: isBlockEnd)
        }
        _ = try expect(.kwEnd, "expected 'end' to close 'if'")
        return .ifStmt(branches: branches, elseBody: elseBody, line: line)
    }

    private func parseWhileStmt() throws -> LuauStmt {
        let line = advance().line // 'while'
        let cond = try parseExpr()
        _ = try expect(.kwDo)
        let body = try parseBlock(until: isBlockEnd)
        _ = try expect(.kwEnd, "expected 'end' to close 'while'")
        return .whileStmt(cond: cond, body: body, line: line)
    }

    private func parseRepeatStmt() throws -> LuauStmt {
        let line = advance().line // 'repeat'
        let body = try parseBlock(until: isBlockEnd)
        _ = try expect(.kwUntil)
        let cond = try parseExpr()
        return .repeatStmt(body: body, cond: cond, line: line)
    }

    private func parseForStmt() throws -> LuauStmt {
        let line = advance().line // 'for'
        guard case .identifier(let first) = current.kind else {
            throw syntaxError("expected loop variable", line: current.line)
        }
        advance()
        if match(.colon) {
            try skipTypeAnnotation()
        }
        if match(.assign) {
            let start = try parseExpr()
            _ = try expect(.comma)
            let limit = try parseExpr()
            var step: LuauExpr? = nil
            if match(.comma) {
                step = try parseExpr()
            }
            _ = try expect(.kwDo)
            let body = try parseBlock(until: isBlockEnd)
            _ = try expect(.kwEnd, "expected 'end' to close 'for'")
            return .numericFor(varName: first, start: start, limit: limit, step: step, body: body, line: line)
        } else {
            var names = [first]
            while match(.comma) {
                guard case .identifier(let n) = current.kind else {
                    throw syntaxError("expected loop variable", line: current.line)
                }
                advance()
                if match(.colon) {
                    try skipTypeAnnotation()
                }
                names.append(n)
            }
            _ = try expect(.kwIn)
            let iters = try parseExprList()
            _ = try expect(.kwDo)
            let body = try parseBlock(until: isBlockEnd)
            _ = try expect(.kwEnd, "expected 'end' to close 'for'")
            return .genericFor(names: names, iterators: iters, body: body, line: line)
        }
    }

    private func parseReturnStmt() throws -> LuauStmt {
        let line = advance().line // 'return'
        var exprs: [LuauExpr] = []
        if !isBlockEnd(current.kind) && current.kind != .semicolon {
            exprs = try parseExprList()
        }
        return .returnStmt(exprs, line: line)
    }

    private func parseExprStatement() throws -> LuauStmt {
        let line = current.line
        let first = try parseSuffixedExpr()

        if let op = compoundOp(current.kind) {
            advance()
            let target = try toLValue(first)
            let rhs = try parseExpr()
            return .compoundAssign(target: target, op: op, value: rhs, line: line)
        }

        if current.kind == .comma || current.kind == .assign {
            var targets = [try toLValue(first)]
            while match(.comma) {
                let nextExpr = try parseSuffixedExpr()
                targets.append(try toLValue(nextExpr))
            }
            _ = try expect(.assign)
            let values = try parseExprList()
            return .assign(targets: targets, values: values, line: line)
        }

        switch first {
        case .call, .methodCall:
            return .call(first, line: line)
        default:
            throw syntaxError("syntax error near '\(describe(current.kind))'", line: line)
        }
    }

    private func compoundOp(_ kind: LuauTokenKind) -> LuauCompoundOp? {
        switch kind {
        case .plusAssign: return .add
        case .minusAssign: return .sub
        case .starAssign: return .mul
        case .slashAssign: return .div
        case .doubleSlashAssign: return .idiv
        case .percentAssign: return .mod
        case .caretAssign: return .pow
        case .dotDotAssign: return .concat
        default: return nil
        }
    }

    private func toLValue(_ expr: LuauExpr) throws -> LuauLValue {
        switch expr {
        case .variable(let name, let line): return .variable(name, line: line)
        case .index(let t, let k, let line): return .index(table: t, key: k, line: line)
        case .member(let t, let m, let line): return .member(table: t, name: m, line: line)
        default:
            throw syntaxError("invalid assignment target", line: current.line)
        }
    }

    // MARK: - Expressions

    private func parseExprList() throws -> [LuauExpr] {
        var list = [try parseExpr()]
        while match(.comma) {
            list.append(try parseExpr())
        }
        return list
    }

    private func parseExpr() throws -> LuauExpr {
        try parseSubExpr(minPrec: 0)
    }

    private func parseSubExpr(minPrec: Int) throws -> LuauExpr {
        var lhs = try parseUnaryOrSimple()
        while match(.doubleColon) {
            try skipTypeAnnotation()
        }
        while let (op, prec, rightAssoc) = binaryOp(current.kind), prec >= minPrec {
            let line = current.line
            advance()
            let nextMin = rightAssoc ? prec : prec + 1
            let rhs = try parseSubExpr(minPrec: nextMin)
            lhs = .binary(op, lhs, rhs, line: line)
            while match(.doubleColon) {
                try skipTypeAnnotation()
            }
        }
        return lhs
    }

    private func parseUnaryOrSimple() throws -> LuauExpr {
        let line = current.line
        switch current.kind {
        case .minus:
            advance()
            return .unary(.neg, try parseSubExpr(minPrec: 7), line: line)
        case .kwNot:
            advance()
            return .unary(.not, try parseSubExpr(minPrec: 7), line: line)
        case .hash:
            advance()
            return .unary(.len, try parseSubExpr(minPrec: 7), line: line)
        default:
            return try parseSuffixedExpr()
        }
    }

    private func binaryOp(_ kind: LuauTokenKind) -> (LuauBinaryOp, Int, Bool)? {
        switch kind {
        case .kwOr: return (.or, 1, false)
        case .kwAnd: return (.and, 2, false)
        case .lt: return (.lt, 3, false)
        case .gt: return (.gt, 3, false)
        case .le: return (.le, 3, false)
        case .ge: return (.ge, 3, false)
        case .neq: return (.neq, 3, false)
        case .eq: return (.eq, 3, false)
        case .dotDot: return (.concat, 4, true)
        case .plus: return (.add, 5, false)
        case .minus: return (.sub, 5, false)
        case .star: return (.mul, 6, false)
        case .slash: return (.div, 6, false)
        case .doubleSlash: return (.idiv, 6, false)
        case .percent: return (.mod, 6, false)
        case .caret: return (.pow, 8, true)
        default: return nil
        }
    }

    private func parseSuffixedExpr() throws -> LuauExpr {
        var expr = try parsePrimaryExpr()
        while true {
            let line = current.line
            switch current.kind {
            case .dot:
                advance()
                guard case .identifier(let name) = current.kind else {
                    throw syntaxError("expected field name after '.'", line: current.line)
                }
                advance()
                expr = .member(table: expr, name: name, line: line)
            case .lbracket:
                advance()
                let key = try parseExpr()
                _ = try expect(.rbracket)
                expr = .index(table: expr, key: key, line: line)
            case .colon:
                advance()
                guard case .identifier(let method) = current.kind else {
                    throw syntaxError("expected method name after ':'", line: current.line)
                }
                advance()
                let args = try parseCallArgs()
                expr = .methodCall(receiver: expr, method: method, args: args, line: line)
            case .lparen, .lbrace, .string:
                let args = try parseCallArgs()
                expr = .call(callee: expr, args: args, line: line)
            default:
                return expr
            }
        }
    }

    private func parseCallArgs() throws -> [LuauExpr] {
        switch current.kind {
        case .lparen:
            advance()
            if match(.rparen) { return [] }
            let list = try parseExprList()
            _ = try expect(.rparen)
            return list
        case .lbrace:
            return [try parseTableConstructor()]
        case .string(let s):
            let line = current.line
            advance()
            return [.string(s, line: line)]
        case .byteString(let bytes):
            let line = current.line
            advance()
            return [.byteString(bytes, line: line)]
        default:
            throw syntaxError("expected function arguments", line: current.line)
        }
    }

    private func parsePrimaryExpr() throws -> LuauExpr {
        let tok = current
        switch tok.kind {
        case .kwNil:
            advance(); return .nil(line: tok.line)
        case .kwTrue:
            advance(); return .bool(true, line: tok.line)
        case .kwFalse:
            advance(); return .bool(false, line: tok.line)
        case .number(let n):
            advance(); return .number(n, line: tok.line)
        case .string(let s):
            advance(); return .string(s, line: tok.line)
        case .byteString(let bytes):
            advance(); return .byteString(bytes, line: tok.line)
        case .dotDotDot:
            advance(); return .vararg(line: tok.line)
        case .identifier(let name):
            advance(); return .variable(name, line: tok.line)
        case .lparen:
            advance()
            let inner = try parseExpr()
            _ = try expect(.rparen)
            return .group(inner, line: tok.line)
        case .lbrace:
            return try parseTableConstructor()
        case .at:
            try skipAttributes()
            guard current.kind == .kwFunction else {
                throw syntaxError("expected 'function' after attribute", line: current.line)
            }
            let fnLine = current.line
            advance()
            let (params, isVar, body) = try parseFuncBody()
            return .function(params: params, isVariadic: isVar, body: body, line: fnLine)
        case .kwFunction:
            advance()
            let (params, isVar, body) = try parseFuncBody()
            return .function(params: params, isVariadic: isVar, body: body, line: tok.line)
        case .kwIf:
            return try parseIfExpr()
        case .interpString(let parts, let exprTokens):
            advance()
            var parsedExprs: [LuauExpr] = []
            for toks in exprTokens {
                let subParser = LuauParser(tokens: toks, sourceName: sourceName)
                let e = try subParser.parseExpr()
                if subParser.current.kind != .eof {
                    throw syntaxError("unexpected token in interpolated expression", line: tok.line)
                }
                parsedExprs.append(e)
            }
            return .interpString(parts: parts, exprs: parsedExprs, line: tok.line)
        default:
            throw syntaxError("unexpected symbol '\(describe(tok.kind))'", line: tok.line)
        }
    }

    private func parseIfExpr() throws -> LuauExpr {
        let line = advance().line // 'if'
        var branches: [(cond: LuauExpr, value: LuauExpr)] = []
        let cond = try parseExpr()
        _ = try expect(.kwThen)
        let val = try parseExpr()
        branches.append((cond, val))
        while match(.kwElseif) {
            let econd = try parseExpr()
            _ = try expect(.kwThen)
            let eval = try parseExpr()
            branches.append((econd, eval))
        }
        _ = try expect(.kwElse, "expected 'else' in if-expression")
        let elseVal = try parseExpr()
        return .ifExpr(branches: branches, elseValue: elseVal, line: line)
    }

    private func parseTableConstructor() throws -> LuauExpr {
        let line = advance().line // '{'
        var entries: [(key: LuauExpr?, value: LuauExpr)] = []
        while current.kind != .rbrace && current.kind != .eof {
            if match(.lbracket) {
                let key = try parseExpr()
                _ = try expect(.rbracket)
                _ = try expect(.assign)
                let val = try parseExpr()
                entries.append((key, val))
            } else if case .identifier(let name) = current.kind, peek(1).kind == .assign {
                let keyLine = current.line
                advance()
                advance() // '='
                let val = try parseExpr()
                entries.append((.string(name, line: keyLine), val))
            } else {
                let val = try parseExpr()
                entries.append((nil, val))
            }
            if !match(.comma) && !match(.semicolon) {
                break
            }
        }
        _ = try expect(.rbrace, "expected '}' to close table")
        return .table(entries, line: line)
    }

    // MARK: - Luau Type Annotation Skipper

    private func skipGenericParams() throws {
        _ = try expect(.lt)
        var depth = 1
        while depth > 0 && current.kind != .eof {
            if current.kind == .lt { depth += 1 }
            else if current.kind == .gt { depth -= 1 }
            advance()
        }
    }

    private func skipReturnTypeAnnotation() throws {
        // Function return types can be `(T1, T2)` or `T1` or `...T`
        try skipTypeAnnotation()
    }

    private func skipTypeAnnotation() throws {
        try skipSimpleType()
        while current.kind == .pipe || current.kind == .amp {
            advance()
            try skipSimpleType()
        }
    }

    private func skipSimpleType() throws {
        // Handle leading `|` or `&` in Luau multiline unions/intersections
        if current.kind == .pipe || current.kind == .amp {
            advance()
        }
        switch current.kind {
        case .kwNil, .kwTrue, .kwFalse, .string, .byteString:
            advance()
        case .dotDotDot:
            advance()
            try skipSimpleType()
        case .identifier(let name):
            advance()
            if name == "typeof" && current.kind == .lparen {
                advance()
                var depth = 1
                while depth > 0 && current.kind != .eof {
                    if current.kind == .lparen { depth += 1 }
                    else if current.kind == .rparen { depth -= 1 }
                    advance()
                }
            }
            if current.kind == .dot {
                while match(.dot) {
                    _ = advance()
                }
            }
            if current.kind == .lt {
                try skipTypeArguments()
            }
        case .lparen:
            advance()
            var depth = 1
            while depth > 0 && current.kind != .eof {
                if current.kind == .lparen { depth += 1 }
                else if current.kind == .rparen { depth -= 1 }
                advance()
            }
            if match(.arrow) {
                try skipTypeAnnotation()
            }
        case .lbrace:
            advance()
            var depth = 1
            while depth > 0 && current.kind != .eof {
                if current.kind == .lbrace { depth += 1 }
                else if current.kind == .rbrace { depth -= 1 }
                advance()
            }
        default:
            throw syntaxError("expected type annotation near '\(describe(current.kind))'", line: current.line)
        }
        if match(.question) {}
    }

    private func skipTypeArguments() throws {
        _ = try expect(.lt)
        var angleDepth = 1
        var parenDepth = 0
        var braceDepth = 0
        while angleDepth > 0 && current.kind != .eof {
            switch current.kind {
            case .lparen: parenDepth += 1
            case .rparen: parenDepth = max(0, parenDepth - 1)
            case .lbrace: braceDepth += 1
            case .rbrace: braceDepth = max(0, braceDepth - 1)
            case .lt where parenDepth == 0 && braceDepth == 0: angleDepth += 1
            case .gt where parenDepth == 0 && braceDepth == 0: angleDepth -= 1
            default: break
            }
            advance()
        }
    }

    private func describe(_ kind: LuauTokenKind) -> String {
        switch kind {
        case .eof: return "<eof>"
        case .identifier(let s): return s
        case .number(let n): return LuauValue.formatNumber(n)
        case .string(let s): return "\"\(s)\""
        case .interpString: return "`...`"
        case .kwAnd: return "and"
        case .kwBreak: return "break"
        case .kwDo: return "do"
        case .kwElse: return "else"
        case .kwElseif: return "elseif"
        case .kwEnd: return "end"
        case .kwFalse: return "false"
        case .kwFor: return "for"
        case .kwFunction: return "function"
        case .kwIf: return "if"
        case .kwIn: return "in"
        case .kwLocal: return "local"
        case .kwNil: return "nil"
        case .kwNot: return "not"
        case .kwOr: return "or"
        case .kwRepeat: return "repeat"
        case .kwReturn: return "return"
        case .kwThen: return "then"
        case .kwTrue: return "true"
        case .kwUntil: return "until"
        case .kwWhile: return "while"
        case .plus: return "+"
        case .minus: return "-"
        case .star: return "*"
        case .slash: return "/"
        case .doubleSlash: return "//"
        case .percent: return "%"
        case .caret: return "^"
        case .hash: return "#"
        case .eq: return "=="
        case .neq: return "~="
        case .lt: return "<"
        case .le: return "<="
        case .gt: return ">"
        case .ge: return ">="
        case .assign: return "="
        case .plusAssign: return "+="
        case .minusAssign: return "-="
        case .starAssign: return "*="
        case .slashAssign: return "/="
        case .doubleSlashAssign: return "//="
        case .percentAssign: return "%="
        case .caretAssign: return "^="
        case .dotDotAssign: return "..="
        case .lparen: return "("
        case .rparen: return ")"
        case .lbrace: return "{"
        case .rbrace: return "}"
        case .lbracket: return "["
        case .rbracket: return "]"
        case .semicolon: return ";"
        case .colon: return ":"
        case .doubleColon: return "::"
        case .comma: return ","
        case .dot: return "."
        case .dotDot: return ".."
        case .dotDotDot: return "..."
        case .arrow: return "->"
        case .pipe: return "|"
        case .amp: return "&"
        case .question: return "?"
        case .at: return "@"
        case .byteString: return "string"
        }
    }
}
