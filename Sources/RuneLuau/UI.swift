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
/// Modifier key state delivered to `NodeArgs.onPress` / `NodeArgs.onPressWith` callbacks.
public struct Press: Sendable, Equatable {
    public var key: String?
    public var shift: Bool
    public var alt: Bool
    public var mod: Bool

    public init(key: String? = nil, shift: Bool = false, alt: Bool = false, mod: Bool = false) {
        self.key = key
        self.shift = shift
        self.alt = alt
        self.mod = mod
    }
}

public struct Handler: @unchecked Sendable {
    internal let fn: LuauValue
    internal let vmID: UInt64
    internal weak var script: Script?

    internal init(fn: LuauValue, vmID: UInt64, script: Script?) {
        self.fn = fn
        self.vmID = vmID
        self.script = script
    }
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
    internal let rawProps: [(String, LuauValue)]
    private let rawChildren: [Any]
    internal let env: UIRenderEnv
    private var usedKeys: Set<String> = []

    internal init(
        content: String?,
        props: [(String, Prop)],
        rawProps: [(String, LuauValue)] = [],
        children: [Any],
        env: UIRenderEnv
    ) {
        self.content = content
        self.props = props
        self.rawProps = rawProps
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

    /// Builds an `El` click callback invoking a Luau `Handler` with press event details.
    public func onPress<State>(_ type: State.Type = State.self, handler: Handler) -> (@Sendable (inout State, inout Tx) -> Void) {
        onPressWith(type, handler: handler, key: string("key"))
    }

    /// Builds an `El` click callback invoking a Luau `Handler` with an explicit key and modifier state.
    public func onPressWith<State>(
        _ type: State.Type = State.self,
        handler: Handler,
        key: String? = nil,
        press: Press? = nil
    ) -> (@Sendable (inout State, inout Tx) -> Void) {
        let vmID = handler.vmID
        let fn = handler.fn
        let script = handler.script
        return { state, tx in
            guard let script else { return }
            let mods = script.consumePressMods()
            let m = script.pressEventMods(mods)
            let p = press ?? Press(key: key, shift: m.shift, alt: m.alt, mod: m.mod)
            let ev = LuauTable()
            ev.rawSet("kind", value: .string("press"))
            if let k = p.key ?? key { ev.rawSet("key", value: .string(k)) }
            ev.rawSet("shift", value: .bool(p.shift))
            ev.rawSet("alt", value: .bool(p.alt))
            ev.rawSet("mod", value: .bool(p.mod))
            script.aroundWrite(state: &state, tx: &tx) { tx in
                script.enter(tx: &tx) {
                    try script.callHandlerIfCurrent(vmID: vmID, fn: fn, arg: .table(ev))
                }
            }
        }
    }

    /// Invokes a Luau `Handler` asynchronously without an active `Tx`.
    public func pressLater(handler: Handler, press: Press = Press()) {
        guard let script = handler.script else { return }
        let ev = LuauTable()
        ev.rawSet("kind", value: .string("press"))
        if let k = press.key { ev.rawSet("key", value: .string(k)) }
        ev.rawSet("shift", value: .bool(press.shift))
        ev.rawSet("alt", value: .bool(press.alt))
        ev.rawSet("mod", value: .bool(press.mod))
        var dummyState: Any = ()
        script.aroundWriteOptional(state: &dummyState, tx: nil) { _ in
            script.enter {
                try script.callHandlerIfCurrent(vmID: handler.vmID, fn: handler.fn, arg: .table(ev))
            }
        }
    }

    /// Builds an `El` hover callback invoking a Luau `Handler`.
    public func onHover<State>(_ type: State.Type = State.self, handler: Handler) -> (@Sendable (inout State, Bool, inout Tx) -> Void) {
        let vmID = handler.vmID
        let fn = handler.fn
        let script = handler.script
        let capturedKey = string("key")
        return { state, entered, tx in
            guard let script else { return }
            let ev = LuauTable()
            ev.rawSet("kind", value: .string("hover"))
            if let capturedKey { ev.rawSet("key", value: .string(capturedKey)) }
            ev.rawSet("entered", value: .bool(entered))
            script.aroundWrite(state: &state, tx: &tx) { tx in
                script.enter(tx: &tx) {
                    try script.callHandlerIfCurrent(vmID: vmID, fn: fn, arg: .table(ev))
                }
            }
        }
    }

    internal func wasRead(_ name: String) -> Bool {
        usedKeys.contains(name)
    }
}

/// Active render environment for a `Script` render pass.
internal final class UIRenderEnv: @unchecked Sendable {
    private static let nextEpochLock = NSLock()
    nonisolated(unsafe) private static var nextEpoch: UInt64 = 1

    private static func allocEpoch() -> UInt64 {
        nextEpochLock.lock()
        defer { nextEpochLock.unlock() }
        let e = nextEpoch
        nextEpoch += 1
        return e
    }

    weak var script: Script?
    let vmID: UInt64
    let salt: UInt64
    let version: UInt64
    let dark: Bool
    let viewport: Vec2
    let scrollLookup: ((String) -> Vec2)?
    let palette: Palette
    let shadows: Shadows?
    let baseTextStyle: TextStyle
    let weights: [Float]
    let prefix: String
    let renderEpoch: UInt64
    var memoFailed: Bool = false
    var trackedScrollKeys: [String] = []
    private var colorCache: [String: Color] = [:]

    init(
        script: Script?,
        vmID: UInt64,
        salt: UInt64,
        version: UInt64,
        dark: Bool,
        viewport: Vec2 = .zero,
        scrollLookup: ((String) -> Vec2)? = nil,
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
        self.viewport = viewport
        self.scrollLookup = scrollLookup
        self.palette = palette
        self.shadows = shadows
        self.baseTextStyle = baseTextStyle
        self.weights = weights
        self.prefix = prefix
        self.renderEpoch = Self.allocEpoch()
    }

    func warnOnce(_ message: String) {
        script?.warnOnce(message)
    }

