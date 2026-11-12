import Foundation
import Rune
import RuneMotion

/// A saved preset entry for a group.
public struct SavedKnobPreset: Sendable, Equatable, Codable {
    public var name: String
    public var values: [String: Float]

    public init(name: String, values: [String: Float]) {
        self.name = name
        self.values = values
    }
}

/// Serializable JSON snapshot of knob values, typed values, presets, and panel width.
public struct KnobSnapshot: Sendable, Equatable, Codable {
    public var version: Int
    public var values: [String: Float]
    public var typedValues: [String: KnobValue]
    public var saved: [String: [SavedKnobPreset]]
    public var kept: [String: Float]
    public var active: [String: String]
    public var width: Float

    public init(
        version: Int = 1,
        values: [String: Float] = [:],
        typedValues: [String: KnobValue] = [:],
        saved: [String: [SavedKnobPreset]] = [:],
        kept: [String: Float] = [:],
        active: [String: String] = [:],
        width: Float = 0
    ) {
        self.version = version
        self.values = values
        self.typedValues = typedValues
        self.saved = saved
        self.kept = kept
        self.active = active
        self.width = width
    }
}

/// Live-tuning state store (`rune_knobs::Knobs`).
public struct Knobs: Sendable, Equatable {
    /// Whether the floating overlay / side panel is currently visible.
    public var open: Bool = false
    /// Modified scalar values keyed by `Knob.name`. Unmodified knobs return their default.
    public var values: [String: Float] = [:]
    /// Modified typed values (colors, text, vec2, spring, etc.) keyed by `Knob.name`.
    public var typedValues: [String: KnobValue] = [:]
    /// User-saved presets per group name.
    public var saved: [String: [SavedKnobPreset]] = [:]
    /// Kept baseline values for `revert` / `differs`.
    public var kept: [String: Float] = [:]
    /// Currently selected group name.
    public var group: String? = nil
    /// Region picker mode.
    public var picking: Bool = false
    /// Settled reference values (for storybook dots).
    public var settled: [String: Float]? = nil
    /// Dragged side panel width (0 uses `RuneKnobsDefaults.sideW`).
    public var width: Float = 0
    /// Folded and unfolded section/group names.
    public var folded: Set<String> = []
    public var unfolded: Set<String> = []
    /// Search / filter query string.
    public var query: String = ""
    /// Whether the filter field is actively editing.
    public var filtering: Bool = false
    /// Filter field text-editing model.
    public var edit: TextEdit = TextEdit()
    /// Selected page tab in `.tabs` layout.
    public var tab: String? = nil
    /// Side-panel keyboard row cursor.
    public var treeAt: KnobTreeNode? = nil
    /// Long choice knob currently expanded.
    public var expanded: String? = nil
    /// Group whose region is currently outlined.
    public var hoverGroup: String? = nil
    /// Keyboard cursor index within current group.
    public var cursor: Int = 0
    /// Whether keyboard navigation is driving the panel.
    public var kbd: Bool = false
    /// Hovered knob name.
    public var hot: String? = nil
    /// Hovered choice option `(knobName, optionIndex)`.
    public var hotOpt: (String, Int)? = nil
    /// Knob currently being dragged.
    public var drag: String? = nil
    /// Active preset name per group.
    public var active: [String: String] = [:]
    /// Undo/redo stacks.
    public var undoStack: [[String: Float]] = []
    public var redoStack: [[String: Float]] = []
    private var seed: UInt64 = 0x9E3779B97F4A7C15

    public init() {}

