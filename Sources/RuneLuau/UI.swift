import Foundation
import Rune

/// Maps a colour token name to a `Color` for light or dark appearance.
public typealias Palette = @Sendable (_ name: String, _ dark: Bool) -> Color?

/// Maps an elevation name (`raised`, `floating`, `overlay`) to its shadows.
public typealias Shadows = @Sendable (_ name: String, _ dark: Bool) -> [Shadow]?

/// Rune's default `Tok.theme` colours under kebab-case names.
public func defaultPalette() -> Palette {
    let light = Tok.theme(dark: false)
    let dark = Tok.theme(dark: true)
    return { name, isDark in
        let t = isDark ? dark : light
        switch name {
        case "bg": return t.bg
        case "card": return t.card
        case "card-border": return t.cardBorder
        case "text": return t.text
        case "text-secondary": return t.textSecondary
        case "separator": return t.separator
        case "hover": return t.hover
        case "press": return t.press
        case "control-off": return t.controlOff
        case "control-track": return t.controlTrack
        case "indicator": return t.indicator
        case "selected": return t.hover
        default: return nil
        }
    }
}

/// One prop a host node received.
public enum Prop: @unchecked Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case data(LuauData)
    case function(Handler)
}

/// A script function a host node can run on press/hover.
public struct Handler: @unchecked Sendable {
    internal let fn: LuauValue
    internal let vmID: UInt64
    internal weak var script: Script?
}

/// A host-provided UI node constructor (`ui.<name>`).
public final class HostNode: @unchecked Sendable {
    public let name: String
    internal let build: @Sendable (NodeArgs) throws -> Any

    public init<State>(
        name: String,
        build: @escaping @Sendable (NodeArgs) throws -> El<State>
    ) {
        self.name = name
        self.build = { args in try build(args) }
    }
}

/// Arguments passed to a `HostNode` builder.
public final class NodeArgs: @unchecked Sendable {
    public let content: String?
    private let props: [(String, Prop)]
    private let rawChildren: [Any]
    private let env: UIRenderEnv
    private var usedKeys: Set<String> = []

    internal init(content: String?, props: [(String, Prop)], children: [Any], env: UIRenderEnv) {
        self.content = content
        self.props = props
        self.rawChildren = children
        self.env = env
    }

    public func children<State>(_ type: State.Type = State.self) -> [El<State>] {
        rawChildren.compactMap { $0 as? El<State> }
    }

    public func get(_ name: String) -> Prop? {
        guard let pair = props.last(where: { $0.0 == name }) else { return nil }
        usedKeys.insert(name)
        return pair.1
    }

    public func number(_ name: String) -> Double? {
        if case .number(let n) = get(name) { return n }
        return nil
    }

    public func string(_ name: String) -> String? {
        if case .string(let s) = get(name) { return s }
        return nil
    }

    public func flag(_ name: String) -> Bool {
        if case .bool(let b) = get(name) { return b }
        return false
    }

    public func data(_ name: String) -> LuauData? {
        guard let p = get(name) else { return nil }
        switch p {
        case .data(let d): return d
        case .string(let s): return .string(s)
        case .number(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .function: return nil
        }
    }

    public func color(_ name: String) -> Color? {
        guard let s = string(name) else { return nil }
        return try? env.resolveColor(s)
    }

    public func palette(_ name: String) -> Color? {
        env.palette(name, env.dark)
    }

    public var dark: Bool { env.dark }

    public func handler(_ name: String) -> Handler? {
        if case .function(let h) = get(name) { return h }
        return nil
    }

    internal func wasRead(_ name: String) -> Bool {
        usedKeys.contains(name)
    }
}

/// Active render environment for a `Script` render pass.
internal final class UIRenderEnv: @unchecked Sendable {
    weak var script: Script?
    let vmID: UInt64
    let salt: UInt64
    let version: UInt64
    let dark: Bool
    let palette: Palette
    let shadows: Shadows?
    let baseTextStyle: TextStyle
    let weights: [Float]
    let prefix: String
    var memoFailed: Bool = false