    func resolveColor(_ token: String) throws -> Color {
        if token.hasPrefix("#") {
            if let c = Color.hex(token) {
                return c
            }
            throw LuauRuntimeError(value: .string("\(token) is not a #rrggbb or #rrggbbaa colour"))
        }
        if let cached = colorCache[token] {
            return cached
        }
        if let c = palette(token, dark) {
            colorCache[token] = c
            return c
        }
        warnOnce("unknown colour \(token)")
        colorCache[token] = .transparent
        return .transparent
    }

    var defaultTextColor: Color {
        palette("text", dark) ?? (dark ? .white : .black)
    }
}

/// Box stored inside a `LuauUserdata` representing a built `El<State>`.
internal final class LuauElBox<State>: @unchecked Sendable {
    let element: El<State>
    let renderEpoch: UInt64
    var used: Bool = false

    init(_ element: El<State>, renderEpoch: UInt64) {
        self.element = element
        self.renderEpoch = renderEpoch
    }
}

internal enum ContainerKind {
    case row, col, box, spacer
}

internal protocol AnyUIRenderSession: AnyObject {
    var env: UIRenderEnv { get }
    func buildContainer(_ kind: ContainerKind, args: [LuauValue]) throws -> LuauValue
    func buildText(_ args: [LuauValue]) throws -> LuauValue
    func buildEach(vm: LuauVM, args: [LuauValue]) throws -> LuauValue
    func buildVirtualList(vm: LuauVM, args: [LuauValue]) throws -> LuauValue
    func buildHostNode(_ node: HostNode, args: [LuauValue]) throws -> LuauValue
    func viewMemo(vm: LuauVM, args: [LuauValue]) throws -> LuauValue
}

internal final class LuauUIBridgeContext: @unchecked Sendable {
    var activeSession: (any AnyUIRenderSession)?
    let uiTable: LuauTable
    let viewTable: LuauTable
    var handlerSlots: [LuauValue] = []
    var handlerWrappers: [LuauValue] = []
    var handlerCursor: Int = 0

    init(uiTable: LuauTable, viewTable: LuauTable) {
        self.uiTable = uiTable
        self.viewTable = viewTable
    }
}

internal final class UIRenderSession<State>: AnyUIRenderSession {
    let env: UIRenderEnv

    init(env: UIRenderEnv) {
        self.env = env
    }

    func buildContainer(_ kind: ContainerKind, args: [LuauValue]) throws -> LuauValue {
        let base: El<State> = switch kind {
        case .row: Rune.row()
        case .col: Rune.col()
        case .box: Rune.el()
        case .spacer: Rune.spacer()
        }
        let (layers, childrenVal) = LuauUIBridge.parseContainerArgs(args)
        var el = try LuauUIBridge.applyProps(layers, to: base, isText: false, env: env)
        if let childrenVal {
            let kids = try LuauUIBridge.extractChildren(childrenVal, State.self, env: env)
            el = el.children(kids)
        }
        return .userdata(LuauUserdata(payload: LuauElBox(el, renderEpoch: env.renderEpoch), typeTag: "El"))
    }

    func buildText(_ args: [LuauValue]) throws -> LuauValue {
        guard let first = args.first else {
            throw LuauRuntimeError(value: .string("ui.text needs a string"))
        }
        let (layers, valueStartIdx) = LuauUIBridge.parseTextArgs(args)
        let template: String
        switch first {
        case .string(let s): template = s
        case .number(let n): template = LuauValue.formatNumber(n)
        default: throw LuauRuntimeError(value: .string("ui.text needs a string, got \(first.typeName)"))
        }
        let content = try LuauUIBridge.interpolateText(template, values: Array(args.dropFirst(valueStartIdx)))
        var el = Rune.text(content) as El<State>
        el = try LuauUIBridge.applyProps(layers, to: el, isText: true, env: env)
        return .userdata(LuauUserdata(payload: LuauElBox(el, renderEpoch: env.renderEpoch), typeTag: "El"))
    }

    func buildEach(vm: LuauVM, args: [LuauValue]) throws -> LuauValue {
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
            if case .string(let field) = keyBy {
                guard case .table(let it) = item else {
                    throw LuauRuntimeError(value: .string("ui.each: item \(i) is not a table"))
                }
                keyVal = it.rawGet(field)
            } else {
                keyVal = try vm.call(value: keyBy, args: [item, .number(Double(i))]).first ?? .nil
            }
            guard !keyVal.isNil else {
                throw LuauRuntimeError(value: .string("ui.each: key for item \(i) is nil"))
            }
            let itemKey = keyVal.displayString

            let verVal: LuauValue
            if case .string(let field) = versionBy {
                guard case .table(let it) = item else {
                    throw LuauRuntimeError(value: .string("ui.each: item \(i) is not a table"))
                }
                verVal = it.rawGet(field)
            } else {
                verVal = try vm.call(value: versionBy, args: [item, .number(Double(i))]).first ?? .nil
            }
            let verHash = LuauUIBridge.mixHash(LuauUIBridge.versionHash(verVal), env.salt)
            var capturedError: Error?
            let built = Rune.memo("\(env.prefix)\(itemKey)", deps: verHash) { () -> El<State> in
                do {
                    let res = try vm.call(value: buildFn, args: [item, .number(Double(i))]).first ?? .nil
                    let node = try LuauUIBridge.unwrapEl(res, State.self)
                    return node.keyId == nil ? node.key(itemKey) : node
                } catch {
                    capturedError = error
                    env.memoFailed = true
                    return Rune.el() as El<State>
                }
            }
            if let capturedError {
                throw capturedError
            }
            out.array.append(.userdata(LuauUserdata(payload: LuauElBox(built, renderEpoch: env.renderEpoch), typeTag: "El")))
        }
        return .table(out)
    }

