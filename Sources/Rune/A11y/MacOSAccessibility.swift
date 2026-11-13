import Foundation

#if os(macOS) && canImport(AppKit)
import AppKit
#endif

// MARK: - Cross-Platform Runtime Accessibility Projection & Action Dispatch

public extension AccessibilityTreeBuilder {
    /// Projects a flattened `[ElementInfo]` array from `Runtime.elements()` into a nested `AccessibilityNode` tree.
    /// Secure text fields (`securePaths.contains(path)` or `role == .textInput && text == nil`) never leak `value`.
    static func project(
        elements: [ElementInfo],
        focusedPath: String?,
        viewport: Vec2,
        securePaths: Set<String> = []
    ) -> AccessibilityNode {
        var childrenByParent: [Int: [Int]] = [:]
        var roots: [Int] = []
        for (idx, info) in elements.enumerated() where !info.inert {
            if let parent = info.parentIndex {
                childrenByParent[parent, default: []].append(idx)
            } else {
                roots.append(idx)
            }
        }

        func build(_ idx: Int) -> AccessibilityNode {
            let info = elements[idx]
            let isSecure = securePaths.contains(info.path) || (info.role == .textInput && info.text == nil)
            var actions: [AccessibilityAction] = []
            if info.role == .button || info.role == .checkbox || info.role == .switchControl ||
                info.role == .radio || info.role == .tab || info.role == .menuItem {
                actions.append(.press)
            }
            if info.focusable {
                actions.append(.focus)
            }
            if info.role == .slider {
                actions.append(.increment)
                actions.append(.decrement)
            }

            let rect = info.rect.count >= 4
                ? MotionRect.fromXYWH(info.rect[0], info.rect[1], info.rect[2], info.rect[3])
                : .zero

            let projectedValue: String? = isSecure ? nil : info.text
            let projectedLabel: String? = isSecure ? (info.label ?? "Password") : (info.label ?? info.key)
            let nodeId = info.key ?? info.path

            return AccessibilityNode(
                id: nodeId,
                role: info.role,
                label: projectedLabel,
                value: projectedValue,
                help: info.help,
                frame: rect,
                isFocused: info.focused || info.path == focusedPath,
                isFocusable: info.focusable,
                isSelected: info.itemSelected,
                isExpanded: info.expanded,
                level: info.level,
                isModal: info.role == .dialog,
                isSecure: isSecure,
                actions: actions,
                children: (childrenByParent[idx] ?? []).map(build)
            )
        }

        let builtRoots = roots.map(build)
        if builtRoots.count == 1 {
            return builtRoots[0]
        }
        return AccessibilityNode(
            id: "root",
            role: .group,
            label: nil,
            value: nil,
            frame: MotionRect.fromXYWH(0, 0, viewport.x, viewport.y),
            children: builtRoots
        )
    }

    /// Computes live-region and modal/dialog announcements when transitioning between snapshots.
    /// Secure fields are strictly excluded.
    static func liveAnnouncements(
        previous: AccessibilityNode?,
        current: AccessibilityNode
    ) -> [AccessibilityAnnouncement] {
        func flatten(_ node: AccessibilityNode, into out: inout [String: AccessibilityNode]) {
            out[node.id] = node
            for child in node.children {
                flatten(child, into: &out)
            }
        }

        var prevMap: [String: AccessibilityNode] = [:]
        if let previous {
            flatten(previous, into: &prevMap)
        }

        var announcements: [AccessibilityAnnouncement] = []
        func visit(_ node: AccessibilityNode) {
            if !node.isSecure {
                let prev = prevMap[node.id]
                let currentText = [node.label, node.value].compactMap { $0 }.joined(separator: " ")
                let prevText = prev.map { [$0.label, $0.value].compactMap { $0 }.joined(separator: " ") } ?? ""

                if node.role == .dialog || node.isModal {
                    if !currentText.isEmpty && (prev == nil || currentText != prevText) {
                        announcements.append(AccessibilityAnnouncement(text: currentText, politeness: .assertive))
                    }
                }
            }
            for child in node.children {
                visit(child)
            }
        }
        visit(current)
        return announcements
    }
}

public extension Runtime {
    /// Returns the current accessibility tree snapshot built from live runtime elements.
    func accessibilitySnapshot(securePaths: Set<String> = []) -> AccessibilityNode {
        AccessibilityTreeBuilder.project(
            elements: elements(),
            focusedPath: focusedPath,
            viewport: viewport,
            securePaths: securePaths
        )
    }