    public static func == (lhs: Knobs, rhs: Knobs) -> Bool {
        lhs.open == rhs.open &&
        lhs.values == rhs.values &&
        lhs.typedValues == rhs.typedValues &&
        lhs.saved == rhs.saved &&
        lhs.kept == rhs.kept &&
        lhs.group == rhs.group &&
        lhs.picking == rhs.picking &&
        lhs.settled == rhs.settled &&
        lhs.width == rhs.width &&
        lhs.folded == rhs.folded &&
        lhs.unfolded == rhs.unfolded &&
        lhs.query == rhs.query &&
        lhs.filtering == rhs.filtering &&
        lhs.edit == rhs.edit &&
        lhs.tab == rhs.tab &&
        lhs.treeAt == rhs.treeAt &&
        lhs.expanded == rhs.expanded &&
        lhs.hoverGroup == rhs.hoverGroup &&
        lhs.cursor == rhs.cursor &&
        lhs.kbd == rhs.kbd &&
        lhs.hot == rhs.hot &&
        lhs.hotOpt?.0 == rhs.hotOpt?.0 &&
        lhs.hotOpt?.1 == rhs.hotOpt?.1 &&
        lhs.drag == rhs.drag &&
        lhs.active == rhs.active &&
        lhs.undoStack == rhs.undoStack &&
        lhs.redoStack == rhs.redoStack
    }

    // MARK: - Panel Metrics & Springs

    public func slide() -> Spring {
        Spring(duration: get(RuneKnobsDefaults.slideTime), bounce: get(RuneKnobsDefaults.slideBounce))
    }

    public func foldSpring() -> Spring {
        Spring(duration: get(RuneKnobsDefaults.foldTime), bounce: 0.0)
    }

    public func sideW() -> Float {
        width > 0 ? min(max(width, RuneKnobsDefaults.sideMin), RuneKnobsDefaults.sideMax) : RuneKnobsDefaults.sideW
    }

    public func sideRoom() -> Float {
        open ? sideW() : 0
    }

    // MARK: - Scalar & Typed Getters / Setters

    public func get(_ knob: Knob) -> Float {
        let raw = values[knob.name] ?? knob.default
        return knob.clamp(raw)
    }

    public mutating func set(_ knob: Knob, _ value: Float) {
        values[knob.name] = knob.clamp(value)
    }

    public func getInt(_ knob: Knob) -> Int {
        if case .int(let i) = typedValues[knob.name] { return i }
        return Int(get(knob).rounded())
    }

    public mutating func setInt(_ knob: Knob, _ value: Int) {
        let clamped = Int(knob.clamp(Float(value)).rounded())
        values[knob.name] = Float(clamped)
        typedValues[knob.name] = .int(clamped)
    }

    public func getBool(_ knob: Knob) -> Bool {
        if case .bool(let b) = typedValues[knob.name] { return b }
        return get(knob) >= 0.5
    }

    public mutating func setBool(_ knob: Knob, _ value: Bool) {
        values[knob.name] = value ? 1.0 : 0.0
        typedValues[knob.name] = .bool(value)
    }

    public func getColor(_ knob: Knob) -> Color {
        if case .color(let c) = typedValues[knob.name] { return c }
        return knob.defaultColor ?? .white
    }

    public mutating func setColor(_ knob: Knob, _ value: Color) {
        typedValues[knob.name] = .color(value)
    }

    public func getText(_ knob: Knob) -> String {
        if case .text(let s) = typedValues[knob.name] { return s }
        return knob.defaultText ?? ""
    }

    public mutating func setText(_ knob: Knob, _ value: String) {
        typedValues[knob.name] = .text(value)
    }

    public func getVec2(_ knob: Knob) -> Vec2 {
        if case .vec2(let x, let y) = typedValues[knob.name] { return Vec2(x, y) }
        let d = knob.defaultVec2 ?? [0, 0]
        return Vec2(d.count > 0 ? d[0] : 0, d.count > 1 ? d[1] : 0)
    }

    public mutating func setVec2(_ knob: Knob, _ value: Vec2) {
        values[knob.name] = knob.clamp(value.x)
        typedValues[knob.name] = .vec2(x: value.x, y: value.y)
    }

    public func getSpring(_ knob: Knob) -> Spring {
        if case .spring(let d, let b) = typedValues[knob.name] {
            return Spring(duration: d, bounce: b)
        }
        return Spring(
            duration: knob.defaultSpringDuration ?? 0.3,
            bounce: knob.defaultSpringBounce ?? 0.0
        )
    }