    init(
        script: Script?,
        vmID: UInt64,
        salt: UInt64,
        version: UInt64,
        dark: Bool,
        palette: @escaping Palette,
        shadows: Shadows?,
        baseTextStyle: TextStyle,
        weights: [Float],
        prefix: String
    ) {
        self.script = script
        self.vmID = vmID
        self.salt = salt
        self.version = version
        self.dark = dark
        self.palette = palette
        self.shadows = shadows
        self.baseTextStyle = baseTextStyle
        self.weights = weights
        self.prefix = prefix
    }

    func resolveColor(_ token: String) throws -> Color {
        if token.hasPrefix("#") {
            if let c = Color.hex(token) {
                return c
            }
            throw LuauRuntimeError(value: .string("invalid hex color '\(token)'"))
        }
        if let c = palette(token, dark) {
            return c
        }
        throw LuauRuntimeError(value: .string("unknown color token '\(token)'"))
    }

    var defaultTextColor: Color {
        palette("text", dark) ?? (dark ? .white : .black)
    }
}

/// Box stored inside a `LuauUserdata` representing a built `El<State>`.
internal final class LuauElBox<State>: @unchecked Sendable {
    let element: El<State>
    init(_ element: El<State>) { self.element = element }
}

/// Helper protocol so `Script` and `UI` can install `@rune/ui` for a specific `State`.
internal enum LuauUIBridge {
    @discardableResult
    static func install<State>(
        into vm: LuauVM,
        stateType: State.Type,
        table existingTable: LuauTable? = nil,
        hostNodes: [HostNode],
        currentEnv: @escaping @Sendable () -> UIRenderEnv?
    ) -> LuauTable {
        let ui = existingTable ?? LuauTable()

        ui.rawSet("hex", value: .nativeFunction(LuauNativeFunction(name: "ui.hex") { _, _, args in
            guard case .string(let s) = args.first, s.hasPrefix("#"), (s.count == 7 || s.count == 9), Color.hex(s) != nil else {
                throw LuauRuntimeError(value: .string("ui.hex needs \"#RRGGBB\" or \"#RRGGBBAA\""))
            }
            return .values([.string(s)])
        }))

        func makeContainer(_ name: String, base: @escaping @Sendable () -> El<State>) -> LuauValue {
            .nativeFunction(LuauNativeFunction(name: "ui.\(name)") { _, _, args in
                guard let env = currentEnv() else {
                    throw LuauRuntimeError(value: .string("ui nodes can only be built while rendering"))
                }
                let (layers, childrenVal) = parseContainerArgs(args)
                var el = base()
                el = try applyProps(layers, to: el, isText: false, env: env)
                if let childrenVal {
                    let kids = try extractChildren(childrenVal, State.self, env: env)
                    el = el.children(kids)
                }
                return .values([.userdata(LuauUserdata(payload: LuauElBox(el), typeTag: "El"))])
            })
        }

        ui.rawSet("row", value: makeContainer("row") { Rune.row() as El<State> })
        ui.rawSet("col", value: makeContainer("col") { Rune.col() as El<State> })
        ui.rawSet("box", value: makeContainer("box") { Rune.el() as El<State> })
        ui.rawSet("spacer", value: makeContainer("spacer") { Rune.spacer() as El<State> })

        ui.rawSet("text", value: .nativeFunction(LuauNativeFunction(name: "ui.text") { _, _, args in
            guard let env = currentEnv() else {
                throw LuauRuntimeError(value: .string("ui.text can only be built while rendering"))
            }
            guard let first = args.first else {
                throw LuauRuntimeError(value: .string("ui.text needs a string"))
            }
            let (layers, valueStartIdx) = parseTextArgs(args)
            let template: String
            switch first {
            case .string(let s): template = s
            case .number(let n): template = LuauValue.formatNumber(n)
            default: throw LuauRuntimeError(value: .string("ui.text needs a string, got \(first.typeName)"))
            }
            let content = try interpolateText(template, values: Array(args.dropFirst(valueStartIdx)))
            var el = Rune.text(content) as El<State>
            el = try applyProps(layers, to: el, isText: true, env: env)
            return .values([.userdata(LuauUserdata(payload: LuauElBox(el), typeTag: "El"))])
        }))

        ui.rawSet("each", value: .nativeFunction(LuauNativeFunction(name: "ui.each") { vm, _, args in
            guard let env = currentEnv() else {
                throw LuauRuntimeError(value: .string("ui.each can only be called while rendering"))
            }
            guard args.count >= 4, case .table(let items) = args[0] else {
                throw LuauRuntimeError(value: .string("ui.each needs items, key, version, build"))
            }
            let keyBy = args[1]
            let versionBy = args[2]
            let buildFn = args[3]
            let len = items.rawLength
            let out = LuauTable(arrayCapacity: len)

            for i in 1...max(1, len) {
                if i > len { break }
                let item = items.rawGet(i)
                let keyVal: LuauValue
                if case .string(let field) = keyBy, case .table(let it) = item {
                    keyVal = it.rawGet(field)
                } else {
                    keyVal = try vm.call(value: keyBy, args: [item, .number(Double(i))]).first ?? .nil
                }
                let itemKey = keyVal.displayString

                let verVal: LuauValue
                if case .string(let field) = versionBy, case .table(let it) = item {
                    verVal = it.rawGet(field)
                } else {
                    verVal = try vm.call(value: versionBy, args: [item, .number(Double(i))]).first ?? .nil
                }
                let verHash = mixHash(versionHash(verVal), env.salt)
                let built = Rune.memo("\(env.prefix)\(itemKey)", deps: verHash) { () -> El<State> in
                    do {
                        let res = try vm.call(value: buildFn, args: [item, .number(Double(i))]).first ?? .nil
                        return try unwrapEl(res, State.self).key(itemKey)
                    } catch {
                        env.memoFailed = true
                        return Rune.el() as El<State>
                    }
                }
                out.array.append(.userdata(LuauUserdata(payload: LuauElBox(built), typeTag: "El")))
            }
            return .values([.table(out)])
        }))

        ui.rawSet("virtualList", value: .nativeFunction(LuauNativeFunction(name: "ui.virtualList") { vm, _, args in
            guard let env = currentEnv() else {
                throw LuauRuntimeError(value: .string("ui.virtualList can only be built while rendering"))
            }
            guard case .table(let props) = args.first else {
                throw LuauRuntimeError(value: .string("ui.virtualList needs a props table"))
            }
            let count = max(0, props.rawGet("count").asInt ?? 0)
            let estimate = Float(max(1.0, props.rawGet("estimatedRowHeight").coercedNumber ?? 32.0))
            let renderRow = props.rawGet("renderRow")
            guard !renderRow.isNil else {
                throw LuauRuntimeError(value: .string("ui.virtualList needs renderRow"))
            }
            let rowKeyFn = props.rawGet("rowKey")
            let gap = Float(props.rawGet("gap").coercedNumber ?? 0.0)
            let keyStr = props.rawGet("key").isNil ? "list" : props.rawGet("key").displayString
            let listVersionVal = props.rawGet("version")
            let listVersion = mixHash(listVersionVal.isNil ? env.version : versionHash(listVersionVal), env.salt)
            let rowVersionsTbl = props.rawGet("rowVersions").asTable
            let ownScroll = props.rawGet("scrollY").asBool ?? true

            let listState = env.script?.virtualListState(forKey: keyStr) ?? VirtualListState()
            let rowCount = count

            var listEl: El<State> = Rune.virtualRows(
                key: "\(env.prefix)\(keyStr)",
                state: listState,
                count: rowCount,
                estimatedHeight: estimate,
                scrollY: 0,
                viewportHeight: 600,
                rowKey: { idx in
                    if !rowKeyFn.isNil {
                        if let k = try? vm.call(value: rowKeyFn, args: [.number(Double(idx + 1))]).first {
                            return k.displayString
                        }
                    }
                    return String(idx)
                },
                buildRow: { idx in
                    let rowVer = rowVersionsTbl.map { mixHash(versionHash($0.rawGet(idx + 1)), listVersion) } ?? listVersion
                    let rowID = "\(env.prefix)\(keyStr)/row/\(idx)"
                    return Rune.memo(rowID, deps: rowVer) {
                        do {
                            let res = try vm.call(value: renderRow, args: [.number(Double(idx + 1))]).first ?? .nil
                            return try unwrapEl(res, State.self)
                        } catch {
                            return LuauCard.rowError(message: error.localizedDescription)
                        }
                    }
                }
            ).gap(gap).wFull()

            if ownScroll {
                listEl = listEl.scrollY()
            }
            // Apply standard container props (excluding virtualList-specific keys)
            let skipKeys: Set<String> = ["count", "estimatedRowHeight", "renderRow", "rowKey", "version", "rowVersions", "onVisibleRows", "onPress", "scrollY"]
            listEl = try applyProps([props], to: listEl, isText: false, env: env, skipKeys: skipKeys)
            return .values([.userdata(LuauUserdata(payload: LuauElBox(listEl), typeTag: "El"))])
        }))

        // Host nodes
        for node in hostNodes {
            ui.rawSet(node.name, value: .nativeFunction(LuauNativeFunction(name: "ui.\(node.name)") { _, _, args in
                guard let env = currentEnv() else {
                    throw LuauRuntimeError(value: .string("ui.\(node.name) can only be built while rendering"))
                }
                let nodeArgs = try buildHostNodeArgs(args, State.self, env: env)
                guard let built = try node.build(nodeArgs) as? El<State> else {
                    throw LuauRuntimeError(value: .string("ui.\(node.name) returned wrong El<State> type"))
                }
                return .values([.userdata(LuauUserdata(payload: LuauElBox(built), typeTag: "El"))])
            }))
        }

        vm.registeredModules["@rune/ui"] = .table(ui)
        return ui
    }

