#if os(Linux)
import CRuneLinuxA11y
import Foundation
import RuneMotion

/// Projects the live Rune tree into the desktop's AT-SPI registry. All tree access and
/// assistive requests run on the SDL thread; the descriptor watcher only wakes that thread.
final class LinuxAccessibilityHost {
    private let waker: Waker
    private var window: OpaquePointer?
    private var lastRoot: AccessibilityNode?
    private var lastTitle = ""
    private var lastWindowFocused = false
    private var lastWindowRect: [Int32] = []
    private struct Field {
        let key, target: String
        let clip: MotionRect
        var geometry: GeometrySource?
    }

    private struct GeometrySource: Equatable {
        let box: ObjectIdentifier
        let width: Float?
        let origin, scale: Vec2
        let clip: MotionRect
        let commit: UInt64
    }

    private var fields: [Field] = []

    private enum Request {
        case action(String, AccessibilityAction, AccessibilityActionValue?)
        case edit(String, Range<Int>, replacement: String?)
    }
    private var requests: [Request] = []

    init(title: String, waker: Waker, isVisible: Bool = true) {
        self.waker = waker
        self.lastTitle = title
        self.window = rune_ax_open(title, isVisible ? 1 : 0, { context in
            guard let context else { return }
            Unmanaged<Waker>.fromOpaque(context).takeUnretainedValue().wake()
        }, Unmanaged.passUnretained(waker).toOpaque())
    }

    deinit { rune_ax_close(window) }

    func setVisible(_ visible: Bool) { rune_ax_visible(window, visible ? 1 : 0) }

    @discardableResult
    func pump<State>(runtime: Runtime<State>, at now: Double, requestWindowFocus: () -> Void = {}) -> Bool {
        guard window != nil else { return false }
        drain()
        var changed = false
        for request in requests {
            switch request {
            case let .action(id, action, value):
                if runtime.accessibilityAction(id, action, value: value, at: now) {
                    if action == .focus && !runtime.windowFocused { requestWindowFocus() }
                    changed = true
                }
            case let .edit(id, scalarRange, replacement):
                guard let idx = runtime.a11yTargetIndex(id), runtime.a11yAllowed(idx) else { continue }
                let el = runtime.flatNodes[idx].el
                guard el.hasEditAccess, !el.isSecure, let lens = el.handlers.editLens else { continue }
                let field = lens.get(runtime.state)
                guard !field.isSecure else { continue }
                let scalars = field.text.unicodeScalars
                guard let lower = scalars.index(scalars.startIndex, offsetBy: scalarRange.lowerBound, limitedBy: scalars.endIndex),
                      let upper = scalars.index(lower, offsetBy: scalarRange.count, limitedBy: scalars.endIndex) else { continue }
                let utf8 = field.text.utf8
                let range = utf8.distance(from: utf8.startIndex, to: lower)..<utf8.distance(from: utf8.startIndex, to: upper)
                if let replacement {
                    let edited = runtime.a11yEdit(index: idx, at: now) { edit in
                        edit.setSelectionRaw(anchor: range.lowerBound, cursor: range.upperBound)
                        if replacement.isEmpty {
                            if !range.isEmpty { edit.deleteForward() }
                        } else {
                            edit.paste(replacement)
                        }
                    }
                    changed = changed || edited
                } else if runtime.accessibilitySelectText(id, range: range, at: now) {
                    changed = true
                }
            }
        }
        requests.removeAll(keepingCapacity: true)
        return changed
    }

