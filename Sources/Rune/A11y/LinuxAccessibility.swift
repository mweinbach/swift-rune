#if os(Linux)
import CRuneLinuxA11y
import Foundation
import RuneMotion

/// Projects the live Rune tree into the desktop's AT-SPI registry. All tree access and
/// assistive requests run on the SDL thread; the descriptor watcher only wakes that thread.
final class LinuxAccessibilityHost {
    private let waker: Waker
    private let overlay: Bool
    private let projectOnDemand: (LinuxAccessibilityHost) -> Void
    private var publishing = false
    private var window: OpaquePointer?
    private var lastRoot: AccessibilityNode?
    private var lastTitle = ""
    private var lastWindowFocused = false
    private var lastWindowRect: [Int32] = []
    // Keep the properties exported to ATK separate from their moving window bounds.
    // Most virtual rows retain the same semantic node while the viewport scrolls.
    private struct Semantics: Equatable {
        let role: ElementRole
        let name: TextUTF8Key
        let help, value, shortcut: TextUTF8Key?
        let state, actions: UInt32
        let selection: SIMD2<Int32>
        let range: A11yRange?
    }
    private struct Published {
        let parent: TextUTF8Key?
        let index: Int
        let semantics: Semantics
        let box: SIMD4<Int32>
        let offscreen: Bool
        let children: [AccessibilityNode]
    }
    private var published: [TextUTF8Key: Published] = [:]
    private var nextPublished: [TextUTF8Key: Published] = [:]
    private var hasAnnouncements = false
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

    private var fields: [TextUTF8Key: Field] = [:]
    private var nextFields: [TextUTF8Key: Field] = [:]

    private enum Request {
        case action(String, AccessibilityAction, AccessibilityActionValue?)
        case edit(String, Range<Int>, replacement: String?)
    }
    private var requests: [Request] = []