    func buildVirtualList(vm: LuauVM, args: [LuauValue]) throws -> LuauValue {
        guard case .table(let props) = args.first else {
            throw LuauRuntimeError(value: .string("ui.virtualList needs a props table"))
        }
        let countVal = props.rawGet("count")
        guard let rawCount = countVal.asInt else {
            throw LuauRuntimeError(value: .string("ui.virtualList count must be a number"))
        }
        let count = max(0, rawCount)
        let estimate = Float(max(1.0, props.rawGet("estimatedRowHeight").coercedNumber ?? 32.0))
        let renderRow = props.rawGet("renderRow")
        guard !renderRow.isNil else {
            throw LuauRuntimeError(value: .string("ui.virtualList needs renderRow"))
        }
        let rowKeyFn = props.rawGet("rowKey")
        let rowErrorFn = props.rawGet("rowError")
        let onVisibleRowsFn = props.rawGet("onVisibleRows")
        switch onVisibleRowsFn {
        case .nil, .closure, .nativeFunction:
            break
        default:
            throw LuauRuntimeError(value: .string("ui.virtualList onVisibleRows can't be a \(onVisibleRowsFn.typeName)"))
        }
        if !props.rawGet("onPress").isNil {
            env.warnOnce("ui.virtualList takes no onPress")
        }
        let gap = Float(props.rawGet("gap").coercedNumber ?? 0.0)
        let keyStr = props.rawGet("key").isNil ? "list" : props.rawGet("key").displayString
        let containerKey = "\(env.prefix)\(keyStr)"
        env.trackedScrollKeys.append(containerKey)

        let listVersionVal = props.rawGet("version")
        let keysVersion = listVersionVal.isNil ? env.version : LuauUIBridge.versionHash(listVersionVal)
        let listVersion = LuauUIBridge.mixHash(keysVersion, env.salt)
        let rowVersionsTbl = props.rawGet("rowVersions").asTable
        let ownScroll = props.rawGet("scrollY").asBool ?? true

        let liveScrollY = env.scrollLookup?(containerKey).y ?? 0
        let explicitH = props.rawGet("h").coercedNumber.map { Float($0) }
        let viewportHeight = max(1, explicitH ?? (env.viewport.y > 0 ? env.viewport.y : 600))

        let listState = env.script?.virtualListState(forKey: containerKey) ?? VirtualListState()
        listState.gap = gap
        let items: [VirtualItemSpec] = (0..<count).map { idx in
            let cachedKey = env.script?.cachedRowKey(for: containerKey, version: keysVersion, index: idx)
            return VirtualItemSpec(key: cachedKey ?? "row-\(idx)", estimatedHeight: estimate)
        }
        listState.setItems(items)
        let window = listState.computeWindow(scrollY: liveScrollY, viewportHeight: viewportHeight)

        var container = El<State>(direction: .column)
            .gap(gap)
            .wFull()

        if window.beforeHeight > 0 {
            container = container.child(
                El<State>(direction: .row)
                    .key("\(containerKey)-before-spacer")
                    .wFull()
                    .h(window.beforeHeight)
                    .shrink(0)
            )
        }

        for idx in window.mountedRange {
            container = container.child(
                try buildVirtualRow(
                    vm: vm,
                    idx: idx,
                    containerKey: containerKey,
                    keysVersion: keysVersion,
                    listVersion: listVersion,
                    rowKeyFn: rowKeyFn,
                    rowVersionsTbl: rowVersionsTbl,
                    renderRow: renderRow,
                    rowErrorFn: rowErrorFn
                )
            )
        }

        if window.afterHeight > 0 {
            container = container.child(
                El<State>(direction: .row)
                    .key("\(containerKey)-after-spacer")
                    .wFull()
                    .h(window.afterHeight)
                    .shrink(0)
            )
        }

        if ownScroll {
            container = container.scrollY()
        }

        let skipKeys: Set<String> = [
            "count", "estimatedRowHeight", "renderRow", "rowKey", "rowError",
            "version", "rowVersions", "onVisibleRows", "onPress", "scrollY",
        ]
        container = try LuauUIBridge.applyProps([props], to: container, isText: false, env: env, skipKeys: skipKeys)
        container = container.key(containerKey)

        if !onVisibleRowsFn.isNil {
            let visFirst = window.visibleRange.isEmpty ? 0 : window.visibleRange.lowerBound + 1
            let visLast = window.visibleRange.isEmpty ? 0 : window.visibleRange.upperBound
            if let script = env.script, script.recordVisibleRowsChange(for: containerKey, first: visFirst, last: visLast) {
                let event = LuauTable()
                event.rawSet("kind", value: .string("visible-rows"))
                event.rawSet("first", value: .number(Double(visFirst)))
                event.rawSet("last", value: .number(Double(visLast)))
                let vmID = env.vmID
                var dummyState: Any = ()
                script.aroundWriteOptional(state: &dummyState, tx: nil) { txPtr in
                    var tx = txPtr?.pointee ?? Tx()
                    script.enter(tx: &tx) {
                        try script.callHandlerIfCurrent(vmID: vmID, fn: onVisibleRowsFn, arg: .table(event))
                    }
                    txPtr?.pointee = tx
                }
            }
        }

        return .userdata(LuauUserdata(payload: LuauElBox(container, renderEpoch: env.renderEpoch), typeTag: "El"))
    }

    @inline(never)
    private func buildVirtualRow(
        vm: LuauVM,
        idx: Int,
        containerKey: String,
        keysVersion: UInt64,
        listVersion: UInt64,
        rowKeyFn: LuauValue,
        rowVersionsTbl: LuauTable?,
        renderRow: LuauValue,
        rowErrorFn: LuauValue
    ) throws -> El<State> {
        let resolvedRowKey: String
        if let cached = env.script?.cachedRowKey(for: containerKey, version: keysVersion, index: idx) {
            resolvedRowKey = cached
        } else if !rowKeyFn.isNil {
            let k = try vm.call(value: rowKeyFn, args: [.number(Double(idx + 1))]).first ?? .nil
            let s = k.isNil ? String(idx + 1) : k.displayString
            env.script?.storeRowKey(s, for: containerKey, version: keysVersion, index: idx)
            resolvedRowKey = s
        } else {
            resolvedRowKey = String(idx + 1)
        }

        let rowVer = rowVersionsTbl.map {
            LuauUIBridge.mixHash(LuauUIBridge.versionHash($0.rawGet(idx + 1)), listVersion)
        } ?? listVersion
        let rowID = "\(containerKey)/\(resolvedRowKey)"
        return Rune.memo(rowID, deps: rowVer) { () -> El<State> in
            env.script?.incrementRowsMetric()
            do {
                let res = try vm.call(value: renderRow, args: [.number(Double(idx + 1))]).first ?? .nil
                let rowEl = try LuauUIBridge.unwrapEl(res, State.self)
                return rowEl.keyId == nil ? rowEl.key(rowID) : rowEl
            } catch {
                let msg = error.localizedDescription
                env.script?.logError(msg)
                if !rowErrorFn.isNil,
                   let fallback = try? vm.call(value: rowErrorFn, args: [.number(Double(idx + 1)), .string(msg)]).first,
                   let el = try? LuauUIBridge.unwrapEl(fallback, State.self) {
                    return el.keyId == nil ? el.key(rowID) : el
                }
                return (LuauCard.rowError(message: msg) as El<State>).key(rowID)
            }
        }
    }

