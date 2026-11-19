import Foundation
import Rune
import RuneMotion

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
public struct Press: @unchecked Sendable, Equatable {
    public var key: String?
    public var shift: Bool
    public var alt: Bool
    public var mod: Bool
    private let handler: Handler?

    public init(key: String? = nil, shift: Bool = false, alt: Bool = false, mod: Bool = false) {
        self.key = key
        self.shift = shift
        self.alt = alt
        self.mod = mod
        self.handler = nil
    }

    internal init(handler: Handler, key: String?) {
        self.key = key
        self.shift = false
        self.alt = false
        self.mod = false
        self.handler = handler
    }

    public static func == (lhs: Press, rhs: Press) -> Bool {
        lhs.key == rhs.key && lhs.shift == rhs.shift && lhs.alt == rhs.alt && lhs.mod == rhs.mod
    }

    /// Delivers a press event with modifiers and extra fields. Mouse menu triggers fire on button down.
    public func attach<State>(_ el: El<State>, fields: [(String, LuauData)] = [], menuTrigger: Bool = false) -> El<State> {
        guard let handler else { return el }
        let vmID = handler.vmID
        let fn = handler.fn
        let scriptRef = handler.script
        let fallbackKey = self.key
        let button = menuTrigger ? el.pressOnDown() : el.onPointerUp { _, press, _ in
            scriptRef?.stashPressMods(press.mods)
        }
        return button.onClick { st, tx in
            guard let script = scriptRef else { return }
            let mods = menuTrigger ? tx.mods : script.consumePressMods()
            let m = script.pressEventMods(mods)
            let ev = LuauTable()
            ev.rawSet("kind", value: .string("press"))
            if let fallbackKey { ev.rawSet("key", value: .string(fallbackKey)) }
            ev.rawSet("shift", value: .bool(m.shift))
            ev.rawSet("alt", value: .bool(m.alt))
            ev.rawSet("mod", value: .bool(m.mod))
            for (fk, fv) in fields {
                ev.rawSet(fk, value: fv.toLuau())
            }
            script.aroundWrite(state: &st, tx: &tx) { innerTx in
                script.enter(tx: &innerTx) {
                    try script.callHandlerIfCurrent(vmID: vmID, fn: fn, arg: .table(ev))
                }
            }
        }
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

    private func rawKey() -> String? {
        guard let pair = props.last(where: { $0.0 == "key" }) else { return nil }
        if case .string(let s) = pair.1 { return s }
        return nil
    }

    /// Builds an `El` click callback invoking a Luau `Handler` with press event details.
    public func onPress<State>(_ type: State.Type = State.self, handler: Handler) -> (@Sendable (inout State, inout Tx) -> Void) {
        onPressWith(type, handler: handler, key: rawKey())
    }

    /// Attaches the named callback and honors the host node’s `menuTrigger` prop.
    public func onPress<State>(_ el: El<State>, _ name: String) -> El<State> {
        guard let h = handler(name) else { return el }
        return Press(handler: h, key: rawKey()).attach(el, menuTrigger: flag("menuTrigger"))
    }

    /// Builds an `El` click callback invoking a Luau `Handler` with an explicit key and modifier state.
    public func onPressWith<State>(
        _ type: State.Type = State.self,
        handler: Handler,
        key: String? = nil,
        press: Press? = nil,
        fields: [(String, LuauData)] = []
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
            for (fk, fv) in fields {
                ev.rawSet(fk, value: fv.toLuau())
            }
            script.aroundWrite(state: &state, tx: &tx) { tx in
                script.enter(tx: &tx) {
                    try script.callHandlerIfCurrent(vmID: vmID, fn: fn, arg: .table(ev))
                }
            }
        }
    }