    /// Dispatches an accessibility action onto an element identified by `id` (`key` or `path`).
    @discardableResult
    func performAccessibilityAction(
        _ id: String,
        action: AccessibilityAction,
        at now: Double
    ) -> Bool {
        let all = elements()
        guard let target = all.first(where: { ($0.key ?? $0.path) == id || $0.path == id }),
              !target.inert,
              target.rect.count >= 4 else {
            return false
        }
        let cx = target.rect[0] + target.rect[2] * 0.5
        let cy = target.rect[1] + target.rect[3] * 0.5
        let center = Vec2(cx, cy)

        switch action {
        case .press, .focus:
            pointerDown(at: center, button: .primary, mods: Mods(), at: now)
            pointerUp(at: center, button: .primary, mods: Mods(), at: now)
            return true
        case .increment:
            pointerDown(at: center, button: .primary, mods: Mods(), at: now)
            pointerUp(at: center, button: .primary, mods: Mods(), at: now)
            return keyDown(KeyEvent(key: .arrowUp), at: now) || keyDown(KeyEvent(key: .arrowRight), at: now)
        case .decrement:
            pointerDown(at: center, button: .primary, mods: Mods(), at: now)
            pointerUp(at: center, button: .primary, mods: Mods(), at: now)
            return keyDown(KeyEvent(key: .arrowDown), at: now) || keyDown(KeyEvent(key: .arrowLeft), at: now)
        }
    }
}

#if os(macOS) && canImport(AppKit)

/// Bridges `AccessibilityNode` trees and live-region announcements onto an AppKit `NSView` for VoiceOver.
@MainActor
public final class MacOSAccessibilityHost {
    private var previousTree: AccessibilityNode?
    private var lastFocusedId: String?
    private var rootElements: [RuneNSAccessibilityElement] = []
    private var elementById: [String: RuneNSAccessibilityElement] = [:]

    public init() {}

    /// Rebuilds cached `NSAccessibilityElement` wrappers for `tree` and emits focus / VoiceOver announcements.
    public func update(
        tree: AccessibilityNode,
        parentView: NSView,
        onAction: @escaping @Sendable (String, AccessibilityAction) -> Void
    ) {
        let announcements = AccessibilityTreeBuilder.liveAnnouncements(previous: previousTree, current: tree)
        previousTree = tree

        var map: [String: RuneNSAccessibilityElement] = [:]
        func convertNode(_ node: AccessibilityNode, parent: AnyObject) -> RuneNSAccessibilityElement {
            let elem = AppKitAccessibilityMapper.buildElement(from: node, onAction: onAction)
            elem.setAccessibilityParent(parent)

            let viewRect = NSRect(
                x: CGFloat(node.frame.left),
                y: CGFloat(node.frame.top),
                width: CGFloat(max(0, node.frame.width)),
                height: CGFloat(max(0, node.frame.height))
            )
            if let window = parentView.window {
                let winRect = parentView.convert(viewRect, to: nil)
                let screenRect = window.convertToScreen(winRect)
                elem.setAccessibilityFrame(screenRect)
            } else {
                elem.setAccessibilityFrame(viewRect)
            }

            let builtChildren = node.children.map { convertNode($0, parent: elem) }
            elem.setAccessibilityChildren(builtChildren)
            map[node.id] = elem
            return elem
        }

        if tree.id == "root" && tree.role == .group && tree.label == nil {
            rootElements = tree.children.map { convertNode($0, parent: parentView) }
        } else {
            rootElements = [convertNode(tree, parent: parentView)]
        }
        elementById = map

        let focusedNodeId = Self.findFocusedId(in: tree)
        if focusedNodeId != lastFocusedId {
            lastFocusedId = focusedNodeId
            if let fid = focusedNodeId, let focusedElem = map[fid] {
                NSAccessibility.post(element: focusedElem, notification: .focusedUIElementChanged)
            } else {
                NSAccessibility.post(element: parentView, notification: .focusedUIElementChanged)
            }
        }

        for announcement in announcements {
            guard let spoken = announcement.spokenText else { continue }
            let priority: NSAccessibilityPriorityLevel =
                announcement.politeness == .assertive ? .high : .medium
            NSAccessibility.post(
                element: parentView,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: spoken,
                    .priority: priority.rawValue,
                ]
            )
        }
    }

    public func accessibilityChildren() -> [Any] {
        rootElements
    }

    public func accessibilityFocusedUIElement() -> Any? {
        if let fid = lastFocusedId {
            return elementById[fid]
        }
        return nil
    }

    public func accessibilityHitTest(_ screenPoint: NSPoint, in parentView: NSView) -> Any? {
        func hitTestNode(_ element: RuneNSAccessibilityElement) -> RuneNSAccessibilityElement? {
            let children = (element.accessibilityChildren() as? [RuneNSAccessibilityElement]) ?? []
            for child in children.reversed() {
                if let hit = hitTestNode(child) {
                    return hit
                }
            }
            if element.accessibilityFrame().contains(screenPoint) {
                return element
            }
            return nil
        }

        _ = parentView
        for root in rootElements.reversed() {
            if let hit = hitTestNode(root) {
                return hit
            }
        }
        return nil
    }

    private static func findFocusedId(in node: AccessibilityNode) -> String? {
        if node.isFocused { return node.id }
        for child in node.children {
            if let found = findFocusedId(in: child) {
                return found
            }
        }
        return nil
    }
}

#endif