    func buildHostNode(_ node: HostNode, args: [LuauValue]) throws -> LuauValue {
        let nodeArgs = try LuauUIBridge.buildHostNodeArgs(args, State.self, env: env)
        let rawBuilt: Any
        do {
            rawBuilt = try node.build(nodeArgs)
        } catch let err as LuauRuntimeError {
            throw LuauRuntimeError(
                value: .string("ui.\(node.name): \(err.value.displayString)"),
                traceback: err.traceback,
                isTimeout: err.isTimeout,
                isMemory: err.isMemory
            )
        } catch let err as ScriptError {
            throw ScriptError(kind: err.kind, message: "ui.\(node.name): \(err.message)")
        } catch {
            throw LuauRuntimeError(value: .string("ui.\(node.name): \(error.localizedDescription)"))
        }
        guard var built = rawBuilt as? El<State> else {
            throw LuauRuntimeError(value: .string("ui.\(node.name) returned wrong El<State> type"))
        }
        if !nodeArgs.rawProps.isEmpty {
            let unread = LuauTable()
            for (k, v) in nodeArgs.rawProps where !nodeArgs.wasRead(k) {
                unread.rawSet(k, value: v)
            }
            if !unread.hash.isEmpty {
                built = try LuauUIBridge.applyProps([unread], to: built, isText: false, env: env)
            }
        }
        return .userdata(LuauUserdata(payload: LuauElBox(built, renderEpoch: env.renderEpoch), typeTag: "El"))
    }

    func viewMemo(vm: LuauVM, args: [LuauValue]) throws -> LuauValue {
        guard args.count >= 4 else {
            throw LuauRuntimeError(value: .string("view:Memo needs (key, version, build)"))
        }
        let keyStr: String
        switch args[1] {
        case .string(let s):
            keyStr = s
        case .number(let n):
            keyStr = LuauValue.number(n).displayString
        default:
            throw LuauRuntimeError(value: .string("view:Memo key must be a string or number, got \(args[1].typeName)"))
        }
        let verArg = args[2]
        switch verArg {
        case .nil, .bool, .number, .string:
            break
        default:
            throw LuauRuntimeError(value: .string("view:Memo version cannot be a \(verArg.typeName)"))
        }
        let buildFn = args[3]
        switch buildFn {
        case .closure, .nativeFunction:
            break
        default:
            throw LuauRuntimeError(value: .string("view:Memo build must be a function, got \(buildFn.typeName)"))
        }
        let ver = LuauUIBridge.mixHash(LuauUIBridge.versionHash(verArg), env.salt)
        let memoID = "\(env.prefix)\(keyStr)"
        var capturedError: Error?
        let el = Rune.memo(memoID, deps: ver) { () -> El<State> in
            do {
                let res = try vm.call(value: buildFn, args: []).first ?? .nil
                let built = try LuauUIBridge.unwrapEl(res, State.self)
                return built.key(memoID)
            } catch {
                capturedError = error
                env.memoFailed = true
                return Rune.el() as El<State>
            }
        }
        if let capturedError {
            throw capturedError
        }
        return .userdata(LuauUserdata(payload: LuauElBox(el, renderEpoch: env.renderEpoch), typeTag: "El"))
    }
}

/// Helper so `Script` and `UI` install `@rune/ui` once per VM and swap active typed render sessions per render pass.
internal enum LuauUIBridge {
    private static func requireSession(_ vm: LuauVM, _ name: String) throws -> any AnyUIRenderSession {
        guard let session = vm.getAppData(LuauUIBridgeContext.self)?.activeSession else {
            throw LuauRuntimeError(value: .string("\(name) can only be built while rendering"))
        }
        return session
    }

