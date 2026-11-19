import Foundation
import RuneMotion

/// Android virtual IDs survive reordering and are retired when the element unmounts.
final class AndroidSemanticTree {
    struct Node: Encodable, Equatable {
        let id: Int32
        let parent: Int32
        let role, name: String
        let value, help: String?
        let rect: [Int32]
        let focused, focusable, disabled, selected, secure, readOnly: Bool
        let checked: String?
        let range: A11yRange?
        let selection: [Int]?
        let liveRegion: LiveRegionPoliteness?
        let actions: [AccessibilityAction]
    }

    private var ids: [AccessibilityIdentity: Int32] = [:]
    private var nextID: Int32 = 1
    private(set) var targets: [Int32: String] = [:]

    func project(_ root: AccessibilityNode, viewport: MotionRect, scale: Float) -> [Node] {
        var updated: [AccessibilityIdentity: Int32] = [:]
        var paths: [Int32: String] = [:]
        var result: [Node] = []
        func pixel(_ point: Float) -> Int32 {
            let value = (Double(point) * Double(scale)).rounded()
            return value.isFinite ? Int32(min(Double(Int32.max), max(Double(Int32.min), value))) : 0
        }
        func add(_ node: AccessibilityNode, identity: AccessibilityIdentity, parent: Int32, clip: MotionRect) {
            let id: Int32
            if let existing = ids[identity] { id = existing }
            else {
                guard nextID < Int32.max else { return }
                id = nextID
                nextID += 1
            }
            updated[identity] = id
            paths[id] = node.runtimePath ?? node.id
            let rect = MotionRect(left: max(clip.left, node.frame.left), top: max(clip.top, node.frame.top),
                                  right: min(clip.right, node.frame.right), bottom: min(clip.bottom, node.frame.bottom))
            let checked = node.toggled?.rawValue ?? ([ElementRole.checkbox, .switchControl, .radio, .menuItemCheckbox, .menuItemRadio].contains(node.role)
                ? (node.value == "mixed" ? "mixed" : (node.value == "true" || node.isSelected ? "true" : "false")) : nil)
            var selection: [Int]?
            if !node.isSecure, [.textInput, .multilineTextInput, .searchbox].contains(node.role), let value = node.value,
               let range = node.textSelection, range.count == 4 {
                selection = [range[1], range[3]].map { ImeUTF16Bridge.utf16Offset(in: value, fromUTF8Offset: $0) }
            }
            result.append(Node(id: id, parent: parent, role: node.role.rawValue,
                               name: AccessibilityDump.resolvedName(for: node) ?? "", value: node.isSecure ? nil : node.value,
                               help: node.help ?? node.placeholder, rect: [pixel(rect.left), pixel(rect.top), pixel(rect.right), pixel(rect.bottom)],
                               focused: node.isFocused, focusable: node.isFocusable, disabled: node.isDisabled,
                               selected: node.isSelected, secure: node.isSecure, readOnly: node.isReadOnly,
                               checked: checked, range: node.range, selection: selection,
                               liveRegion: node.liveRegion, actions: node.actions))
            var occurrences: [String: Int] = [:]
            for child in node.children {
                add(child, identity: AccessibilityIdentity(child, parent: identity, occurrences: &occurrences),
                    parent: id, clip: node.clipsChildren ? rect : clip)
            }
        }
        var occurrences: [String: Int] = [:]
        add(root, identity: AccessibilityIdentity(root, parent: nil, occurrences: &occurrences), parent: -1, clip: viewport)
        ids = updated
        targets = paths
        return result
    }
}