    public mutating func setSpring(_ knob: Knob, _ value: Spring) {
        values[knob.name] = knob.clamp(value.duration)
        typedValues[knob.name] = .spring(duration: value.duration, bounce: value.bounce)
    }

    public func getValue(_ knob: Knob) -> KnobValue {
        if let v = typedValues[knob.name] { return v }
        switch knob.kind {
        case .float: return .float(get(knob))
        case .int: return .int(getInt(knob))
        case .bool: return .bool(getBool(knob))
        case .color: return .color(getColor(knob))
        case .text: return .text(getText(knob))
        case .select: return .select(getInt(knob))
        case .vec2:
            let v = getVec2(knob)
            return .vec2(x: v.x, y: v.y)
        case .spring:
            let s = getSpring(knob)
            return .spring(duration: s.duration, bounce: s.bounce)
        }
    }

    public mutating func setValue(_ knob: Knob, _ value: KnobValue) {
        switch value {
        case .float(let v):
            set(knob, v)
            typedValues[knob.name] = .float(get(knob))
        case .int(let i):
            setInt(knob, i)
        case .bool(let b):
            setBool(knob, b)
        case .color(let c):
            setColor(knob, c)
        case .text(let s):
            setText(knob, s)
        case .select(let i):
            setInt(knob, i)
            typedValues[knob.name] = .select(getInt(knob))
        case .vec2(let x, let y):
            setVec2(knob, Vec2(x, y))
        case .spring(let d, let b):
            setSpring(knob, Spring(duration: d, bounce: b))
        }
    }

    // MARK: - Folding & Visibility

    public func isFolded(_ name: String, byDefault: Bool) -> Bool {
        if folded.contains(name) { return true }
        if unfolded.contains(name) { return false }
        return byDefault
    }

    public mutating func setFolded(_ name: String, _ fold: Bool) {
        if fold {
            unfolded.remove(name)
            folded.insert(name)
        } else {
            folded.remove(name)
            unfolded.insert(name)
        }
    }

    public mutating func show() {
        if !open {
            let keep = group.flatMap { unfolded.contains($0) ? $0 : nil }
            folded.removeAll()
            unfolded.removeAll()
            if let keep { unfolded.insert(keep) }
        }
        open = true
        picking = false
        kbd = false
        hoverGroup = nil
    }

    public mutating func close() {
        open = false
        picking = false
        hoverGroup = nil
        kbd = false
        stopFilter()
        hot = nil
        hotOpt = nil
        drag = nil
    }

    public mutating func toggle() {
        if open { close() } else { show() }
    }

    public mutating func pickRegion() {
        picking = true
        hoverGroup = nil
    }

    public func current(in groups: [KnobGroup]) -> KnobGroup? {
        if picking { return nil }
        if let g = group, let found = groups.first(where: { $0.name == g }) {
            return found
        }
        return groups.first
    }

    public mutating func hover(_ name: String, option: Int? = nil) {
        hot = name
        hotOpt = option.map { (name, $0) }
    }

    public mutating func pick(_ groupName: String) {
        if group != groupName {
            cursor = 0
        }
        group = groupName
        setFolded(groupName, false)
        picking = false
        hoverGroup = nil
    }

    // MARK: - Search / Filter

    public mutating func setQuery(_ q: String) {
        query = q
        syncEdit()
    }

    public mutating func syncEdit() {
        if edit.text != query {
            edit.setText(query)
        }
    }

    public mutating func filter(_ q: String) {
        setQuery(q)
        startFilter()
    }

    public mutating func startFilter() {
        syncEdit()
        filtering = true
        edit.selectAll()
    }

    public mutating func stopFilter() {
        filtering = false
    }

    public mutating func edited() {
        query = edit.text
    }

    // MARK: - Keyboard Navigation