    init(title: String, waker: Waker, isVisible: Bool = true, overlay: Bool = false,
         projectOnDemand: @escaping (LinuxAccessibilityHost) -> Void) {
        self.overlay = overlay
        self.waker = waker
        self.projectOnDemand = projectOnDemand
        self.lastTitle = title
        let open = overlay ? rune_ax_open_overlay : rune_ax_open
        self.window = open(title, isVisible ? 1 : 0, { context in
            guard let context else { return }
            Unmanaged<Waker>.fromOpaque(context).takeUnretainedValue().wake()
        }, Unmanaged.passUnretained(waker).toOpaque())
        rune_ax_set_projection_callback(window, { context in
            guard let context else { return }
            let host = Unmanaged<LinuxAccessibilityHost>.fromOpaque(context).takeUnretainedValue()
            host.projectOnDemand(host)
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit { rune_ax_close(window) }

    func setVisible(_ visible: Bool) { rune_ax_visible(window, visible ? 1 : 0) }

    func serviceDemand<State>(runtime: Runtime<State>) {
        guard let window, lastWindowRect.count >= 2, !publishing else { return }
        let readerNeedsTree = rune_ax_is_active(window) != 0
        let treeIsPublished = !published.isEmpty
        if readerNeedsTree != treeIsPublished {
            update(runtime: runtime, windowX: lastWindowRect[0], windowY: lastWindowRect[1])
        }
    }

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
        // A reader can attach or leave while the window has no scheduled frame.
        serviceDemand(runtime: runtime)
        return changed
    }

    private func drain() {
        let service = overlay ? rune_ax_take_requests : rune_ax_pump
        service(window, { context, target, kind, text, number, start, end in
            guard let context, let target else { return }
            let host = Unmanaged<LinuxAccessibilityHost>.fromOpaque(context).takeUnretainedValue()
            let id = String(cString: target)
            switch Int(kind) {
            case RUNE_AX_PRESS: host.requests.append(.action(id, .press, nil))
            case RUNE_AX_FOCUS: host.requests.append(.action(id, .focus, nil))
            case RUNE_AX_INCREMENT: host.requests.append(.action(id, .increment, nil))
            case RUNE_AX_DECREMENT: host.requests.append(.action(id, .decrement, nil))
            case RUNE_AX_SCROLL_INTO_VIEW: host.requests.append(.action(id, .scrollIntoView, nil))
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
        guard let window, !publishing else { return }
        publishing = true
        defer { publishing = false }
        let width = pixel(runtime.viewport.x), height = pixel(runtime.viewport.y)
        let title = runtime.windowTitle ?? lastTitle
        let windowRect = [windowX, windowY, width, height]
        if lastTitle != title || lastWindowRect != windowRect || lastWindowFocused != runtime.windowFocused {
            rune_ax_begin(window, title, windowX, windowY, width, height, runtime.windowFocused ? 1 : 0)
        }
        lastTitle = title
        lastWindowRect = windowRect
        lastWindowFocused = runtime.windowFocused
        guard rune_ax_is_active(window) != 0 else {
            if !published.isEmpty {
                for key in published.keys { rune_ax_remove(window, key.source) }
                published.removeAll()
                fields.removeAll()
                lastRoot = nil
            }
            return
        }
        var root = runtime.nativeAccessibilitySnapshot()
        if runtime.a11yAnnouncement.count != 0 {
            root.children.append(AccessibilityTreeState.announcerNode(runtime.a11yAnnouncement, holdWords: false))
        }
        hasAnnouncements = false
        publish(root, parent: nil, index: 0, clip: .fromXYWH(0, 0, runtime.viewport.x, runtime.viewport.y), place: false)
        for key in published.keys where nextPublished[key] == nil { rune_ax_remove(window, key.source) }
        swap(&published, &nextPublished)
        nextPublished.removeAll(keepingCapacity: true)
        swap(&fields, &nextFields)
        nextFields.removeAll(keepingCapacity: true)
        if hasAnnouncements, let lastRoot {
            for announcement in AccessibilityTreeBuilder.liveAnnouncements(previous: lastRoot, current: root) {
                rune_ax_announce(window, announcement.text, announcement.politeness == .assertive ? 1 : 0)
            }
        } else if lastRoot == nil, runtime.a11yAnnouncement.recent(), let words = runtime.a11yAnnouncement.words {
            // Match the upstream attach window for words spoken while a reader was starting.
            rune_ax_announce(window, words.text, words.politeness == .assertive ? 1 : 0)
        }
        lastRoot = root
        // The caret or horizontal input offset can change while the semantic frame stays still.
        refreshTextGeometry(runtime: runtime, window: window)
    }

    private func publish(_ node: AccessibilityNode, parent: TextUTF8Key?, index: Int, clip: MotionRect, place: Bool) {
        // Runtime paths distinguish namesakes, including links with the same label. Synthetic
        // children without a path keep their authored id scoped to their projected parent.
        let key = TextUTF8Key(node.runtimePath.map { "runtime:" + $0 } ?? "\(parent?.source ?? "")/node:\(index):\(node.id)")
        let target = node.runtimePath ?? node.id
        let visible = intersectRects(node.frame, clip)
        let offscreen = visible.width <= 0 || visible.height <= 0
        var state = 0
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

        // AT-SPI Component.ScrollTo accepts every runtime element, including a field
        // already in view. The optional scroll hint resolves to its owning element.
        var actions = node.runtimePath == nil ? 0 : RUNE_AX_SCROLL_INTO_VIEW
        for action in node.actions {
            switch action {
            case .press: actions |= RUNE_AX_PRESS
            case .focus: actions |= RUNE_AX_FOCUS
            case .increment: actions |= RUNE_AX_INCREMENT
            case .decrement: actions |= RUNE_AX_DECREMENT
            case .setValue: actions |= node.range == nil ? RUNE_AX_SET_TEXT : RUNE_AX_SET_NUMBER
            case .scrollIntoView: actions |= RUNE_AX_SCROLL_INTO_VIEW
            }
        }
        var properties = RuneA11yProperties()
        properties.x = pixel(node.frame.left.rounded(.down))
        properties.y = pixel(node.frame.top.rounded(.down))
        properties.width = pixel(max(0, node.frame.right.rounded(.up) - node.frame.left.rounded(.down)))
        properties.height = pixel(max(0, node.frame.bottom.rounded(.up) - node.frame.top.rounded(.down)))
        properties.state = UInt32(state | (offscreen ? RUNE_AX_OFFSCREEN : 0))
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
        let semantics = Semantics(role: node.role, name: TextUTF8Key(AccessibilityDump.resolvedName(for: node) ?? ""),
                                  help: node.help.map(TextUTF8Key.init), value: node.isSecure ? nil : text.map(TextUTF8Key.init),
                                  shortcut: node.keyboardShortcut.map(TextUTF8Key.init), state: UInt32(state), actions: UInt32(actions),
                                  selection: SIMD2(properties.anchor, properties.caret), range: node.range)
        let box = SIMD4(properties.x, properties.y, properties.width, properties.height)
        let old = published[key]
        if place || old?.semantics != semantics || old?.parent != parent || old?.index != index {
            rune_ax_node(window, key.source, parent?.source, Int32(clamping: index), target, node.role.rawValue,
                         semantics.name.source, node.help ?? "", semantics.value?.source, node.keyboardShortcut, properties)
        } else if old?.box != box || old?.offscreen != offscreen {
            rune_ax_geometry(window, key.source, box.x, box.y, box.z, box.w, offscreen ? 1 : 0)
        }
        nextPublished[key] = Published(parent: parent, index: index, semantics: semantics, box: box,
                                       offscreen: offscreen, children: node.children)
        if !node.isSecure && (node.liveRegion != nil || node.isModal || node.role == .dialog || node.role == .alertDialog) {
            hasAnnouncements = true
        }
        let mayReplace = old?.semantics.role != semantics.role || old?.semantics.actions != semantics.actions
        if !node.isSecure, node.role == .textInput || node.role == .multilineTextInput, let path = node.runtimePath {
            nextFields[key] = Field(key: key.source, target: path, clip: visible, geometry: mayReplace ? nil : fields[key]?.geometry)
        }
        // A changed ATK interface can recreate the parent. Insertions and removals can
        // also displace a sibling whose own index happens to match its previous index.
        let placeChildren = mayReplace || !Self.sameChildren(old?.children ?? [], node.children)
        let childClip = node.clipsChildren ? visible : clip
        for (i, child) in node.children.enumerated() {
            publish(child, parent: key, index: i, clip: childClip, place: placeChildren)
        }
    }

    private static func sameChildren(_ previous: [AccessibilityNode], _ current: [AccessibilityNode]) -> Bool {
        guard previous.count == current.count else { return false }
        return zip(previous, current).allSatisfy { old, new in
            switch (old.runtimePath, new.runtimePath) {
            case let (a?, b?): return TextUTF8Key.equalBytes(a, b)
            case (nil, nil): return TextUTF8Key.equalBytes(old.id, new.id)
            default: return false
            }
        }
    }

    private func refreshTextGeometry<State>(runtime: Runtime<State>, window: OpaquePointer) {
        for (key, field) in fields {
            let layout = runtime.accessibilityTextLayout(target: field.target, clip: field.clip)
            let source = layout.map {
                GeometrySource(box: ObjectIdentifier($0.box), width: $0.box.maxWidth, origin: $0.origin,
                               scale: $0.scale, clip: $0.clip, commit: runtime.commitCount)
            }
            if let source, field.geometry == source { continue }
            fields[key]?.geometry = source
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