    static func makeViewTable<State>(
        for vm: LuauVM,
        stateType: State.Type,
        currentEnv: @escaping @Sendable () -> UIRenderEnv?
    ) -> LuauTable {
        let view = LuauTable()
        view.rawSet("dark", value: .bool(false))
        view.rawSet("Memo", value: .nativeFunction(LuauNativeFunction(name: "view:Memo") { vm, _, args in
            guard let env = currentEnv() else {
                throw LuauRuntimeError(value: .string("view:Memo can only be called while rendering"))
            }
            guard args.count >= 4 else {
                throw LuauRuntimeError(value: .string("view:Memo needs (key, version, build)"))
            }
            let keyStr = args[1].displayString
            let ver = mixHash(versionHash(args[2]), env.salt)
            let buildFn = args[3]
            let memoID = "\(env.prefix)\(keyStr)"
            var capturedError: Error?
            let el = Rune.memo(memoID, deps: ver) { () -> El<State> in
                do {
                    let res = try vm.call(value: buildFn, args: []).first ?? .nil
                    let built = try unwrapEl(res, State.self)
                    return built.keyId == nil ? built.key(memoID) : built
                } catch {
                    capturedError = error
                    env.memoFailed = true
                    return Rune.el() as El<State>
                }
            }
            if let capturedError {
                throw capturedError
            }
            return .values([.userdata(LuauUserdata(payload: LuauElBox(el), typeTag: "El"))])
        }))

        view.rawSet("Handler", value: .nativeFunction(LuauNativeFunction(name: "view:Handler") { _, _, args in
            return .values([args.count > 1 ? args[1] : .nil])
        }))

        return view
    }