    /// Captures a named press handler prop for later attachment via `Press.attach(_:fields:)`, without marking `"key"` as read.
    public func pressLater(_ name: String) -> Press? {
        let k = rawKey()
        return handler(name).map { Press(handler: $0, key: k) }
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
        let capturedKey = rawKey()
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

    /// Attaches a named hover handler prop to `el` if present, without marking `"key"` as read.
    public func onHover<State>(_ el: El<State>, _ name: String) -> El<State> {
        guard let h = handler(name) else { return el }
        return el.onHover(onHover(State.self, handler: h))
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
    fileprivate struct PaletteValue: Equatable {
        let color: Color?
    }
    private var colorCache: [String: PaletteValue] = [:]
    private var recordedPalette: [String: PaletteValue]?

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

    /// Each deferred row is a new Luau UI frame with its own handles and palette reads.
    func forRow() -> UIRenderEnv {
        UIRenderEnv(script: script, vmID: vmID, salt: salt, version: version, dark: dark,
                    viewport: viewport, palette: palette, shadows: shadows,
                    baseTextStyle: baseTextStyle, weights: weights, prefix: prefix)
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
        if let c = paletteColor(token) {
            return c
        }
        warnOnce("unknown colour \(token)")
        return .transparent
    }

    func paletteColor(_ name: String) -> Color? {
        let value: PaletteValue
        if let cached = colorCache[name] {
            value = cached
        } else {
            value = PaletteValue(color: palette(name, dark))
            colorCache[name] = value
        }
        recordedPalette?[name] = value
        return value.color
    }

    fileprivate func recordPalette<R>(_ body: () throws -> R) rethrows -> (R, [String: PaletteValue]) {
        let previous = recordedPalette
        recordedPalette = [:]
        defer { recordedPalette = previous }
        return (try body(), recordedPalette ?? [:])
    }

    var defaultTextColor: Color {
        paletteColor("text") ?? (dark ? .white : .black)
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

internal enum BuiltinNodeKind: Hashable {
    case row, col, box, spacer, text

    func element<State>(content: String) -> El<State> {
        switch self {
        case .row: Rune.row()
        case .col: Rune.col()
        case .box: Rune.el()
        case .spacer: Rune.spacer()
        case .text: Rune.text(content).dir(.auto)
        }
    }
}

internal protocol AnyUIRenderSession: AnyObject {
    var env: UIRenderEnv { get }
    func buildContainer(_ kind: BuiltinNodeKind, args: [LuauValue]) throws -> LuauValue
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
    fileprivate let templates = LuauUIBridge.Templates()

    init(uiTable: LuauTable, viewTable: LuauTable) {
        self.uiTable = uiTable
        self.viewTable = viewTable
    }
}

internal final class UIRenderSession<State>: AnyUIRenderSession {
    let env: UIRenderEnv
    private let templates: LuauUIBridge.Templates

    fileprivate init(env: UIRenderEnv, templates: LuauUIBridge.Templates) {
        self.env = env
        self.templates = templates
    }

    func buildContainer(_ kind: BuiltinNodeKind, args: [LuauValue]) throws -> LuauValue {
        let (layers, childrenVal) = LuauUIBridge.parseContainerArgs(args)
        var el: El<State> = try LuauUIBridge.buildBuiltin(kind, layers: layers, env: env, templates: templates)
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
        let el: El<State> = try LuauUIBridge.buildBuiltin(.text, content: content, layers: layers, env: env, templates: templates)
        return .userdata(LuauUserdata(payload: LuauElBox(el, renderEpoch: env.renderEpoch), typeTag: "El"))
    }

    func buildEach(vm: LuauVM, args: [LuauValue]) throws -> LuauValue {
        guard args.count >= 4, case .table(let items) = args[0] else {
            throw LuauRuntimeError(value: .string("ui.each needs items, key, version, build"))
        }
        let keyBy = args[1]
        switch LuauUIBridge.readPropValue(keyBy) {
        case .str, .funcValue:
            break
        case let other:
            throw LuauRuntimeError(value: .string("ui.each: key must be a string or function, got \(other.typeName)"))
        }
        let versionBy = args[2]
        switch LuauUIBridge.readPropValue(versionBy) {
        case .str, .funcValue:
            break
        case let other:
            throw LuauRuntimeError(value: .string("ui.each: version must be a string or function, got \(other.typeName)"))
        }
        let buildFn = args[3]
        switch LuauUIBridge.readPropValue(buildFn) {
        case .funcValue:
            break
        case let other:
            throw LuauRuntimeError(value: .string("ui.each: build must be a function, got \(other.typeName)"))
        }
        let len = items.rawLength
        let out = LuauTable(arrayCapacity: len)

        for i in 1...max(1, len) {
            if i > len { break }
            let item = items.rawGet(i)
            let keyVal: LuauValue
            if case .str = LuauUIBridge.readPropValue(keyBy) {
                guard case .table(let it) = item else {
                    throw LuauRuntimeError(value: .string("ui.each: item \(i) is a \(item.typeName), not a table with fields"))
                }
                keyVal = it.rawGet(keyBy)
            } else {
                keyVal = try vm.call(value: keyBy, args: [item, .number(Double(i))]).first ?? .nil
            }
            let itemKey: String
            switch LuauUIBridge.readPropValue(keyVal) {
            case .str(let s):
                itemKey = s
            case .num(let n):
                itemKey = LuauValue.formatNumber(n)
            case let other:
                throw LuauRuntimeError(value: .string("ui.each: item \(i)'s key must be a string or a number, got \(other.typeName)"))
            }

            let verVal: LuauValue
            if case .str = LuauUIBridge.readPropValue(versionBy) {
                guard case .table(let it) = item else {
                    throw LuauRuntimeError(value: .string("ui.each: item \(i) is a \(item.typeName), not a table with fields"))
                }
                verVal = it.rawGet(versionBy)
            } else {
                verVal = try vm.call(value: versionBy, args: [item, .number(Double(i))]).first ?? .nil
            }
            let verHash: UInt64
            do {
                verHash = try LuauUIBridge.mixHash(LuauUIBridge.versionHash(verVal), env.salt)
            } catch let error as LuauRuntimeError {
                throw LuauRuntimeError(value: .string("ui.each: item \(i): \(error.value.displayString)"))
            }
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
        let count: Int
        switch countVal {
        case .nil: count = 0
        case .number(let value) where value.isNaN || value <= 0: count = 0
        case .number(let value) where value < Double(Int.max): count = Int(value)
        default:
            throw LuauRuntimeError(value: .string("ui.virtualList count must be a representable number"))
        }
        let estimateVal = props.rawGet("estimatedRowHeight")
        let estimate: Float
        switch estimateVal {
        case .nil:
            estimate = 32.0
        case .number(let n):
            estimate = Float(max(1.0, n))
        default:
            throw LuauRuntimeError(value: .string("ui.virtualList estimatedRowHeight must be a number, got \(estimateVal.typeName)"))
        }
        let renderRow = props.rawGet("renderRow")
        switch renderRow {
        case .nil:
            throw LuauRuntimeError(value: .string("ui.virtualList needs renderRow"))
        case .closure, .nativeFunction:
            break
        default:
            throw LuauRuntimeError(value: .string("ui.virtualList renderRow must be a function, got \(renderRow.typeName)"))
        }
        let rowKeyFn = props.rawGet("rowKey")
        switch rowKeyFn {
        case .nil, .closure, .nativeFunction:
            break
        default:
            throw LuauRuntimeError(value: .string("ui.virtualList rowKey must be a function, got \(rowKeyFn.typeName)"))
        }
        let rowErrorFn = props.rawGet("rowError")
        switch rowErrorFn {
        case .nil, .closure, .nativeFunction:
            break
        default:
            throw LuauRuntimeError(value: .string("ui.virtualList rowError must be a function, got \(rowErrorFn.typeName)"))
        }
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
        if !props.rawGet("onMiddlePress").isNil {
            env.warnOnce("ui.virtualList takes no onMiddlePress")
        }
        let gapVal = props.rawGet("gap")
        let gap: Float
        switch gapVal {
        case .nil:
            gap = 0.0
        case .number(let n):
            gap = Float(n)
        default:
            throw LuauRuntimeError(value: .string("ui.virtualList gap must be a number, got \(gapVal.typeName)"))
        }
        let keyVal = props.rawGet("key")
        let keyStr: String
        switch LuauUIBridge.readPropValue(keyVal) {
        case .nil:
            keyStr = "list"
        case .str(let s):
            keyStr = s
        case .num(let n):
            keyStr = LuauValue.formatNumber(n)
        case let other:
            throw LuauRuntimeError(value: .string("key must be a string, got \(other.typeName)"))
        }
        let containerKey = "\(env.prefix)\(keyStr)"

        let listVersionVal = props.rawGet("version")
        let keysVersion = listVersionVal.isNil ? env.version : try LuauUIBridge.versionHash(listVersionVal)
        let listVersion = LuauUIBridge.mixHash(keysVersion, env.salt)
        let rowVersionsVal = props.rawGet("rowVersions")
        let rowVersionsTbl: LuauTable?
        switch rowVersionsVal {
        case .nil:
            rowVersionsTbl = nil
        case .table(let t):
            rowVersionsTbl = t
        default:
            throw LuauRuntimeError(value: .string("ui.virtualList rowVersions must be a table, got \(rowVersionsVal.typeName)"))
        }
        let versions: [UInt64]
        if let rowVersionsTbl {
            versions = try (0..<rowVersionsTbl.rawLength).map { i in
                do {
                    return try LuauUIBridge.mixHash(LuauUIBridge.versionHash(rowVersionsTbl.rawGet(i + 1)), listVersion)
                } catch let error as LuauRuntimeError {
                    throw LuauRuntimeError(value: .string("ui.virtualList rowVersions \(i + 1): \(error.value.displayString)"))
                }
            }
        } else {
            versions = []
        }
        let scrollYVal = props.rawGet("scrollY")
        let ownScroll: Bool
        switch scrollYVal {
        case .nil:
            ownScroll = true
        case .bool(let b):
            ownScroll = b
        default:
            throw LuauRuntimeError(value: .string("ui.virtualList scrollY must be a boolean, got \(scrollYVal.typeName)"))
        }

        let ownProps: Set<String> = [
            "count", "estimatedRowHeight", "renderRow", "rowKey", "rowError", "version",
            "rowVersions", "onVisibleRows", "onPress", "onMiddlePress", "scrollY", "gap", "key",
        ]
        if MemoScope.activeCacheObject != nil {
            let base: El<State> = try LuauUIBridge.applyProps(
                [props], to: Rune.col().wFull(), isText: false, env: env, skipKeys: ownProps
            )
            func keyFor(_ state: State, _ i: Int) -> String {
                guard !rowKeyFn.isNil, let script = env.script, script.vmId == env.vmID else { return String(i) }
                return (try? script.aroundReadOptional(state: state) {
                    try script.resolveRowKey(rowKeyFn, index: i)
                }) ?? String(i)
            }
            var stack: El<State> = ownScroll ? Rune.col().wFull().key("rows") : base.key(keyStr)
            stack = stack.gap(gap).growth().virtualRows(count: count, estimatedRowHeight: estimate, key: keyFor) {
                [weak vm] state, i in
                guard let vm, let script = self.env.script, script.vmId == self.env.vmID else { return Rune.el() }
                return (try? script.aroundReadOptional(state: state) {
                    let rowKey = rowKeyFn.isNil ? String(i) : (try? script.resolveRowKey(rowKeyFn, index: i)) ?? String(i)
                    let rowID = "\(containerKey)/\(rowKey)"
                    let rowVersion = i < versions.count ? versions[i] : listVersion
                    return Rune.memo(rowID, deps: rowVersion) {
                        let rowEnv = self.env.forRow()
                        return LuauUIBridge.withSession(vm: vm, stateType: State.self, env: rowEnv) { _ in
                            script.runTimed {
                                self.renderRow(vm: vm, index: i, callback: renderRow, fallback: rowErrorFn).key(rowID)
                            }
                        }
                    }
                }) ?? Rune.el()
            }.virtualRowsVersion(rowKeyFn.isNil ? env.salt : listVersion)
            if !onVisibleRowsFn.isNil {
                stack = stack.onVisibleRows { state, range in
                    guard let script = self.env.script, script.vmId == self.env.vmID else { return false }
                    let event = Self.visibleEvent(first: range.lowerBound + 1, last: range.upperBound)
                    var scopedState: Any = state
                    script.aroundWriteOptional(state: &scopedState, tx: nil) { tx in
                        if let tx {
                            script.enter(tx: &tx.pointee) {
                                try script.callHandlerIfCurrent(vmID: self.env.vmID, fn: onVisibleRowsFn, arg: event)
                            }
                        } else {
                            script.enter {
                                try script.callHandlerIfCurrent(vmID: self.env.vmID, fn: onVisibleRowsFn, arg: event)
                            }
                        }
                    }
                    if let updated = scopedState as? State { state = updated }
                    return true
                }
            }
            let element = ownScroll ? base.scrollY().key(keyStr).child(stack) : stack
            return .userdata(LuauUserdata(payload: LuauElBox(element, renderEpoch: env.renderEpoch), typeTag: "El"))
        }

        // Detached renders expose the requested viewport immediately to Swift callers.
        env.trackedScrollKeys.append(containerKey)
        let liveScrollY = env.scrollLookup?(containerKey).y ?? 0
        let explicitH = props.rawGet("h").coercedNumber.map { Float($0) }
        let viewportHeight = max(1, explicitH ?? (env.viewport.y > 0 ? env.viewport.y : 600))

        let window = detachedListWindow(count: count, estimate: estimate, gap: gap, scrollY: liveScrollY, viewportHeight: viewportHeight)

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
                    rowKeyFn: rowKeyFn,
                    rowVersion: idx < versions.count ? versions[idx] : listVersion,
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
            "version", "rowVersions", "onVisibleRows", "onPress", "onMiddlePress", "scrollY",
        ]
        container = try LuauUIBridge.applyProps([props], to: container, isText: false, env: env, skipKeys: skipKeys)
        container = container.key(containerKey)

        if !onVisibleRowsFn.isNil {
            let visFirst = window.visibleRange.isEmpty ? 0 : window.visibleRange.lowerBound + 1
            let visLast = window.visibleRange.isEmpty ? 0 : window.visibleRange.upperBound
            if let script = env.script, script.recordVisibleRowsChange(for: containerKey, first: visFirst, last: visLast) {
                let event = Self.visibleEvent(first: visFirst, last: visLast)
                let vmID = env.vmID
                var dummyState: Any = ()
                script.aroundWriteOptional(state: &dummyState, tx: nil) { txPtr in
                    var tx = txPtr?.pointee ?? Tx()
                    script.enter(tx: &tx) {
                        try script.callHandlerIfCurrent(vmID: vmID, fn: onVisibleRowsFn, arg: event)
                    }
                    txPtr?.pointee = tx
                }
            }
        }

        return .userdata(LuauUserdata(payload: LuauElBox(container, renderEpoch: env.renderEpoch), typeTag: "El"))
    }

    private static func visibleEvent(first: Int, last: Int) -> LuauValue {
        let event = LuauTable()
        event.rawSet("kind", value: .string("visible-rows"))
        event.rawSet("first", value: .number(Double(first)))
        event.rawSet("last", value: .number(Double(last)))
        return .table(event)
    }

    private func renderRow(vm: LuauVM, index: Int, callback: LuauValue, fallback: LuauValue) -> El<State> {
        env.script?.incrementRowsMetric()
        defer { env.script?.noteSchedule() }
        do {
            let res = try vm.call(value: callback, args: [.number(Double(index + 1))]).first ?? .nil
            return try LuauUIBridge.unwrapEl(res, State.self)
        } catch {
            let message: String = switch error {
            case let rt as LuauRuntimeError: rt.toScriptError().message
            case let se as ScriptError: se.message
            default: error.localizedDescription
            }
            env.script?.logError(message)
            if !fallback.isNil,
               let result = try? vm.call(value: fallback, args: [.number(Double(index + 1)), .string(message)]).first,
               !result.isNil, let el = try? LuauUIBridge.unwrapEl(result, State.self) {
                return el
            }
            return LuauCard.rowError(message: message)
        }
    }

    @inline(never)
    private func buildVirtualRow(
        vm: LuauVM,
        idx: Int,
        containerKey: String,
        keysVersion: UInt64,
        rowKeyFn: LuauValue,
        rowVersion: UInt64,
        renderRow: LuauValue,
        rowErrorFn: LuauValue
    ) throws -> El<State> {
        let buildRow: () throws -> El<State> = {
            let resolvedRowKey: String
            if let cached = self.env.script?.cachedRowKey(for: containerKey, version: keysVersion, index: idx) {
                resolvedRowKey = cached
            } else if !rowKeyFn.isNil {
                let k = try vm.call(value: rowKeyFn, args: [.number(Double(idx + 1))]).first ?? .nil
                let s = k.isNil ? String(idx + 1) : k.displayString
                self.env.script?.storeRowKey(s, for: containerKey, version: keysVersion, index: idx)
                resolvedRowKey = s
            } else {
                resolvedRowKey = String(idx + 1)
            }

            let rowID = "\(containerKey)/\(resolvedRowKey)"
            return Rune.memo(rowID, deps: rowVersion) { () -> El<State> in
                let el = self.renderRow(vm: vm, index: idx, callback: renderRow, fallback: rowErrorFn)
                return el.keyId == nil ? el.key(rowID) : el
            }
        }
        if let script = env.script {
            return try script.aroundReadOptional(state: (), buildRow) ?? (Rune.el() as El<State>)
        }
        return try buildRow()
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
        let keyArg = args.count > 1 ? args[1] : .nil
        let keyStr: String
        switch LuauUIBridge.readPropValue(keyArg) {
        case .str(let s):
            keyStr = s
        case .num(let n):
            keyStr = LuauValue.formatNumber(n)
        case let other:
            throw LuauRuntimeError(value: .string("view:Memo key must be a string or number, got \(other.typeName)"))
        }
        let verArg = args.count > 2 ? args[2] : .nil
        let ver = try LuauUIBridge.mixHash(LuauUIBridge.versionHash(verArg), env.salt)
        let buildFn = args.count > 3 ? args[3] : .nil
        guard case .funcValue = LuauUIBridge.readPropValue(buildFn) else {
            throw LuauRuntimeError(value: .string("view:Memo needs a build function"))
        }
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

        func makeContainer(_ name: String, kind: BuiltinNodeKind) -> LuauValue {
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
        view.rawSet("Handler", value: .nativeFunction(LuauNativeFunction(name: "view:Handler") { _, _, args in
            .values([args.count > 1 ? args[1] : .nil])
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
        ctx.activeSession = UIRenderSession<State>(env: env, templates: ctx.templates)
        ctx.viewTable.rawSet("dark", value: .bool(env.dark))
        defer {
            ctx.activeSession = prevSession
            ctx.viewTable.rawSet("dark", value: prevDark)
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
                result.append((Rune.text(s) as El<State>).dir(.auto).font(env.baseTextStyle).color(env.defaultTextColor))
            case .number(let n):
                result.append((Rune.text(LuauValue.formatNumber(n)) as El<State>).dir(.auto).font(env.baseTextStyle).color(env.defaultTextColor))
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
        var menuTrigger: Bool = false
        var onMiddlePressVal: LuauValue? = nil
        var onHoverVal: LuauValue? = nil
        var canCache = true
        var role: ElementRole?
        var center = false
        var corners: (Float, Float, Float, Float)?
        var selected = false
        var truncate = false
        var singleLine = false
        var wrap = false
        var isDisabled = false
        var isSelectable = false
        var fadeOut = false
    }

    /// Mirrors `crates/rune-luau/src/ui/props.rs::Value`.
    internal enum PropValue: Sendable, Equatable {
        case `nil`
        case bool(Bool)
        case num(Double)
        case str(String)
        case funcValue
        case other(String)

        var typeName: String {
            switch self {
            case .nil: return "nil"
            case .bool: return "boolean"
            case .num: return "number"
            case .str: return "string"
            case .funcValue: return "function"
            case .other(let t): return t
            }
        }
    }

    /// Mirrors `crates/rune-luau/src/ui/props.rs::read`.
    internal static func readPropValue(_ val: LuauValue) -> PropValue {
        switch val {
        case .nil:
            return .nil
        case .bool(let b):
            return .bool(b)
        case .number(let n):
            return .num(n)
        case .string(let s):
            return .str(s)
        case .byteString(let bytes):
            // Matches `std::str::from_utf8(...).unwrap_or("")` in upstream `props.rs::read`.
            return .str(String(bytes: bytes, encoding: .utf8) ?? "")
        case .closure, .nativeFunction:
            return .funcValue
        default:
            return .other(val.typeName)
        }
    }

    private static func propNum(_ v: LuauValue, _ name: String) throws -> Float {
        let value = readPropValue(v)
        guard case .num(let d) = value else {
            throw LuauRuntimeError(value: .string("\(name) must be a number, got \(value.typeName)"))
        }
        return Float(d)
    }

    private static func propFlag(_ v: LuauValue, _ name: String) throws -> Bool {
        switch readPropValue(v) {
        case .bool(let b): return b
        case .nil: return false
        case let other:
            throw LuauRuntimeError(value: .string("\(name) must be a boolean, got \(other.typeName)"))
        }
    }

    private static func propStr(_ v: LuauValue, _ name: String) throws -> String {
        let value = readPropValue(v)
        guard case .str(let s) = value else {
            throw LuauRuntimeError(value: .string("\(name) must be a string, got \(value.typeName)"))
        }
        return s
    }

    private static func propSize(_ v: LuauValue, _ name: String) throws -> LuauSizeSpec {
        switch readPropValue(v) {
        case .num(let n):
            return .px(Float(n))
        case .str("full"):
            return .full
        case let other:
            throw LuauRuntimeError(value: .string("\(name) must be a number or \"full\", got \(other.typeName)"))
        }
    }

    private static func mapRole(_ name: String) -> ElementRole? {
        switch name {
        case "none": return .presentation
        case "group", "region", "button", "link", "switch", "checkbox", "radio", "tab",
             "list", "listitem", "heading", "img", "status", "alert":
            return ElementRole(rawValue: name)
        default: return nil
        }
    }

    @inline(never)
    private static func applySizeProp<State>(_ k: String, _ v: LuauValue, el: inout El<State>) throws -> Bool {
        switch k {
        case "w":
            switch try propSize(v, "w") {
            case .px(let px): el = el.w(px)
            case .full: el = el.wFull()
            }
        case "h":
            switch try propSize(v, "h") {
            case .px(let px): el = el.h(px)
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
            switch readPropValue(v) {
            case .str("start"): el = el.itemsStart()
            case .str("center"): el = el.itemsCenter()
            case .str("end"): el = el.itemsEnd()
            case .str("stretch"): el = el.itemsStretch()
            case let other: throw LuauRuntimeError(value: .string("align must be start, center, end or stretch, got \(other.typeName)"))
            }
        case "justify":
            switch readPropValue(v) {
            case .str("start"): el = el.justifyStart()
            case .str("center"): el = el.justifyCenter()
            case .str("end"): el = el.justifyEnd()
            case .str("between"): el = el.justifyBetween()
            case let other: throw LuauRuntimeError(value: .string("justify must be start, center, end or between, got \(other.typeName)"))
            }
        case "center":
            state.center = try propFlag(v, k)
        case "wrap":
            let b = try propFlag(v, k)
            if isText {
                state.wrap = b
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
            switch readPropValue(v) {
            case .str(let s): state.keyStr = s
            case .num(let n): state.keyStr = LuauValue.formatNumber(n)
            case let other:
                throw LuauRuntimeError(value: .string("key must be a string, got \(other.typeName)"))
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
            if !ct.isFrozen { state.canCache = false }
            state.corners = (
                Float(ct.rawGet(1).asNumber ?? 0), Float(ct.rawGet(2).asNumber ?? 0),
                Float(ct.rawGet(3).asNumber ?? 0), Float(ct.rawGet(4).asNumber ?? 0)
            )
        case "clip":
            if try propFlag(v, k) { el = el.clipSoft(0) }
        case "scrollY":
            if try propFlag(v, k) { state.scrollY = true }
        case "scrollX":
            if try propFlag(v, k) { state.scrollX = true }
        case "stickBottom": state.stickBottom = try propFlag(v, k)
        case "pin":
            guard case .table(let pt) = v else {
                throw LuauRuntimeError(value: .string("pin must be a table, got \(v.typeName)"))
            }
            if !pt.isFrozen { state.canCache = false }
            el = el.pin(
                top: pt.rawGet("top").asNumber.map(Float.init),
                right: pt.rawGet("right").asNumber.map(Float.init),
                bottom: pt.rawGet("bottom").asNumber.map(Float.init),
                left: pt.rawGet("left").asNumber.map(Float.init)
            )
        case "shadow":
            state.canCache = false
            let s = try propStr(v, k)
            if let list = env.shadows?(s, env.dark) {
                el = el.shadows(list.reversed())
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
            switch readPropValue(v) {
            case .str("regular"): state.textStyle.weight = env.weights[0]
            case .str("medium"): state.textStyle.weight = env.weights[1]
            case .str("semibold"): state.textStyle.weight = env.weights[2]
            case .str("bold"): state.textStyle.weight = env.weights[3]
            case .num(let n): state.textStyle.weight = Float(n)
            case let other:
                throw LuauRuntimeError(value: .string("weight must be regular, medium, semibold or bold, got \(other.typeName)"))
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
            if try propFlag(v, k) {
                state.wrap = false
                state.singleLine = true
            }
        case "truncate":
            state.truncate = try propFlag(v, k)
        case "textAlign":
            switch readPropValue(v) {
            case .str("start"): state.textStyle.align = .leading
            case .str("center"): state.textStyle.align = .center
            case .str("end"): state.textStyle.align = .trailing
            case let other:
                throw LuauRuntimeError(value: .string("textAlign must be start, center or end, got \(other.typeName)"))
            }
        case "focusable":
            if try propFlag(v, k) { el = el.focusable(true) }
        case "disabled":
            state.isDisabled = try propFlag(v, k)
        case "selected":
            state.selected = try propFlag(v, k)
        case "fadeOut":
            state.fadeOut = try propFlag(v, k)
        case "dir":
            switch try propStr(v, k) {
            case "auto":
                el = el.dir(.auto)
                state.textStyle.direction = nil
            case "ltr":
                el = el.dir(.ltr)
                state.textStyle.direction = .ltr
            case "rtl":
                el = el.dir(.rtl)
                state.textStyle.direction = .rtl
            case let other: throw LuauRuntimeError(value: .string("dir must be auto, ltr or rtl, got \(other)"))
            }
        case "hoverTransition":
            switch try propStr(v, k) {
            case "default": break
            case "instant": el = el.hoverMotion(Anim<Float>.instant, Anim<Float>.instant)
            case let other: throw LuauRuntimeError(value: .string("hoverTransition must be default or instant, got \(other)"))
            }
        case "hoverGroup":
            if try propFlag(v, k) { el = el.hoverGroup() }
        case "hoverGroupColor":
            el = el.groupColor(try env.resolveColor(try propStr(v, k)))
        case "revealOnHover":
            if try propFlag(v, k) { el = el.groupOpacity(0, 1) }
        case "helpSide":
            switch readPropValue(v) {
            case .str("top"): el = el.helpSide(.top)
            case .str("right"): el = el.helpSide(.right)
            case .str("left"): el = el.helpSide(.left)
            default: break
            }
        case "onPress": state.onPressVal = v
        case "menuTrigger": state.menuTrigger = try propFlag(v, k)
        case "onMiddlePress": state.onMiddlePressVal = v
        case "onHover": state.onHoverVal = v
        case "role":
            let s = try propStr(v, k)
            guard let r = mapRole(s) else {
                throw LuauRuntimeError(value: .string("unknown role \(s)"))
            }
            state.role = r
        default:
            return false
        }
        return true
    }

    @inline(never)
    private static func finalizeAppliedProps<State>(_ el: inout El<State>, state: ApplyPropState, isText: Bool, env: UIRenderEnv) {
        if let callback = state.onPressVal, !state.isDisabled {
            let handler = Handler(fn: callback, vmID: env.vmID, script: env.script)
            el = Press(handler: handler, key: state.keyStr).attach(el, menuTrigger: state.menuTrigger)
        }
        if let onMiddlePressVal = state.onMiddlePressVal, !state.isDisabled {
            let capturedKey = state.keyStr
            let scriptRef = env.script
            let vmID = env.vmID
            el = el.onMiddlePress { st, tx in
                guard let script = scriptRef else { return }
                let m = script.pressEventMods(tx.mods)
                let ev = LuauTable()
                ev.rawSet("kind", value: .string("middle-press"))
                if let capturedKey { ev.rawSet("key", value: .string(capturedKey)) }
                ev.rawSet("shift", value: .bool(m.shift))
                ev.rawSet("alt", value: .bool(m.alt))
                ev.rawSet("mod", value: .bool(m.mod))
                script.aroundWrite(state: &st, tx: &tx) { innerTx in
                    script.enter(tx: &innerTx) {
                        try script.callHandlerIfCurrent(vmID: vmID, fn: onMiddlePressVal, arg: .table(ev))
                    }
                }
            }
        }
        if let onHoverVal = state.onHoverVal {
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
        if let role = state.role { el = el.role(role) }
        if state.center { el = el.center() }
        if let (tl, tr, br, bl) = state.corners { el = el.corners(tl, tr, br, bl) }
        if state.selected {
            if let color = env.paletteColor("selected") { el = el.bg(color) }
            el = el.focusSelected(true)
        }
        if state.isDisabled { el = el.disabled(true) }
        if isText {
            el = el.font(state.textStyle).color(state.textColor ?? env.defaultTextColor)
            if state.truncate { el = el.truncate() }
            if state.fadeOut {
                el = el.truncateFade()
            }
            if state.singleLine { el = el.singleLine() }
            if state.wrap { el = el.wrapText() }
            if state.isSelectable {
                el = el.selectable(true)
            }
        } else {
            if let c = state.textColor {
                el = el.color(c)
            }
        }
        if state.borderWidth != nil || state.borderColor != nil {
            let c = state.borderColor ?? env.paletteColor("separator") ?? .transparent
            el = el.border(state.borderWidth ?? 1.0, c)
        }
        if state.scrollX && state.scrollY {
            el = el.scrollXY()
        } else if state.scrollX {
            el = el.scrollX()
        } else if state.scrollY {
            el = el.scrollY(stickBottom: state.stickBottom)
        }
        if let k = state.keyStr {
            el = el.key(k)
        }
    }

    fileprivate final class Templates {
        struct Key: Hashable {
            let table: ObjectIdentifier
            let kind: BuiltinNodeKind
            let stateType: ObjectIdentifier
        }

        // The VM can serve windows with different Swift state types.
        private var entries: [Key: AnyObject] = [:]

        subscript(key: Key) -> AnyObject? { entries[key] }

        func insert(_ template: AnyObject, for key: Key) {
            if entries.count >= 1_024 { entries.removeAll(keepingCapacity: true) }
            entries[key] = template
        }
    }

    private final class Template<State> {
        // Retain the frozen table for as long as its address is used as a cache key.
        let table: LuauTable
        let under: El<State>
        let props: ApplyPropState
        let finished: El<State>
        let dark: Bool
        let colors: [String: UIRenderEnv.PaletteValue]
        var checkedEpoch: UInt64

        init(table: LuauTable, under: El<State>, props: ApplyPropState, finished: El<State>,
             env: UIRenderEnv, colors: [String: UIRenderEnv.PaletteValue]) {
            self.table = table
            self.under = under
            self.props = props
            self.finished = finished
            self.dark = env.dark
            self.colors = colors
            self.checkedEpoch = env.renderEpoch
        }

        func isCurrent(in env: UIRenderEnv) -> Bool {
            if checkedEpoch == env.renderEpoch { return true }
            guard dark == env.dark, colors.allSatisfy({ env.paletteColor($0.key) == $0.value.color }) else { return false }
            checkedEpoch = env.renderEpoch
            return true
        }
    }

    fileprivate static func buildBuiltin<State>(
        _ kind: BuiltinNodeKind, content: String = "", layers: [LuauTable], env: UIRenderEnv, templates: Templates
    ) throws -> El<State> {
        let isText = kind == .text
        guard let style = layers.first, style.isFrozen else {
            return try applyProps(layers, to: kind.element(content: content), isText: isText, env: env)
        }
        let key = Templates.Key(table: ObjectIdentifier(style), kind: kind, stateType: ObjectIdentifier(State.self))
        var el: El<State>
        var state: ApplyPropState
        if let cached = templates[key] as? Template<State>, cached.isCurrent(in: env) {
            if layers.count == 1 {
                el = cached.finished
                if isText { el.plainText = content }
                return el
            }
            el = cached.under
            state = cached.props
        } else {
            // Store the style without this node's children, string, or handlers.
            el = kind.element(content: "")
            state = ApplyPropState(textStyle: env.baseTextStyle)
            let (finished, colors) = try env.recordPalette { () throws -> El<State>? in
                try decodeProps(style, el: &el, state: &state, isText: isText, env: env)
                guard state.canCache, state.onPressVal == nil, state.onMiddlePressVal == nil, state.onHoverVal == nil else { return nil }
                var finished = el
                finalizeAppliedProps(&finished, state: state, isText: isText, env: env)
                return finished
            }
            if var finished {
                templates.insert(Template(table: style, under: el, props: state, finished: finished, env: env, colors: colors), for: key)
                if layers.count == 1 {
                    if isText { finished.plainText = content }
                    return finished
                }
            }
        }
        if isText { el.plainText = content }
        for own in layers.dropFirst() {
            try decodeProps(own, el: &el, state: &state, isText: isText, env: env)
        }
        finalizeAppliedProps(&el, state: state, isText: isText, env: env)
        return el
    }

    private static func decodeProps<State>(
        _ table: LuauTable, el: inout El<State>, state: inout ApplyPropState,
        isText: Bool, env: UIRenderEnv, skipKeys: Set<String> = []
    ) throws {
        for key in table.hashOrder {
            guard case .string(let k) = key, let v = table.hash[key], !v.isNil, !skipKeys.contains(k) else { continue }
            if try applySizeProp(k, v, el: &el) { continue }
            if try applySpacingLayoutProp(k, v, el: &el, state: &state, isText: isText) { continue }
            if try applyVisualProp(k, v, el: &el, state: &state, env: env) { continue }
            if try applyTextAndBehaviorProp(k, v, el: &el, state: &state, env: env) { continue }
            env.warnOnce("unknown prop \(k)")
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
            try decodeProps(tbl, el: &el, state: &state, isText: isText, env: env, skipKeys: skipKeys)
        }
        finalizeAppliedProps(&el, state: state, isText: isText, env: env)
        return el
    }

    internal static func versionHash(_ val: LuauValue) throws -> UInt64 {
        var h = Hasher()
        switch readPropValue(val) {
        case .nil:
            h.combine(UInt8(0))
        case .bool(let b):
            h.combine(UInt8(1))
            h.combine(b)
        case .num(let n):
            h.combine(UInt8(2))
            h.combine(n.bitPattern)
        case .str(let s):
            h.combine(UInt8(3))
            h.combine(s.utf8.count)
            for byte in s.utf8 { h.combine(byte) }
        case let other:
            throw LuauRuntimeError(value: .string("a memo version must be nil, a boolean, a number or a string, got \(other.typeName)"))
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