    private func drain() {
        rune_ax_pump(window, { context, target, kind, text, number, start, end in
            guard let context, let target else { return }
            let host = Unmanaged<LinuxAccessibilityHost>.fromOpaque(context).takeUnretainedValue()
            let id = String(cString: target)
            switch Int(kind) {
            case RUNE_AX_PRESS: host.requests.append(.action(id, .press, nil))
            case RUNE_AX_FOCUS: host.requests.append(.action(id, .focus, nil))
            case RUNE_AX_INCREMENT: host.requests.append(.action(id, .increment, nil))
            case RUNE_AX_DECREMENT: host.requests.append(.action(id, .decrement, nil))
            case RUNE_AX_SET_TEXT:
                if let text { host.requests.append(.action(id, .setValue, .text(String(cString: text)))) }
            case RUNE_AX_SET_NUMBER: host.requests.append(.action(id, .setValue, .number(number)))
            case RUNE_AX_SELECT_TEXT, RUNE_AX_REPLACE_TEXT:
                if start >= 0 && end >= start {
                    host.requests.append(.edit(id, Int(start)..<Int(end), replacement: text.map(String.init(cString:))))
                }
            default: break
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func update<State>(runtime: Runtime<State>, windowX: Int32, windowY: Int32) {
        guard let window else { return }
        let width = pixel(runtime.viewport.x), height = pixel(runtime.viewport.y)
        let title = runtime.windowTitle ?? lastTitle
        let windowRect = [windowX, windowY, width, height]
        var root = runtime.accessibilitySnapshot()
        if runtime.a11yAnnouncement.count != 0 {
            root.children.append(AccessibilityTreeState.announcerNode(runtime.a11yAnnouncement, holdWords: false))
        }
        // Horizontal input scrolling and paint transforms can move glyphs inside an
        // unchanged semantic frame. Refresh the retained fields after every drawn frame.
        defer { refreshTextGeometry(runtime: runtime, window: window) }
        guard lastRoot != root || lastTitle != title || lastWindowRect != windowRect || lastWindowFocused != runtime.windowFocused else { return }
        let announcements = AccessibilityTreeBuilder.liveAnnouncements(previous: lastRoot, current: root)
        lastRoot = root
        lastTitle = title
        lastWindowRect = windowRect
        lastWindowFocused = runtime.windowFocused
        fields.removeAll(keepingCapacity: true)
        rune_ax_begin(window, title, windowX, windowY, width, height, runtime.windowFocused ? 1 : 0)
        publish(root, parent: nil, index: 0, clip: .fromXYWH(0, 0, runtime.viewport.x, runtime.viewport.y))
        rune_ax_end(window)
        for announcement in announcements {
            rune_ax_announce(window, announcement.text, announcement.politeness == .assertive ? 1 : 0)
        }
    }

    private func publish(_ node: AccessibilityNode, parent: String?, index: Int, clip: MotionRect) {
        // Runtime paths distinguish namesakes, including links with the same label. Synthetic
        // children without a path keep their authored id scoped to their projected parent.
        let key = node.runtimePath.map { "runtime:" + $0 } ?? "\(parent ?? "")/node:\(index):\(node.id)"
        let target = node.runtimePath ?? node.id
        let visible = intersectRects(node.frame, clip)
        var state = 0
        if visible.width <= 0 || visible.height <= 0 { state |= RUNE_AX_OFFSCREEN }
        if node.isDisabled { state |= RUNE_AX_DISABLED }
        if node.isFocusable { state |= RUNE_AX_FOCUSABLE }
        if node.isFocused && lastWindowFocused { state |= RUNE_AX_FOCUSED }
        if node.selectedState != nil { state |= RUNE_AX_SELECTABLE }
        if node.isSelected { state |= RUNE_AX_SELECTED }
        if node.isExpanded != nil { state |= RUNE_AX_EXPANDABLE }
        if node.isExpanded == true { state |= RUNE_AX_EXPANDED }
        if node.isReadOnly { state |= RUNE_AX_READ_ONLY }
        if node.isBusy { state |= RUNE_AX_BUSY }
        if node.isInvalid { state |= RUNE_AX_INVALID }
        if node.isModal { state |= RUNE_AX_MODAL }
        if node.toggled != nil || [.switchControl, .checkbox, .radio, .menuItemCheckbox, .menuItemRadio].contains(node.role) {
            state |= RUNE_AX_CHECKABLE
            let checked = node.toggled ?? node.value.flatMap(A11yChecked.init(rawValue:))
            if checked == .trueState { state |= RUNE_AX_CHECKED }
            if checked == .mixed { state |= RUNE_AX_MIXED }
        }

        var actions = 0
        for action in node.actions {
            switch action {
            case .press: actions |= RUNE_AX_PRESS
            case .focus: actions |= RUNE_AX_FOCUS
            case .increment: actions |= RUNE_AX_INCREMENT
            case .decrement: actions |= RUNE_AX_DECREMENT
            case .setValue: actions |= node.range == nil ? RUNE_AX_SET_TEXT : RUNE_AX_SET_NUMBER
            }
        }
        var properties = RuneA11yProperties()
        properties.x = pixel(node.frame.left.rounded(.down))
        properties.y = pixel(node.frame.top.rounded(.down))
        properties.width = pixel(max(0, node.frame.right.rounded(.up) - node.frame.left.rounded(.down)))
        properties.height = pixel(max(0, node.frame.bottom.rounded(.up) - node.frame.top.rounded(.down)))
        properties.state = UInt32(state)
        properties.anchor = -1
        properties.caret = -1
        if !node.isSecure, actions & RUNE_AX_SET_TEXT != 0, let selection = node.textSelection,
           selection.count == 4, selection[0] == 0, selection[2] == 0, let value = node.value {
            properties.anchor = scalarOffset(selection[1], in: value)
            properties.caret = scalarOffset(selection[3], in: value)
            actions |= RUNE_AX_SELECT_TEXT | RUNE_AX_REPLACE_TEXT
        }
        properties.actions = UInt32(actions)
        if let range = node.range {
            properties.minimum = range.min
            properties.maximum = range.max
            properties.value = range.value
            properties.step = range.step ?? 0
        }
        let text: String?
        switch node.role {
        case .text, .heading, .mark, .code: text = node.value ?? node.label
        default: text = node.value
        }
        rune_ax_node(window, key, parent, Int32(clamping: index), target, node.role.rawValue,
                     AccessibilityDump.resolvedName(for: node) ?? "", node.help ?? "", node.isSecure ? nil : text, node.keyboardShortcut, properties)
        if !node.isSecure, node.role == .textInput || node.role == .multilineTextInput, let path = node.runtimePath {
            fields.append(Field(key: key, target: path, clip: visible))
        }
        let childClip = node.clipsChildren ? visible : clip
        for (i, child) in node.children.enumerated() {
            publish(child, parent: key, index: i, clip: childClip)
        }
    }

    private func refreshTextGeometry<State>(runtime: Runtime<State>, window: OpaquePointer) {
        for index in fields.indices {
            let field = fields[index]
            let layout = runtime.accessibilityTextLayout(target: field.target, clip: field.clip)
            let source = layout.map {
                GeometrySource(box: ObjectIdentifier($0.box), width: $0.box.maxWidth, origin: $0.origin,
                               scale: $0.scale, clip: $0.clip, commit: runtime.commitCount)
            }
            if let source, field.geometry == source { continue }
            fields[index].geometry = source
            // On Linux SDL and AT-SPI expose the same window logical coordinates, even
            // when the GPU drawable has a higher pixel density than the window.
            guard let cells = layout?.cells(unit: .unicodeScalars, pixelScale: 1) else {
                rune_ax_text_geometry(window, field.key, nil, 0)
                continue
            }
            let native = cells.map {
                RuneA11yTextCell(start: $0.start, end: $0.end, line: $0.line,
                                 x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
            native.withUnsafeBufferPointer {
                rune_ax_text_geometry(window, field.key, $0.baseAddress, Int32($0.count))
            }
        }
    }

    private func scalarOffset(_ byteOffset: Int, in text: String) -> Int32 {
        let utf8 = text.utf8
        let index = utf8.index(utf8.startIndex, offsetBy: max(0, byteOffset), limitedBy: utf8.endIndex) ?? utf8.endIndex
        guard let scalar = index.samePosition(in: text.unicodeScalars) else { return -1 }
        return Int32(clamping: text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: scalar))
    }

    private func pixel(_ value: Float) -> Int32 {
        guard value.isFinite else { return 0 }
        return Int32(clamping: Int64(max(Double(Int32.min), min(Double(Int32.max), Double(value)))))
    }
}
#endif