    static func unwrapEl<State>(_ val: LuauValue, _ type: State.Type) throws -> El<State> {
        if val.isNil { return Rune.el() as El<State> }
        if case .userdata(let u) = val, let box = u.payload as? LuauElBox<State> {
            return box.element
        }
        throw LuauRuntimeError(value: .string("expected a ui node, got \(val.typeName)"))
    }

    // MARK: - Helpers

    private static func isKeyedTable(_ val: LuauValue) -> Bool {
        guard case .table(let t) = val else { return false }
        return !t.hash.isEmpty || t.rawLength == 0
    }

    private static func parseContainerArgs(_ args: [LuauValue]) -> ([LuauTable], LuauValue?) {
        let t0 = args.count > 0 ? args[0] : .nil
        let t1 = args.count > 1 ? args[1] : .nil
        let t2 = args.count > 2 ? args[2] : .nil

        if case .table(let p0) = t0 {
            if case .table(let p1) = t1 {
                if case .table = t2 {
                    return ([p0, p1], t2)
                }
                if isKeyedTable(t1) {
                    return ([p0, p1], nil)
                }
                return ([p0], t1)
            }
            if t1.isNil, case .table = t2 {
                return ([p0], t2)
            }
            if isKeyedTable(t0) {
                return ([p0], nil)
            }
            return ([], t0)
        }
        if t0.isNil, case .table = t1 {
            return ([], t1)
        }
        return ([], nil)
    }