    @discardableResult
    static func installStatic(
        into vm: LuauVM,
        hostNodes: [HostNode]
    ) -> LuauUIBridgeContext {
        if let existing = vm.getAppData(LuauUIBridgeContext.self) {
            return existing
        }
        let ui = LuauTable()

        ui.rawSet("hex", value: .nativeFunction(LuauNativeFunction(name: "ui.hex") { _, _, args in
            guard case .string(let s) = args.first, s.hasPrefix("#"), (s.count == 7 || s.count == 9), Color.hex(s) != nil else {
                throw LuauRuntimeError(value: .string("ui.hex needs \"#RRGGBB\" or \"#RRGGBBAA\""))
            }
            return .values([.string(s)])
        }))

        func makeContainer(_ name: String, kind: ContainerKind) -> LuauValue {
            .nativeFunction(LuauNativeFunction(name: "ui.\(name)") { vm, _, args in
                let session = try LuauUIBridge.requireSession(vm, "ui nodes")
                return .values([try session.buildContainer(kind, args: args)])
            })
        }

        ui.rawSet("row", value: makeContainer("row", kind: .row))
        ui.rawSet("col", value: makeContainer("col", kind: .col))
        ui.rawSet("box", value: makeContainer("box", kind: .box))
        ui.rawSet("spacer", value: makeContainer("spacer", kind: .spacer))

        ui.rawSet("text", value: .nativeFunction(LuauNativeFunction(name: "ui.text") { vm, _, args in
            let session = try LuauUIBridge.requireSession(vm, "ui.text")
            return .values([try session.buildText(args)])
        }))

        ui.rawSet("each", value: .nativeFunction(LuauNativeFunction(name: "ui.each") { vm, _, args in
            let session = try LuauUIBridge.requireSession(vm, "ui.each")
            return .values([try session.buildEach(vm: vm, args: args)])
        }))

        ui.rawSet("virtualList", value: .nativeFunction(LuauNativeFunction(name: "ui.virtualList") { vm, _, args in
            let session = try LuauUIBridge.requireSession(vm, "ui.virtualList")
            return .values([try session.buildVirtualList(vm: vm, args: args)])
        }))

        for node in hostNodes {
            ui.rawSet(node.name, value: .nativeFunction(LuauNativeFunction(name: "ui.\(node.name)") { vm, _, args in
                let session = try LuauUIBridge.requireSession(vm, "ui.\(node.name)")
                return .values([try session.buildHostNode(node, args: args)])
            }))
        }

        ui.isFrozen = true
        vm.registeredModules["@rune/ui"] = .table(ui)

        let view = LuauTable()
        view.rawSet("dark", value: .bool(false))
        view.rawSet("Memo", value: .nativeFunction(LuauNativeFunction(name: "view:Memo") { vm, _, args in
            guard let session = vm.getAppData(LuauUIBridgeContext.self)?.activeSession else {
                throw LuauRuntimeError(value: .string("view:Memo can only be called while rendering"))
            }
            return .values([try session.viewMemo(vm: vm, args: args)])
        }))
        view.rawSet("Handler", value: .nativeFunction(LuauNativeFunction(name: "view:Handler") { vm, _, args in
            let fn = args.count > 1 ? args[1] : .nil
            guard case .closure = fn else {
                if case .nativeFunction = fn {
                    return .values([fn])
                }
                throw LuauRuntimeError(value: .string("view:Handler needs a function"))
            }
            guard let ctx = vm.getAppData(LuauUIBridgeContext.self) else {
                return .values([fn])
            }
            let idx = ctx.handlerCursor
            ctx.handlerCursor += 1
            if idx < ctx.handlerSlots.count {
                ctx.handlerSlots[idx] = fn
                return .values([ctx.handlerWrappers[idx]])
            }
            ctx.handlerSlots.append(fn)
            let wrapper = LuauValue.nativeFunction(LuauNativeFunction(name: "view.handlerWrapper") { vm, _, callArgs in
                guard let ctx = vm.getAppData(LuauUIBridgeContext.self), idx < ctx.handlerSlots.count else {
                    return .values([])
                }
                return .values(try vm.call(value: ctx.handlerSlots[idx], args: callArgs))
            })
            ctx.handlerWrappers.append(wrapper)
            return .values([wrapper])
        }))

        let ctx = LuauUIBridgeContext(uiTable: ui, viewTable: view)
        vm.setAppData(ctx)
        return ctx
    }

    static func withSession<State, R>(
        vm: LuauVM,
        stateType: State.Type = State.self,
        env: UIRenderEnv,
        body: (LuauTable) throws -> R
    ) rethrows -> R {
        let ctx = vm.getAppData(LuauUIBridgeContext.self) ?? installStatic(into: vm, hostNodes: [])
        let prevSession = ctx.activeSession
        let prevDark = ctx.viewTable.rawGet("dark")
        let prevCursor = ctx.handlerCursor
        ctx.activeSession = UIRenderSession<State>(env: env)
        ctx.viewTable.rawSet("dark", value: .bool(env.dark))
        ctx.handlerCursor = 0
        defer {
            ctx.activeSession = prevSession
            ctx.viewTable.rawSet("dark", value: prevDark)
            ctx.handlerCursor = prevCursor
        }
        return try body(ctx.viewTable)
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
        if t.rawLength > 0 {
            return false
        }
        return t.hashOrder.contains { hk in
            switch hk {
            case .string: return true
            case .number(let bits):
                let d = Double(bitPattern: bits)
                return !(d.isFinite && d >= 1.0 && d.rounded(.towardZero) == d)
            default: return true
            }
        }
    }