    public mutating func panelKey(groups: [KnobGroup], event: KeyEvent) -> Bool {
        if event.mods.cmd || event.mods.alt || event.mods.ctrl || filtering {
            return false
        }
        if event.key == .escape {
            close()
            return true
        }
        guard let g = current(in: groups) ?? groups.first else { return false }
        let n = g.knobs.count
        switch event.key {
        case .arrowUp, .arrowDown:
            guard n > 0 else { return false }
            let delta = (event.key == .arrowDown) ? 1 : -1
            let next = ((cursor.clamped(to: 0...(n - 1)) + delta) % n + n) % n
            cursor = next
        case .arrowLeft, .arrowRight:
            guard n > 0 else { return false }
            let idx = min(cursor, n - 1)
            step(g.knobs[idx], up: event.key == .arrowRight, big: event.mods.shift)
        case .tab:
            guard !groups.isEmpty else { return false }
            let i = groups.firstIndex(where: { $0.name == g.name }) ?? 0
            let delta = event.mods.shift ? -1 : 1
            let next = ((i + delta) % groups.count + groups.count) % groups.count
            pick(groups[next].name)
        case .text(let t) where t == "[" || t == "]":
            guard !groups.isEmpty else { return false }
            let i = groups.firstIndex(where: { $0.name == g.name }) ?? 0
            let delta = (t == "[") ? -1 : 1
            let next = ((i + delta) % groups.count + groups.count) % groups.count
            pick(groups[next].name)
        default:
            return false
        }
        kbd = true
        return true
    }

    public mutating func step(_ knob: Knob, up: Bool, big: Bool) {
        let isChoice = !knob.labels.isEmpty
        let baseUnit: Float = if isChoice {
            1.0
        } else if knob.step > 0.0 {
            knob.step
        } else {
            (knob.max - knob.min) / 100.0
        }
        let unit = (big && !isChoice) ? baseUnit * 10.0 : baseUnit
        let before = get(knob)
        checkpoint()
        set(knob, before + (up ? unit : -unit))
        if get(knob) == before && undoStack.last == values {
            _ = undoStack.popLast()
        }
    }

    // MARK: - Undo / Redo / Keep / Revert / Reset / Random

    public func canReset(_ group: KnobGroup) -> Bool {
        let anyChanged = group.knobs.contains { k in
            abs(get(k) - k.default) > 1e-4 || typedValues[k.name] != nil
        }
        if anyChanged { return true }
        if let a = active[group.name], drifted(group, name: a) {
            return true
        }
        return false
    }

    public mutating func checkpoint() {
        if undoStack.last != values {
            undoStack.append(values)
            if undoStack.count > 100 {
                undoStack.removeFirst()
            }
        }
        redoStack.removeAll()
    }