    private static func parseTextArgs(_ args: [LuauValue]) -> ([LuauTable], Int) {
        let a1 = args.count > 1 ? args[1] : .nil
        let a2 = args.count > 2 ? args[2] : .nil
        if case .table(let t1) = a1 {
            if case .table(let t2) = a2 {
                return ([t1, t2], 3)
            }
            if a2.isNil {
                return ([t1], 3)
            }
            return ([t1], 2)
        }
        if a1.isNil, case .table(let t2) = a2 {
            return ([t2], 3)
        }
        if a1.isNil {
            return ([], 2)
        }
        return ([], 1)
    }

    private static func interpolateText(_ template: String, values: [LuauValue]) throws -> String {
        if values.isEmpty { return template }
        var out = ""
        var i = template.startIndex
        while i < template.endIndex {
            if template[i] == "{" {
                let after = template.index(after: i)
                var j = after
                while j < template.endIndex && template[j].isNumber {
                    j = template.index(after: j)
                }
                if j > after && j < template.endIndex && template[j] == "}" {
                    if let n = Int(template[after..<j]), n >= 1 && n <= values.count {
                        out += values[n - 1].displayString
                        i = template.index(after: j)
                        continue
                    } else {
                        throw LuauRuntimeError(value: .string("ui.text: placeholder has no value"))
                    }
                }
            }
            out.append(template[i])
            i = template.index(after: i)
        }
        return out
    }

    private static func extractChildren<State>(_ val: LuauValue, _ type: State.Type, env: UIRenderEnv) throws -> [El<State>] {
        guard case .table(let t) = val else { return [] }
        var result: [El<State>] = []
        let len = t.rawLength
        for i in 1...max(1, len) {
            if i > len { break }
            let item = t.rawGet(i)
            switch item {
            case .nil:
                continue
            case .string(let s):
                result.append((Rune.text(s) as El<State>).font(env.baseTextStyle).color(env.defaultTextColor))
            case .userdata(let u):
                if let box = u.payload as? LuauElBox<State> {
                    result.append(box.element)
                }
            case .table:
                result.append(contentsOf: try extractChildren(item, State.self, env: env))
            default:
                throw LuauRuntimeError(value: .string("ui child must be a node or string, got \(item.typeName)"))
            }
        }
        return result
    }