extension TextEdit {
    /// Android deletes on either side of the selection and preserves that selection. Keep secure
    /// model bytes in Swift while respecting Android's two distinct definitions of a character.
    mutating func deleteAndroidSurrounding(before: Int, after: Int, codePoints: Bool) {
        guard before >= 0, after >= 0 else { return }
        let original = text
        let selected = selectedUTF8Range
        let left = original.utf8.index(original.utf8.startIndex, offsetBy: selected.lowerBound)
        let right = original.utf8.index(original.utf8.startIndex, offsetBy: selected.upperBound)
        let from: Int, to: Int
        if codePoints {
            let units = original.unicodeScalars
            let lower = units.index(left, offsetBy: -before, limitedBy: units.startIndex) ?? units.startIndex
            let upper = units.index(right, offsetBy: after, limitedBy: units.endIndex) ?? units.endIndex
            from = original.utf8.distance(from: original.startIndex, to: lower)
            to = original.utf8.distance(from: original.startIndex, to: upper)
        } else {
            let units = original.utf16
            let lower = units.distance(from: units.startIndex, to: left)
            let upper = units.distance(from: units.startIndex, to: right)
            from = ImeUTF16Bridge.utf8Offset(in: original, fromUTF16Offset: lower - min(before, lower))
            let end = upper + min(after, units.count - upper)
            var boundary = units.index(units.startIndex, offsetBy: end)
            if boundary.samePosition(in: original.unicodeScalars) == nil { units.formIndex(after: &boundary) }
            to = original.utf8.distance(from: original.startIndex, to: boundary)
        }
        guard from != selected.lowerBound || to != selected.upperBound else { return }
        let reversed = anchor > cursor
        let preserved = String(original[left..<right])
        setSelectionRaw(anchor: from, cursor: to)
        insert(preserved)
        let end = from + preserved.utf8.count
        setSelectionRaw(anchor: reversed ? end : from, cursor: reversed ? from : end)
    }
}

#if os(Android)
import CRuneAndroid

@MainActor
private final class AndroidSemanticActions {
    var perform: ((String, Int32, Data) -> Bool)?
}

@MainActor
final class AndroidSemanticBridge<State> {
    // Android IMEs address the full document in UTF-16. Passwords publish no model context.
    private struct Mirror: Encodable, Equatable {
        let key, text: String
        let secure: Bool
        let anchor, focus: Int
        static func == (a: Self, b: Self) -> Bool {
            a.key == b.key && a.secure == b.secure && a.anchor == b.anchor && a.focus == b.focus
                && a.text.utf8.elementsEqual(b.text.utf8)
        }
    }
    private struct Field: Encodable, Equatable {
        var mirror: Mirror?
        var multiline = false
    }
    private struct Snapshot: Encodable, Equatable {
        let nodes: [AndroidSemanticTree.Node]
        let announcement: String?
        let announcementCount: UInt32
    }
    private struct Edit: Decodable {
        var key: String?
        var text: String?
        var expected: String?
        var base: Int?
        var anchor: Int?
        var focus: Int?
        var number: Double?
        var before, after: Int?
        var points: Bool?
    }

    private let runtime: Runtime<State>
    private let receiver = AndroidSemanticActions()
    private let tree = AndroidSemanticTree()
    private var peer: OpaquePointer?
    private var previousTree: Snapshot?
    private var previousField: Field?
    private var wasObserved = false

    init(activity: UnsafeMutableRawPointer, runtime: Runtime<State>) {
        self.runtime = runtime
        receiver.perform = { [weak self] in self?.perform($0, id: $1, data: $2) ?? false }
        peer = rune_android_semantics_open(activity, Unmanaged.passUnretained(receiver).toOpaque()) { box, name, id, bytes, size in
            guard let box, let name else { return 0 }
            let owner = Unmanaged<AndroidSemanticActions>.fromOpaque(box).takeUnretainedValue()
            let data = bytes.map { Data(bytes: $0, count: Int(size)) } ?? Data()
            return MainActor.assumeIsolated { owner.perform?(String(cString: name), id, data) == true ? 1 : 0 }
        }
    }

    var isAttached: Bool { peer != nil }

    func close() {
        rune_android_semantics_close(peer)
        peer = nil
    }

    private func publish<T: Encodable>(_ value: T, tree: Bool) {
        guard let bytes = try? JSONEncoder().encode(value), let count = Int32(exactly: bytes.count) else { return }
        bytes.withUnsafeBytes { raw in rune_android_semantics_publish(peer, tree ? 1 : 0, raw.bindMemory(to: UInt8.self).baseAddress, count) }
    }

    private func field() -> Field {
        guard let key = runtime.focusedPath, let el = runtime.focusedInputElement(at: key), el.hasEditAccess,
              let lens = el.handlers.editLens else { return Field() }
        let edit = lens.get(runtime.state)
        let secure = el.isSecure || edit.isSecure
        let mirror = Mirror(key: key, text: secure ? "" : edit.text, secure: secure,
                            anchor: secure ? 0 : ImeUTF16Bridge.utf16Offset(in: edit.text, fromUTF8Offset: edit.anchor),
                            focus: secure ? 0 : ImeUTF16Bridge.utf16Offset(in: edit.text, fromUTF8Offset: edit.cursor))
        return Field(mirror: mirror, multiline: edit.multiline)
    }