    public mutating func change(_ knob: Knob, _ value: Float) {
        if abs(get(knob) - knob.clamp(value)) > 1e-6 {
            checkpoint()
            set(knob, value)
        }
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard let prev = undoStack.popLast() else { return false }
        redoStack.append(values)
        values = prev
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        undoStack.append(values)
        values = next
        return true
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func keptValue(_ knob: Knob) -> Float {
        knob.clamp(kept[knob.name] ?? knob.default)
    }

    public func differs(_ knob: Knob) -> Bool {
        abs(get(knob) - keptValue(knob)) > 1e-4
    }

    public mutating func keep() {
        kept = values
    }

    public mutating func keepSome(_ knobs: [Knob]) {
        for k in knobs {
            if let v = values[k.name] {
                kept[k.name] = v
            } else {
                kept.removeValue(forKey: k.name)
            }
        }
    }

    public mutating func revert(_ knobs: [Knob]) {
        guard knobs.contains(where: { differs($0) }) else { return }
        checkpoint()
        for k in knobs {
            if let v = kept[k.name] {
                values[k.name] = v
            } else {
                values.removeValue(forKey: k.name)
            }
        }
    }

    public mutating func random(_ group: KnobGroup) {
        checkpoint()
        if seed == 0 { seed = 1 }
        for k in group.knobs {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            let f = Float(seed >> 40) / Float(1 << 24)
            set(k, k.min + f * (k.max - k.min))
        }
    }

    public mutating func resetKnob(_ knob: Knob) {
        if values[knob.name] != nil || typedValues[knob.name] != nil {
            checkpoint()
            values.removeValue(forKey: knob.name)
            typedValues.removeValue(forKey: knob.name)
        }
    }

    public mutating func reset(_ group: KnobGroup) {
        if let activeName = active[group.name], drifted(group, name: activeName) {
            apply(group, name: activeName)
        } else {
            checkpoint()
            for k in group.knobs {
                values.removeValue(forKey: k.name)
                typedValues.removeValue(forKey: k.name)
            }
            active.removeValue(forKey: group.name)
        }
    }

    public mutating func resetAll() {
        guard !values.isEmpty || !typedValues.isEmpty else { return }
        checkpoint()
        values.removeAll()
        typedValues.removeAll()
        active.removeAll()
    }

    // MARK: - Presets & Code Export

    public func preset(_ group: KnobGroup, name: String) -> [String: Float]? {
        var out: [String: Float] = [:]
        for k in group.knobs {
            out[k.name] = k.default
        }
        if let p = group.presets.first(where: { $0.name == name }) {
            for (k, v) in p.values { out[k] = v }
            return out
        }
        if let s = saved[group.name]?.first(where: { $0.name == name }) {
            let valid = Set(group.knobs.map(\.name))
            for (k, v) in s.values where valid.contains(k) {
                out[k] = v
            }
            return out
        }
        if name == RuneKnobsDefaults.defaultPresetName {
            return out
        }
        return nil
    }

    public mutating func apply(_ group: KnobGroup, name: String) {
        guard let vals = preset(group, name: name) else { return }
        checkpoint()
        for k in group.knobs {
            let v = vals[k.name] ?? k.default
            if v == k.default {
                values.removeValue(forKey: k.name)
            } else {
                set(k, v)
            }
        }
        if name == RuneKnobsDefaults.defaultPresetName {
            active.removeValue(forKey: group.name)
        } else {
            active[group.name] = name
        }
    }

    public func activePreset(_ group: KnobGroup) -> String {
        active[group.name] ?? RuneKnobsDefaults.defaultPresetName
    }

    public func drifted(_ group: KnobGroup, name: String) -> Bool {
        guard let vals = preset(group, name: name) else { return false }
        return group.knobs.contains { k in
            abs(get(k) - k.clamp(vals[k.name] ?? k.default)) > 1e-4
        }
    }

    @discardableResult
    public mutating func savePreset(_ group: KnobGroup) -> String {
        let existing = saved[group.name] ?? []
        var n = 1
        while existing.contains(where: { $0.name == "Saved \(n)" }) {
            n += 1
        }
        let name = "Saved \(n)"
        var vals: [String: Float] = [:]
        for k in group.knobs {
            vals[k.name] = get(k)
        }
        saved[group.name, default: []].append(SavedKnobPreset(name: name, values: vals))
        active[group.name] = name
        return name
    }

    public mutating func deletePreset(_ group: KnobGroup, name: String) {
        saved[group.name]?.removeAll { $0.name == name }
        if active[group.name] == name {
            active.removeValue(forKey: group.name)
        }
    }

    public func code(_ group: KnobGroup) -> String {
        group.knobs.map { k in
            let v = get(k)
            let formatted = trimFloat(v)
            let idx = Int(v)
            if idx >= 0 && idx < k.labels.count {
                return "\(k.name) = \(formatted) (\(k.labels[idx]))"
            }
            return "\(k.name) = \(formatted)"
        }.joined(separator: "\n")
    }

    // MARK: - JSON Snapshot Import / Export / Persistence

    public func snapshot() -> KnobSnapshot {
        KnobSnapshot(
            values: values,
            typedValues: typedValues,
            saved: saved,
            kept: kept,
            active: active,
            width: width
        )
    }

    public mutating func applySnapshot(_ snap: KnobSnapshot) {
        checkpoint()
        values = snap.values
        typedValues = snap.typedValues
        saved = snap.saved
        kept = snap.kept
        active = snap.active
        if snap.width > 0 { width = snap.width }
    }

    public func exportJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        var fmt: JSONEncoder.OutputFormatting = [.sortedKeys]
        if prettyPrinted { fmt.insert(.prettyPrinted) }
        encoder.outputFormatting = fmt
        return try encoder.encode(snapshot())
    }