    private static func buildHostNodeArgs<State>(_ args: [LuauValue], _ type: State.Type, env: UIRenderEnv) throws -> NodeArgs {
        var idx = 0
        var content: String? = nil
        if idx < args.count, case .string(let s) = args[idx] {
            content = s
            idx += 1
        }
        var props: [(String, Prop)] = []
        func collectProps(_ tbl: LuauTable) {
            for hk in tbl.hashOrder {
                guard case .string(let k) = hk, let v = tbl.hash[hk], !v.isNil else { continue }
                let prop: Prop? = switch v {
                case .bool(let b): .bool(b)
                case .number(let n): .number(n)
                case .string(let s): .string(s)
                case .table: .data(LuauData.fromLuau(v))
                case .closure, .nativeFunction:
                    .function(Handler(fn: v, vmID: env.vmID, script: env.script))
                default: nil
                }
                if let prop { props.append((k, prop)) }
            }
        }
        if idx < args.count, case .table(let p1) = args[idx] {
            collectProps(p1)
            idx += 1
            if idx < args.count, case .table(let p2) = args[idx], isKeyedTable(.table(p2)) {
                collectProps(p2)
                idx += 1
            }
        }
        var kids: [Any] = []
        if idx < args.count {
            let cVal = args[idx]
            if case .userdata(let u) = cVal, let box = u.payload as? LuauElBox<State> {
                kids = [box.element]
            } else if case .table = cVal {
                kids = try extractChildren(cVal, State.self, env: env)
            }
        }
        return NodeArgs(content: content, props: props, children: kids, env: env)
    }