    fileprivate static func parseContainerArgs(_ args: [LuauValue]) -> ([LuauTable], LuauValue?) {
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

    fileprivate static func parseTextArgs(_ args: [LuauValue]) -> ([LuauTable], Int) {
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

    fileprivate static func interpolateText(_ template: String, values: [LuauValue]) throws -> String {
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

    fileprivate static func extractChildren<State>(_ val: LuauValue, _ type: State.Type, env: UIRenderEnv) throws -> [El<State>] {
        guard case .table(let t) = val else { return [] }
        var result: [El<State>] = []
        let len = t.rawLength
        var indices: [Int] = len > 0 ? Array(1...len) : []
        var extra: [Int] = []
        for hk in t.hashOrder {
            if case .number(let bits) = hk {
                let d = Double(bitPattern: bits)
                if d.isFinite, d >= 1.0, d.rounded(.towardZero) == d, d <= Double(Int.max) {
                    let idx = Int(d)
                    if idx > len {
                        extra.append(idx)
                    }
                }
            }
        }
        if !extra.isEmpty {
            extra.sort()
            indices.append(contentsOf: extra)
        }
        for i in indices {
            let item = t.rawGet(i)
            switch item {
            case .nil, .bool(false):
                continue
            case .string(let s):
                result.append((Rune.text(s) as El<State>).font(env.baseTextStyle).color(env.defaultTextColor))
            case .number(let n):
                result.append((Rune.text(LuauValue.formatNumber(n)) as El<State>).font(env.baseTextStyle).color(env.defaultTextColor))
            case .userdata(let u):
                guard let box = u.payload as? LuauElBox<State> else {
                    throw LuauRuntimeError(value: .string("child \(i) is a userdata, not a ui node"))
                }
                if box.renderEpoch != env.renderEpoch {
                    throw LuauRuntimeError(value: .string("elements cannot be saved across renders"))
                }
                if box.used {
                    throw LuauRuntimeError(value: .string("each element can only be placed once"))
                }
                box.used = true
                result.append(box.element)
            default:
                throw LuauRuntimeError(value: .string("child \(i) is a \(item.typeName), not a ui node"))
            }
        }
        return result
    }

    fileprivate static func buildHostNodeArgs<State>(_ args: [LuauValue], _ type: State.Type, env: UIRenderEnv) throws -> NodeArgs {
        var idx = 0
        var content: String? = nil
        if idx < args.count, case .string(let s) = args[idx] {
            content = s
            idx += 1
        }
        var props: [(String, Prop)] = []
        var rawProps: [(String, LuauValue)] = []
        func collectProps(_ tbl: LuauTable) {
            for hk in tbl.hashOrder {
                guard case .string(let k) = hk, let v = tbl.hash[hk], !v.isNil else { continue }
                rawProps.append((k, v))
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
                if box.renderEpoch != env.renderEpoch {
                    throw LuauRuntimeError(value: .string("elements cannot be saved across renders"))
                }
                if box.used {
                    throw LuauRuntimeError(value: .string("each element can only be placed once"))
                }
                box.used = true
                kids = [box.element]
            } else if case .table = cVal {
                kids = try extractChildren(cVal, State.self, env: env)
            }
        }
        return NodeArgs(content: content, props: props, rawProps: rawProps, children: kids, env: env)
    }

    private enum LuauSizeSpec {
        case px(Float)
        case frac(Float)
        case full
    }

    private struct ApplyPropState {
        var keyStr: String? = nil
        var padAll: Float? = nil
        var padSides: UInt8 = 0
        var borderWidth: Float? = nil
        var borderColor: Color? = nil
        var textStyle: TextStyle
        var textColor: Color? = nil
        var scrollX = false
        var scrollY = false
        var stickBottom = false
        var onPressVal: LuauValue? = nil
        var onHoverVal: LuauValue? = nil
        var isDisabled = false
        var isSelectable = false
    }

    private static func propNum(_ v: LuauValue, _ name: String) throws -> Float {
        guard let d = v.coercedNumber else {
            throw LuauRuntimeError(value: .string("\(name) must be a number, got \(v.typeName)"))
        }
        return Float(d)
    }

    private static func propFlag(_ v: LuauValue, _ name: String) throws -> Bool {
        guard case .bool(let b) = v else {
            throw LuauRuntimeError(value: .string("\(name) must be a boolean, got \(v.typeName)"))
        }
        return b
    }

    private static func propStr(_ v: LuauValue, _ name: String) throws -> String {
        guard case .string(let s) = v else {
            throw LuauRuntimeError(value: .string("\(name) must be a string, got \(v.typeName)"))
        }
        return s
    }

    private static func propSize(_ v: LuauValue, _ name: String) throws -> LuauSizeSpec {
        switch v {
        case .number(let n):
            return .px(Float(n))
        case .string("full"):
            return .full
        case .string(let s) where s.hasSuffix("%"):
            let prefix = String(s.dropLast())
            guard let pct = Float(prefix) else {
                throw LuauRuntimeError(value: .string("\(name): invalid percentage '\(s)'"))
            }
            return .frac(pct / 100.0)
        case .string(let s):
            throw LuauRuntimeError(value: .string("\(name): invalid size '\(s)'"))
        default:
            throw LuauRuntimeError(value: .string("\(name) must be a number or size string, got \(v.typeName)"))
        }
    }

    private static func mapRole(_ s: String) -> ElementRole? {
        switch s {
        case "none", "group", "list": return .group
        case "region": return .region
        case "button": return .button
        case "link": return .link
        case "switch": return .switchControl
        case "checkbox": return .checkbox
        case "radio": return .radio
        case "tab": return .tab
        case "textbox": return .textInput
        case "slider": return .slider
        case "progress", "progressbar": return .progress
        case "listitem": return .listItem
        case "heading": return .heading
        case "dialog": return .dialog
        case "alert": return .alert
        case "menu": return .menu
        case "menuitem": return .menuItem
        case "img": return .image
        case "icon": return .icon
        case "separator": return .separator
        case "status", "text": return .text
        default: return nil
        }
    }

    @inline(never)
    private static func applySizeProp<State>(_ k: String, _ v: LuauValue, el: inout El<State>) throws -> Bool {
        switch k {
        case "w":
            switch try propSize(v, "w") {
            case .px(let px): el = el.w(px)
            case .frac(let f): el = el.wFrac(f)
            case .full: el = el.wFull()
            }
        case "h":
            switch try propSize(v, "h") {
            case .px(let px): el = el.h(px)
            case .frac(let f): el = el.hFrac(f)
            case .full: el = el.hFull()
            }
        case "minW": el = el.minW(try propNum(v, k))
        case "maxW": el = el.maxW(try propNum(v, k))
        case "minH": el = el.minH(try propNum(v, k))
        case "maxH": el = el.maxH(try propNum(v, k))
        case "grow": el = el.grow(try propNum(v, k))
        case "shrink":
            if try propFlag(v, k) { el = el.shrink(1) }
        default:
            return false
        }
        return true
    }

    @inline(never)
    private static func applySpacingLayoutProp<State>(_ k: String, _ v: LuauValue, el: inout El<State>, state: inout ApplyPropState, isText: Bool) throws -> Bool {
        switch k {
        case "pad": state.padAll = try propNum(v, k)
        case "px": el = el.px(try propNum(v, k)); state.padSides |= 0b1010
        case "py": el = el.py(try propNum(v, k)); state.padSides |= 0b0101
        case "pt": el = el.pt(try propNum(v, k)); state.padSides |= 0b0001
        case "pr": el = el.pr(try propNum(v, k)); state.padSides |= 0b0010
        case "pb": el = el.pb(try propNum(v, k)); state.padSides |= 0b0100
        case "pl": el = el.pl(try propNum(v, k)); state.padSides |= 0b1000
        case "m": el = el.m(try propNum(v, k))
        case "mx": el = el.mx(try propNum(v, k))
        case "my": el = el.my(try propNum(v, k))
        case "mt": el = el.mt(try propNum(v, k))
        case "mr": el = el.mr(try propNum(v, k))
        case "mb": el = el.mb(try propNum(v, k))
        case "ml": el = el.ml(try propNum(v, k))
        case "gap": el = el.gap(try propNum(v, k))
        case "align":
            switch v.asString {
            case "start": el = el.itemsStart()
            case "center": el = el.itemsCenter()
            case "end": el = el.itemsEnd()
            case "stretch": el = el.itemsStretch()
            default: throw LuauRuntimeError(value: .string("align must be start, center, end or stretch, got \(v.typeName)"))
            }
        case "justify":
            switch v.asString {
            case "start": el = el.justifyStart()
            case "center": el = el.justifyCenter()
            case "end": el = el.justifyEnd()
            case "between": el = el.justifyBetween()
            default: throw LuauRuntimeError(value: .string("justify must be start, center, end or between, got \(v.typeName)"))
            }
        case "center":
            if try propFlag(v, k) { el = el.center() }
        case "wrap":
            let b = try propFlag(v, k)
            if isText {
                state.textStyle.wrap = b ? .wrap : .noWrap
            } else if b {
                el = el.flexWrap(true)
            }
        default:
            return false
        }
        return true
    }

    @inline(never)
    private static func applyVisualProp<State>(_ k: String, _ v: LuauValue, el: inout El<State>, state: inout ApplyPropState, env: UIRenderEnv) throws -> Bool {
        switch k {
        case "key":
            switch v {
            case .string(let s): state.keyStr = s
            case .number(let n): state.keyStr = LuauValue.number(n).displayString
            default:
                throw LuauRuntimeError(value: .string("key must be a string or number, got \(v.typeName)"))
            }
        case "opacity": el = el.opacity(try propNum(v, k))
        case "label": el = el.label(try propStr(v, k))
        case "help": el = el.help(try propStr(v, k))
        case "fill": el = el.bg(try env.resolveColor(try propStr(v, k)))
        case "hover": el = el.hover(try env.resolveColor(try propStr(v, k)))
        case "press": el = el.press(try env.resolveColor(try propStr(v, k)))
        case "border": state.borderColor = try env.resolveColor(try propStr(v, k))
        case "borderWidth": state.borderWidth = try propNum(v, k)
        case "radius": el = el.rounded(try propNum(v, k))
        case "corners":
            guard case .table(let ct) = v else {
                throw LuauRuntimeError(value: .string("corners must be a table, got \(v.typeName)"))
            }
            let c0 = Float(ct.rawGet(1).coercedNumber ?? 0)
            let c1 = Float(ct.rawGet(2).coercedNumber ?? 0)
            let c2 = Float(ct.rawGet(3).coercedNumber ?? 0)
            let c3 = Float(ct.rawGet(4).coercedNumber ?? 0)
            el = el.corners(c0, c1, c2, c3)
        case "clip":
            if try propFlag(v, k) { el = el.clipSoft(0) }
        case "scrollY": state.scrollY = try propFlag(v, k)
        case "scrollX": state.scrollX = try propFlag(v, k)
        case "stickBottom": state.stickBottom = try propFlag(v, k)
        case "pin":
            guard case .table(let pt) = v else {
                throw LuauRuntimeError(value: .string("pin must be a table, got \(v.typeName)"))
            }
            el = el.pin(
                top: pt.rawGet("top").coercedNumber.map { Float($0) },
                right: pt.rawGet("right").coercedNumber.map { Float($0) },
                bottom: pt.rawGet("bottom").coercedNumber.map { Float($0) },
                left: pt.rawGet("left").coercedNumber.map { Float($0) }
            )
        case "shadow":
            let s = try propStr(v, k)
            if let list = env.shadows?(s, env.dark) {
                el = el.shadows(list)
            } else {
                env.warnOnce("unknown shadow \(s)")
            }
        default:
            return false
        }
        return true
    }

    @inline(never)
    private static func applyTextAndBehaviorProp<State>(_ k: String, _ v: LuauValue, el: inout El<State>, state: inout ApplyPropState, env: UIRenderEnv) throws -> Bool {
        switch k {
        case "color": state.textColor = try env.resolveColor(try propStr(v, k))
        case "size": state.textStyle.size = try propNum(v, k)
        case "weight":
            switch v {
            case .string("regular"): state.textStyle.weight = env.weights[0]
            case .string("medium"): state.textStyle.weight = env.weights[1]
            case .string("semibold"): state.textStyle.weight = env.weights[2]
            case .string("bold"): state.textStyle.weight = env.weights[3]
            case .number(let n): state.textStyle.weight = Float(n)
            default:
                throw LuauRuntimeError(value: .string("weight must be regular, medium, semibold, bold or a number, got \(v.typeName)"))
            }
        case "lineHeight": state.textStyle.lineHeight = try propNum(v, k)
        case "tracking": state.textStyle.letterSpacing = try propNum(v, k)
        case "mono":
            if try propFlag(v, k) { state.textStyle.family = .monospace }
        case "tabular":
            if try propFlag(v, k) { state.textStyle = state.textStyle.features("'tnum' 1") }
        case "selectable":
            state.isSelectable = try propFlag(v, k)
        case "noWrap":
            if try propFlag(v, k) { state.textStyle.wrap = .noWrap }
        case "truncate":
            if try propFlag(v, k) { state.textStyle.wrap = .ellipsis }
        case "textAlign":
            switch v.asString {
            case "start": state.textStyle.align = .leading
            case "center": state.textStyle.align = .center
            case "end": state.textStyle.align = .trailing
            default:
                throw LuauRuntimeError(value: .string("textAlign must be start, center or end, got \(v.typeName)"))
            }
        case "focusable":
            if try propFlag(v, k) { el = el.focusable(true) }
        case "disabled":
            state.isDisabled = try propFlag(v, k)
            if state.isDisabled { el = el.disabled(true) }
        case "selected":
            let sel = try propFlag(v, k)
            if sel {
                if let c = env.palette("selected", env.dark) {
                    el = el.bg(c)
                }
                el = el.focusSelected(true)
            }
            el = el.itemSelected(sel).selected(sel ? "true" : nil)
        case "fadeOut":
            _ = try propFlag(v, k)
            env.warnOnce("fadeOut has no effect on Swift El yet")
        case "dir":
            switch try propStr(v, k) {
            case "auto", "ltr", "rtl": break
            case let other: throw LuauRuntimeError(value: .string("dir must be auto, ltr or rtl, got \(other)"))
            }
            env.warnOnce("dir has no effect on Swift El yet")
        case "hoverTransition":
            switch try propStr(v, k) {
            case "default", "instant": break
            case let other: throw LuauRuntimeError(value: .string("hoverTransition must be default or instant, got \(other)"))
            }
            env.warnOnce("hoverTransition has no effect on Swift El yet")
        case "hoverGroup":
            if try propFlag(v, k) { el = el.hoverGroup() }
        case "hoverGroupColor":
            el = el.groupColor(try env.resolveColor(try propStr(v, k)))
        case "revealOnHover":
            if try propFlag(v, k) { el = el.groupOpacity(0, 1) }
        case "helpSide":
            switch try propStr(v, k) {
            case "top": el = el.helpSide(.top)
            case "right": el = el.helpSide(.right)
            case "bottom": el = el.helpSide(.bottom)
            case "left": el = el.helpSide(.left)
            case let other: throw LuauRuntimeError(value: .string("helpSide must be top, right, bottom or left, got \(other)"))
            }
        case "onPress": state.onPressVal = v
        case "onHover": state.onHoverVal = v
        case "role":
            let s = try propStr(v, k)
            guard let r = mapRole(s) else {
                throw LuauRuntimeError(value: .string("unknown role \(s)"))
            }
            el = el.role(r)
        default:
            return false
        }
        return true
    }

    @inline(never)
    private static func finalizeAppliedProps<State>(_ el: inout El<State>, state: ApplyPropState, isText: Bool, env: UIRenderEnv) {
        if let p = state.padAll {
            if state.padSides == 0 {
                el = el.p(p)
            } else {
                if (state.padSides & 0b0001) == 0 { el = el.pt(p) }
                if (state.padSides & 0b0010) == 0 { el = el.pr(p) }
                if (state.padSides & 0b0100) == 0 { el = el.pb(p) }
                if (state.padSides & 0b1000) == 0 { el = el.pl(p) }
            }
        }
        if state.borderWidth != nil || state.borderColor != nil {
            let c = state.borderColor ?? env.palette("separator", env.dark) ?? .transparent
            el = el.border(state.borderWidth ?? 1.0, c)
        }
        if state.scrollX && state.scrollY {
            el = el.scrollXY()
        } else if state.scrollX {
            el = el.scrollX()
        } else if state.scrollY {
            el = el.scrollY(stickBottom: state.stickBottom)
        }
        if isText {
            el = el.font(state.textStyle).color(state.textColor ?? env.defaultTextColor)
            if state.isSelectable {
                el = el.selectable(true)
            }
        } else if let c = state.textColor {
            el = el.color(c)
        }
        if let k = state.keyStr {
            el = el.key(k)
        }
        if let onPressVal = state.onPressVal, !state.isDisabled {
            let capturedKey = state.keyStr
            let scriptRef = env.script
            let vmID = env.vmID
            el = el.onPointerUp { _, press, _ in
                scriptRef?.stashPressMods(press.mods)
            }
            el = el.onClick { st, tx in
                guard let script = scriptRef else { return }
                let mods = script.consumePressMods()
                let m = script.pressEventMods(mods)
                let ev = LuauTable()
                ev.rawSet("kind", value: .string("press"))
                if let capturedKey { ev.rawSet("key", value: .string(capturedKey)) }
                ev.rawSet("shift", value: .bool(m.shift))
                ev.rawSet("alt", value: .bool(m.alt))
                ev.rawSet("mod", value: .bool(m.mod))
                script.aroundWrite(state: &st, tx: &tx) { innerTx in
                    script.enter(tx: &innerTx) {
                        try script.callHandlerIfCurrent(vmID: vmID, fn: onPressVal, arg: .table(ev))
                    }
                }
            }
        }
        if let onHoverVal = state.onHoverVal, !state.isDisabled {
            let capturedKey = state.keyStr
            let scriptRef = env.script
            let vmID = env.vmID
            el = el.onHover { st, entered, tx in
                guard let script = scriptRef else { return }
                let ev = LuauTable()
                ev.rawSet("kind", value: .string("hover"))
                if let capturedKey { ev.rawSet("key", value: .string(capturedKey)) }
                ev.rawSet("entered", value: .bool(entered))
                script.aroundWrite(state: &st, tx: &tx) { innerTx in
                    script.enter(tx: &innerTx) {
                        try script.callHandlerIfCurrent(vmID: vmID, fn: onHoverVal, arg: .table(ev))
                    }
                }
            }
        }
    }

    @inline(never)
    fileprivate static func applyProps<State>(
        _ tables: [LuauTable],
        to element: El<State>,
        isText: Bool,
        env: UIRenderEnv,
        skipKeys: Set<String> = []
    ) throws -> El<State> {
        var el = element
        var state = ApplyPropState(textStyle: env.baseTextStyle)
        for tbl in tables {
            for hk in tbl.hashOrder {
                guard case .string(let k) = hk, let v = tbl.hash[hk], !v.isNil else { continue }
                if skipKeys.contains(k) { continue }
                if try applySizeProp(k, v, el: &el) { continue }
                if try applySpacingLayoutProp(k, v, el: &el, state: &state, isText: isText) { continue }
                if try applyVisualProp(k, v, el: &el, state: &state, env: env) { continue }
                if try applyTextAndBehaviorProp(k, v, el: &el, state: &state, env: env) { continue }
                env.warnOnce("unknown prop \(k)")
            }
        }
        finalizeAppliedProps(&el, state: state, isText: isText, env: env)
        return el
    }

    fileprivate static func versionHash(_ val: LuauValue) -> UInt64 {
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

    fileprivate static func mixHash(_ a: UInt64, _ b: UInt64) -> UInt64 {
        var h = Hasher()
        h.combine(a)
        h.combine(b)
        return UInt64(bitPattern: Int64(h.finalize()))
    }
}