    public func exportJSONString(prettyPrinted: Bool = true) throws -> String {
        let data = try exportJSON(prettyPrinted: prettyPrinted)
        return String(decoding: data, as: UTF8.self)
    }

    public mutating func importJSON(_ data: Data) throws {
        let snap = try JSONDecoder().decode(KnobSnapshot.self, from: data)
        applySnapshot(snap)
    }

    public mutating func importJSONString(_ json: String) throws {
        try importJSON(Data(json.utf8))
    }

    public func save(to url: URL) throws {
        let data = try exportJSON(prettyPrinted: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public mutating func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        try importJSON(data)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

func trimFloat(_ v: Float) -> String {
    var s = String(format: "%.3f", v)
    while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) {
        s.removeLast()
    }
    return s == "-0" ? "0" : s
}

// MARK: - Thread-Safe KnobRegistry & Reactive Handles

/// Thread-safe registry of knobs and live reactive handles.
public final class KnobRegistry: @unchecked Sendable {
    public static let shared = KnobRegistry()

    private let lock = NSLock()
    private var store = Knobs()
    private var descriptors: [String: Knob] = [:]
    private var observers: [String: [(UUID, @Sendable (KnobValue) -> Void)]] = [:]

    public init(initial: Knobs = Knobs()) {
        self.store = initial
    }

    @discardableResult
    public func register(_ knob: Knob) -> Knob {
        lock.lock()
        descriptors[knob.name] = knob
        lock.unlock()
        return knob
    }

    public func descriptor(for name: String) -> Knob? {
        lock.lock()
        defer { lock.unlock() }
        return descriptors[name]
    }

    public func allDescriptors() -> [Knob] {
        lock.lock()
        defer { lock.unlock() }
        return descriptors.values.sorted { $0.name < $1.name }
    }

    public func snapshotKnobs() -> Knobs {
        lock.lock()
        defer { lock.unlock() }
        return store
    }

    public func withKnobs<R>(_ body: (inout Knobs) -> R) -> R {
        lock.lock()
        let result = body(&store)
        lock.unlock()
        return result
    }

    public func get(_ knob: Knob) -> Float {
        lock.lock()
        descriptors[knob.name] = knob
        let val = store.get(knob)
        lock.unlock()
        return val
    }

    public func set(_ knob: Knob, _ value: Float) {
        lock.lock()
        descriptors[knob.name] = knob
        store.set(knob, value)
        let newVal = store.getValue(knob)
        let list = observers[knob.name] ?? []
        lock.unlock()
        for (_, cb) in list { cb(newVal) }
    }

    public func getValue(_ knob: Knob) -> KnobValue {
        lock.lock()
        descriptors[knob.name] = knob
        let val = store.getValue(knob)
        lock.unlock()
        return val
    }

    public func setValue(_ knob: Knob, _ value: KnobValue) {
        lock.lock()
        descriptors[knob.name] = knob
        store.setValue(knob, value)
        let newVal = store.getValue(knob)
        let list = observers[knob.name] ?? []
        lock.unlock()
        for (_, cb) in list { cb(newVal) }
    }

    public func reset(_ knob: Knob) {
        lock.lock()
        store.resetKnob(knob)
        let newVal = store.getValue(knob)
        let list = observers[knob.name] ?? []
        lock.unlock()
        for (_, cb) in list { cb(newVal) }
    }

    public func resetAll() {
        lock.lock()
        store.resetAll()
        let allObs = observers
        let descs = descriptors
        let currentStore = store
        lock.unlock()
        for (name, list) in allObs {
            guard let k = descs[name] else { continue }
            let val = currentStore.getValue(k)
            for (_, cb) in list { cb(val) }
        }
    }

    @discardableResult
    public func observe(_ knobName: String, handler: @escaping @Sendable (KnobValue) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        observers[knobName, default: []].append((id, handler))
        lock.unlock()
        return id
    }

    public func removeObserver(_ knobName: String, id: UUID) {
        lock.lock()
        observers[knobName]?.removeAll { $0.0 == id }
        lock.unlock()
    }

    public func handle(_ knob: Knob) -> KnobHandle {
        register(knob)
        return KnobHandle(knob: knob, registry: self)
    }

    public func exportJSON(prettyPrinted: Bool = true) throws -> Data {
        lock.lock()
        let copy = store
        lock.unlock()
        return try copy.exportJSON(prettyPrinted: prettyPrinted)
    }

    public func importJSON(_ data: Data) throws {
        lock.lock()
        try store.importJSON(data)
        let allObs = observers
        let descs = descriptors
        let currentStore = store
        lock.unlock()
        for (name, list) in allObs {
            guard let k = descs[name] else { continue }
            let val = currentStore.getValue(k)
            for (_, cb) in list { cb(val) }
        }
    }

    public func save(to url: URL) throws {
        lock.lock()
        let copy = store
        lock.unlock()
        try copy.save(to: url)
    }

    public func load(from url: URL) throws {
        let data = try Data(contentsOf: url)
        try importJSON(data)
    }
}

/// Reactive handle bound to a `Knob` in a `KnobRegistry`.
public struct KnobHandle: Sendable {
    public let knob: Knob
    public let registry: KnobRegistry

    public init(knob: Knob, registry: KnobRegistry = .shared) {
        self.knob = knob
        self.registry = registry
        registry.register(knob)
    }

    public var floatValue: Float {
        get { registry.get(knob) }
        nonmutating set { registry.set(knob, newValue) }
    }

    public var intValue: Int {
        get { registry.getValue(knob).intValue ?? Int(knob.default.rounded()) }
        nonmutating set { registry.setValue(knob, .int(newValue)) }
    }

    public var boolValue: Bool {
        get { registry.getValue(knob).boolValue ?? (knob.default >= 0.5) }
        nonmutating set { registry.setValue(knob, .bool(newValue)) }
    }

    public var colorValue: Color {
        get { registry.getValue(knob).colorValue ?? (knob.defaultColor ?? .white) }
        nonmutating set { registry.setValue(knob, .color(newValue)) }
    }

    public var textValue: String {
        get { registry.getValue(knob).textValue ?? (knob.defaultText ?? "") }
        nonmutating set { registry.setValue(knob, .text(newValue)) }
    }

    public var vec2Value: Vec2 {
        get { registry.getValue(knob).vec2Value ?? .zero }
        nonmutating set { registry.setValue(knob, .vec2(x: newValue.x, y: newValue.y)) }
    }

    public var springValue: Spring {
        get { registry.getValue(knob).springValue ?? Spring(duration: 0.3, bounce: 0.0) }
        nonmutating set { registry.setValue(knob, .spring(duration: newValue.duration, bounce: newValue.bounce)) }
    }

    public var value: KnobValue {
        get { registry.getValue(knob) }
        nonmutating set { registry.setValue(knob, newValue) }
    }

    public func reset() {
        registry.reset(knob)
    }

    @discardableResult
    public func onChange(_ handler: @escaping @Sendable (KnobValue) -> Void) -> UUID {
        registry.observe(knob.name, handler: handler)
    }
}

/// Top-level `RuneKnobs` namespace for keyboard shortcuts and panel builders.
public enum RuneKnobs {
    /// `⌘⇧K` toggles the panel and `Esc` closes it (`rune_knobs::key`).
    @discardableResult
    public static func key(_ knobs: inout Knobs, event: KeyEvent) -> Bool {
        switch event.key {
        case .command(let ch) where (ch == "k" || ch == "K") && event.mods.shift:
            knobs.toggle()
            return true
        case .text(let s) where (s == "k" || s == "K") && event.mods.primaryCommand && event.mods.shift:
            knobs.toggle()
            return true
        case .escape where knobs.open:
            knobs.close()
            return true
        default:
            return false
        }
    }
}