    private static func applyProps<State>(
        _ tables: [LuauTable],
        to element: El<State>,
        isText: Bool,
        env: UIRenderEnv,
        skipKeys: Set<String> = []
    ) throws -> El<State> {
        var el = element
        var keyStr: String? = nil
        var padAll: Float? = nil
        var padSides: UInt8 = 0
        var borderWidth: Float? = nil
        var borderColor: Color? = nil
        var textStyle = env.baseTextStyle
        var textColor: Color? = nil
        var scrollX = false
        var scrollY = false
        var stickBottom = false
        var onPressVal: LuauValue? = nil
        var onHoverVal: LuauValue? = nil
        var isDisabled = false

        func num(_ v: LuauValue, _ name: String) throws -> Float {
            guard let d = v.coercedNumber else {
                throw LuauRuntimeError(value: .string("\(name) must be a number, got \(v.typeName)"))
            }
            return Float(d)
        }

        for tbl in tables {
            for hk in tbl.hashOrder {
                guard case .string(let k) = hk, let v = tbl.hash[hk], !v.isNil else { continue }
                if skipKeys.contains(k) { continue }
                switch k {
                case "key": keyStr = v.displayString
                case "w":
                    if case .string("full") = v { el = el.wFull() }
                    else { el = el.w(try num(v, "w")) }
                case "h":
                    if case .string("full") = v { el = el.hFull() }
                    else { el = el.h(try num(v, "h")) }
                case "minW": el = el.minW(try num(v, k))
                case "maxW": el = el.maxW(try num(v, k))
                case "minH": el = el.minH(try num(v, k))
                case "maxH": el = el.maxH(try num(v, k))
                case "grow": el = el.grow(try num(v, k))
                case "shrink": if v.isTruthy { el = el.shrink(1) } else { el = el.shrink(0) }
                case "pad": padAll = try num(v, k)
                case "px":
                    let n = try num(v, k)
                    el = el.px(n)
                    padSides |= 0b1010
                case "py":
                    let n = try num(v, k)
                    el = el.py(n)
                    padSides |= 0b0101
                case "pt": el = el.pt(try num(v, k)); padSides |= 0b0001
                case "pr": el = el.pr(try num(v, k)); padSides |= 0b0010
                case "pb": el = el.pb(try num(v, k)); padSides |= 0b0100
                case "pl": el = el.pl(try num(v, k)); padSides |= 0b1000
                case "m": el = el.m(try num(v, k))
                case "mx": el = el.mx(try num(v, k))
                case "my": el = el.my(try num(v, k))
                case "mt": el = el.mt(try num(v, k))
                case "mr": el = el.mr(try num(v, k))
                case "mb": el = el.mb(try num(v, k))
                case "ml": el = el.ml(try num(v, k))
                case "opacity": el = el.opacity(try num(v, k))
                case "label": if let s = v.asString { el = el.label(s) }
                case "help": if let s = v.asString { el = el.help(s) }
                case "gap": el = el.gap(try num(v, k))
                case "align":
                    switch v.asString {
                    case "start": el = el.itemsStart()
                    case "center": el = el.itemsCenter()
                    case "end": el = el.itemsEnd()
                    case "stretch": el = el.itemsStretch()
                    default: throw LuauRuntimeError(value: .string("invalid align '\(v.displayString)'"))
                    }
                case "justify":
                    switch v.asString {
                    case "start": el = el.justifyStart()
                    case "center": el = el.justifyCenter()
                    case "end": el = el.justifyEnd()
                    case "between": el = el.justifyBetween()
                    default: throw LuauRuntimeError(value: .string("invalid justify '\(v.displayString)'"))
                    }
                case "center": if v.isTruthy { el = el.center() }
                case "wrap":
                    if !isText && v.isTruthy { el = el.flexWrap(true) }
                case "fill":
                    if let s = v.asString { el = el.bg(try env.resolveColor(s)) }
                case "hover":
                    if let s = v.asString { el = el.hover(try env.resolveColor(s)) }
                case "press":
                    if let s = v.asString { el = el.press(try env.resolveColor(s)) }
                case "border":
                    if let s = v.asString { borderColor = try env.resolveColor(s) }
                case "borderWidth":
                    borderWidth = try num(v, k)
                case "radius":
                    el = el.rounded(try num(v, k))
                case "corners":
                    if case .table(let ct) = v {
                        let c0 = Float(ct.rawGet(1).coercedNumber ?? 0)
                        let c1 = Float(ct.rawGet(2).coercedNumber ?? 0)
                        let c2 = Float(ct.rawGet(3).coercedNumber ?? 0)
                        let c3 = Float(ct.rawGet(4).coercedNumber ?? 0)
                        el = el.corners(c0, c1, c2, c3)
                    }
                case "clip":
                    if v.isTruthy { el = el.clip(true) }
                case "scrollY":
                    if v.isTruthy { scrollY = true }
                case "scrollX":
                    if v.isTruthy { scrollX = true }
                case "stickBottom":
                    stickBottom = v.isTruthy
                case "pin":
                    if case .table(let pt) = v {
                        el = el.pin(
                            top: pt.rawGet("top").coercedNumber.map { Float($0) },
                            right: pt.rawGet("right").coercedNumber.map { Float($0) },
                            bottom: pt.rawGet("bottom").coercedNumber.map { Float($0) },
                            left: pt.rawGet("left").coercedNumber.map { Float($0) }
                        )
                    }
                case "color":
                    if let s = v.asString { textColor = try env.resolveColor(s) }
                case "size":
                    textStyle.size = try num(v, k)
                case "weight":
                    switch v.asString {
                    case "regular": textStyle.weight = env.weights[0]
                    case "medium": textStyle.weight = env.weights[1]
                    case "semibold": textStyle.weight = env.weights[2]
                    case "bold": textStyle.weight = env.weights[3]
                    default: textStyle.weight = try num(v, k)
                    }
                case "lineHeight":
                    textStyle.lineHeight = try num(v, k)
                case "tracking":
                    textStyle.letterSpacing = try num(v, k)
                case "mono":
                    if v.isTruthy { textStyle.family = .monospace }
                case "noWrap":
                    if v.isTruthy { textStyle.wrap = .noWrap }
                case "truncate":
                    if v.isTruthy { textStyle.wrap = .ellipsis }
                case "textAlign":
                    switch v.asString {
                    case "start": textStyle.align = .leading
                    case "center": textStyle.align = .center
                    case "end": textStyle.align = .trailing
                    default: break
                    }
                case "focusable":
                    if v.isTruthy { el = el.focusable(true) }
                case "disabled":
                    isDisabled = v.isTruthy
                case "selected":
                    if v.isTruthy, let c = env.palette("selected", env.dark) {
                        el = el.bg(c)
                    }
                case "shadow":
                    if let s = v.asString, let list = env.shadows?(s, env.dark) {
                        el = el.shadows(list)
                    }
                case "onPress":
                    onPressVal = v
                case "onHover":
                    onHoverVal = v
                case "role":
                    if let s = v.asString, let r = ElementRole(rawValue: s) {
                        el = el.role(r)
                    }
                default:
                    break
                }
            }
        }

        if let p = padAll {
            if padSides == 0 {
                el = el.p(p)
            } else {
                if (padSides & 0b0001) == 0 { el = el.pt(p) }
                if (padSides & 0b0010) == 0 { el = el.pr(p) }
                if (padSides & 0b0100) == 0 { el = el.pb(p) }
                if (padSides & 0b1000) == 0 { el = el.pl(p) }
            }
        }
        if borderWidth != nil || borderColor != nil {
            let c = borderColor ?? env.palette("separator", env.dark) ?? .transparent
            el = el.border(borderWidth ?? 1.0, c)
        }
        if scrollX && scrollY {
            el = el.scrollXY()
        } else if scrollX {
            el = el.scrollX()
        } else if scrollY {
            el = el.scrollY(stickBottom: stickBottom)
        }
        if isText {
            el = el.font(textStyle).color(textColor ?? env.defaultTextColor)
        } else if let c = textColor {
            el = el.color(c)
        }
        if let k = keyStr {
            el = el.key(k)
        }
        if let onPressVal, !isDisabled {
            let capturedKey = keyStr
            let scriptRef = env.script
            let vmID = env.vmID
            el = el.onClick { _, tx in
                guard let script = scriptRef else { return }
                let ev = LuauTable()
                ev.rawSet("kind", value: .string("press"))
                if let capturedKey { ev.rawSet("key", value: .string(capturedKey)) }
                ev.rawSet("shift", value: .bool(false))
                ev.rawSet("alt", value: .bool(false))
                ev.rawSet("mod", value: .bool(false))
                script.handleCallback(fn: onPressVal, vmID: vmID, event: .table(ev), tx: &tx)
            }
        }
        if let onHoverVal {
            let capturedKey = keyStr
            let scriptRef = env.script
            let vmID = env.vmID
            el = el.onHover { _, entered, tx in
                guard let script = scriptRef else { return }
                let ev = LuauTable()
                ev.rawSet("kind", value: .string("hover"))
                if let capturedKey { ev.rawSet("key", value: .string(capturedKey)) }
                ev.rawSet("entered", value: .bool(entered))
                script.handleCallback(fn: onHoverVal, vmID: vmID, event: .table(ev), tx: &tx)
            }
        }
        return el
    }

    private static func versionHash(_ val: LuauValue) -> UInt64 {
        var h = Hasher()
        switch val {
        case .nil: h.combine(UInt8(0))
        case .bool(let b): h.combine(UInt8(1)); h.combine(b)
        case .number(let n): h.combine(UInt8(2)); h.combine(n.bitPattern)
        case .string(let s): h.combine(UInt8(3)); h.combine(s)
        default: h.combine(UInt8(4)); h.combine(val.displayString)
        }
        return UInt64(bitPattern: Int64(h.finalize()))
    }

    private static func mixHash(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var h = Hasher()
        h.combine(a)
        h.combine(b)
        return UInt64(bitPattern: Int64(h.finalize()))
    }
}