    func refresh() {
        guard peer != nil else { return }
        let field = field()
        if field != previousField {
            previousField = field
            publish(field, tree: false)
        }
        let observed = rune_android_semantics_reader(peer) != 0
        defer { wasObserved = observed }
        guard observed else { previousTree = nil; return }
        let root = runtime.nativeAccessibilitySnapshot()
        let nodes = tree.project(root, viewport: .fromXYWH(0, 0, runtime.viewport.x, runtime.viewport.y), scale: runtime.pixelScale)
        let announcement = runtime.a11yAnnouncement
        let snapshot = Snapshot(nodes: nodes, announcement: announcement.spokenText, announcementCount: announcement.count)
        if !wasObserved || previousTree != snapshot {
            previousTree = snapshot
            publish(snapshot, tree: true)
        }
    }

    private func perform(_ operation: String, id: Int32, data: Data) -> Bool {
        if operation == "refresh" {
            previousField = nil
            refresh()
            return true
        }
        guard let edit = data.isEmpty ? Edit() : try? JSONDecoder().decode(Edit.self, from: data) else { return false }
        let t = runtime.currentTime
        defer { runtime.waker.wake() }
        if let target = tree.targets[id] {
            if let action = AccessibilityAction(rawValue: operation) {
                let value = edit.number.map(AccessibilityActionValue.number) ?? edit.text.map(AccessibilityActionValue.text)
                return runtime.accessibilityAction(target, action, value: value, at: t)
            }
            if operation == "selectText", let el = runtime.a11yTargetIndex(target).map({ runtime.flatNodes[$0].el }),
               el.hasEditAccess, let value = el.handlers.editLens?.get(runtime.state), !value.isSecure, !el.isSecure,
               let anchor = edit.anchor, let focus = edit.focus, anchor >= 0, focus >= 0,
               max(anchor, focus) <= value.text.utf16.count {
                let lo = ImeUTF16Bridge.utf8Offset(in: value.text, fromUTF16Offset: min(anchor, focus))
                let hi = ImeUTF16Bridge.utf8Offset(in: value.text, fromUTF16Offset: max(anchor, focus))
                return runtime.accessibilitySelectText(target, range: lo..<hi, at: t)
            }
            return false
        }
        guard id == -1, let key = edit.key, key == runtime.focusedPath,
              let el = runtime.focusedInputElement(at: key), el.hasEditAccess,
              let value = el.handlers.editLens?.get(runtime.state) else { return false }
        let secure = el.isSecure || value.isSecure
        switch operation {
        case "return": return runtime.keyDown(KeyEvent(key: .enter), at: t)
        case "secureInsert" where secure:
            guard let text = edit.text, !text.isEmpty else { return false }
            return runtime.keyDown(KeyEvent(key: .text(text)), at: t)
        case "secureDelete" where secure:
            guard let lens = el.handlers.editLens, let before = edit.before, let after = edit.after,
                  before >= 0, after >= 0 else { return false }
            var changed = value
            changed.deleteAndroidSurrounding(before: before, after: after, codePoints: edit.points == true)
            if value != changed { runtime.deliverInputEdit(el: el, previousEdit: value, newEdit: changed, editLens: lens, at: t) }
            return true
        case "preedit" where !secure:
            let text = edit.text ?? ""
            let cursor = ImeUTF16Bridge.utf8Offset(in: text, fromUTF16Offset: edit.focus ?? text.utf16.count)
            return runtime.dispatchImeEvent(.preedit(text, cursorUTF8: cursor..<cursor, clauses: []), at: t)
        case "edit", "selection":
            guard !secure, let expected = edit.expected, let base = edit.base,
                  let anchor = edit.anchor, let focus = edit.focus else { return false }
            if value.preedit != nil { _ = runtime.dispatchImeEvent(.preedit("", cursorUTF8: nil, clauses: []), at: t) }
            return runtime.applyNativeFieldChange(key: key, base: base, expected: expected,
                text: operation == "edit" ? edit.text : nil, anchor: anchor, focus: focus, at: t)
        default: return false
        }
    }
}
#endif
