#if os(macOS) && canImport(AppKit)
import AppKit
import Testing
@testable import Rune

@MainActor
@Suite("Incremental AppKit accessibility")
struct AppKitIncrementalAccessibilityTests {
    private func node(_ key: String, role: ElementRole = .group, frame: MotionRect = .zero,
                      label: String? = nil, actions: [AccessibilityAction] = [],
                      children: [AccessibilityNode] = []) -> AccessibilityNode {
        var value = AccessibilityNode(id: key, role: role, label: label, frame: frame, actions: actions, children: children)
        value.runtimePath = "/" + key
        return value
    }

    private func children(of node: RuneNSAccessibilityElement) -> [RuneNSAccessibilityElement] {
        node.accessibilityChildren() as? [RuneNSAccessibilityElement] ?? []
    }

    @Test func virtualRangeKeepsTheOverlappingProxiesAndUpdatesTheirGeometry() throws {
        func rows(_ start: Int, offset: Float) -> AccessibilityNode {
            node("viewport", role: .scrollView, children: (start..<(start + 5)).map { index in
                let y = Float(index * 20) - offset
                return node("row-\(index)", role: .row, frame: .fromXYWH(0, y, 100, 20), children: [
                    node("cell-\(index)", role: .gridCell, frame: .fromXYWH(0, y, 100, 20),
                         label: "Line \(index)", actions: [.scrollIntoView])
                ])
            })
        }
        let parent = NSView(), host = MacOSAccessibilityHost()
        let callbacks = MacOSAccessibilityCallbacks(onSelectText: nil, onSetValue: nil) { _, _ in }
        host.activate()
        host.update(tree: rows(0, offset: 0), parentView: parent, callbacks: callbacks)
        let viewport = try #require(host.accessibilityChildren().first as? RuneNSAccessibilityElement)
        let first = children(of: viewport)
        let oldCell = try #require(children(of: first[1]).first)
        let dropped = try #require(children(of: first[0]).first)
        let next = rows(1, offset: 13)
        host.update(tree: next, parentView: parent, callbacks: callbacks)
        let shifted = children(of: viewport)
        #expect(shifted.map(\.nodeId) == ["row-1", "row-2", "row-3", "row-4", "row-5"])
        #expect(shifted[0] === first[1])
        #expect(children(of: shifted[0]).first === oldCell)
        #expect(oldCell.accessibilityFrame() == CGRect(x: 0, y: 7, width: 100, height: 20))
        #expect(host.accessibilityHitTest(.init(x: 4, y: 10), in: parent) as? RuneNSAccessibilityElement === oldCell)
        #expect(dropped.supportedActions.isEmpty)
        #if DEBUG
        #expect(host.lastUpdatedElements == 0)
        #endif
        host.update(tree: next, parentView: parent, callbacks: callbacks)
        #if DEBUG
        #expect(host.lastVisitedNodes == 1)
        #expect(host.lastUpdatedElements == 0)
        #endif
    }

    @Test func readerQueriesMaterializeCurrentChildrenAndHitTargetsOnDemand() throws {
        let host = MacOSAccessibilityHost(), view = NSView()
        let callbacks = MacOSAccessibilityCallbacks(onSelectText: nil, onSetValue: nil) { _, _ in }
        func scene(_ firstRow: Int) -> AccessibilityNode {
            node("list", role: .list, children: (firstRow..<(firstRow + 100)).map { i in
                node("row-\(i)", role: .listItem, children: [
                    node("button-\(i)", role: .button, frame: .fromXYWH(4, Float(i * 10), 50, 10),
                         label: "Line \(i)", actions: [.press])
                ])
            })
        }
        host.onActivate = { host.update(tree: scene(0), parentView: view, callbacks: callbacks) }
        #expect(host.accessibilityFocusedUIElement() == nil)
        #if DEBUG
        #expect(host.materializedCount == 0)
        #endif
        host.update(tree: scene(10), parentView: view, callbacks: callbacks)
        let hit = try #require(host.accessibilityHitTest(CGPoint(x: 12, y: 145), in: view) as? RuneNSAccessibilityElement)
        #expect(hit.nodeId == "button-14")
        #expect(hit.accessibilityLabel() == "Line 14")
        #expect(hit.accessibilityPerformPress())
        #if DEBUG
        #expect(host.materializedCount == 3)
        #endif
        let root = try #require(host.accessibilityChildren().first as? RuneNSAccessibilityElement)
        #expect(children(of: root).count == 100)
        #expect(children(of: children(of: root)[4]).first === hit)
        #if DEBUG
        #expect(host.materializedCount == 102)
        #endif
        host.update(tree: scene(20), parentView: view, callbacks: callbacks)
        #expect(!hit.isAccessibilityElement())
        #expect(!hit.accessibilityPerformPress())
        #expect(children(of: root).first?.nodeId == "row-20")
    }

    @Test func reorderedOrReparentedDescendantsKeepTheirHandlesAndCurrentParent() throws {
        let view = NSView(), host = MacOSAccessibilityHost()
        let callbacks = MacOSAccessibilityCallbacks(onSelectText: nil, onSetValue: nil) { _, _ in }
        let item = node("item", role: .button, label: "Move", actions: [.press])
        let left = node("left", children: [item]), right = node("right")
        let root = node("app", children: [left, right])
        host.update(tree: root, parentView: view, callbacks: callbacks)
        let group = try #require(host.accessibilityChildren().first as? RuneNSAccessibilityElement)
        let first = children(of: group)
        let retained = try #require(children(of: first[0]).first)
        for order in [[node("right", children: [item]), node("left")], [left, right]] {
            host.update(tree: node("app", children: order), parentView: view, callbacks: callbacks)
            let current = children(of: group)
            #expect(current.map(\.nodeId) == order.map(\.id))
            #expect(children(of: current[0]).first === retained)
            #expect(retained.accessibilityParent() as? RuneNSAccessibilityElement === current[0])
            #expect(retained.accessibilityPerformPress())
            #expect(children(of: current[1]).isEmpty)
        }
    }

    @Test func movingAnUnorderedWindowRefreshesScreenBoundsForAnUnchangedSubtree() throws {
        final class FlippedView: NSView {
            override var isFlipped: Bool { true }
        }
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 80, y: 90, width: 240, height: 160),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let view = FlippedView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        window.contentView = view
        let host = MacOSAccessibilityHost()
        let callbacks = MacOSAccessibilityCallbacks(onSelectText: nil, onSetValue: nil) { _, _ in }
        let child = node("child", role: .button, frame: .fromXYWH(10, 20, 32, 18))
        let tree = node("group", children: [child])
        host.update(tree: tree, parentView: view, callbacks: callbacks)
        let root = try #require(host.accessibilityChildren().first as? RuneNSAccessibilityElement)
        let element = try #require(children(of: root).first)
        func expectedFrame() -> CGRect {
            window.convertToScreen(view.convert(CGRect(x: 10, y: 20, width: 32, height: 18), to: nil))
        }
        #expect(element.accessibilityFrame() == expectedFrame())
        let previous = element.accessibilityFrame()
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x + 57, y: window.frame.origin.y + 36))
        host.update(tree: tree, parentView: view, callbacks: callbacks)
        #expect(element.accessibilityFrame() != previous)
        #expect(element.accessibilityFrame() == expectedFrame())
        #expect(children(of: root).first === element)
    }

    @Test func scrollingBetweenCommitsMovesTheRetainedElementForHitTesting() throws {
        let runtime = Runtime(state: 0, viewport: Vec2(160, 100)) { _, _ in
            col().key("viewport").scrollY().size(160, 100).children(
                (0..<20).map { text("Line \($0)").key("line-\($0)").h(20).shrink(0) }
            )
        }
        let view = NSView(), host = MacOSAccessibilityHost()
        let callbacks = MacOSAccessibilityCallbacks(onSelectText: nil, onSetValue: nil) { _, _ in }
        _ = runtime.renderFrame(at: 0)
        host.activate()
        host.synchronize(runtime, in: view, force: true, callbacks: callbacks)
        let root = try #require(host.accessibilityChildren().first as? RuneNSAccessibilityElement)
        let line = try #require(children(of: root).first { $0.nodeId == "line-3" })
        let initialFrame = line.accessibilityFrame()
        let commit = runtime.commitCount
        _ = runtime.wheelXY(40, 40, dx: 0, dy: -30, at: 0.02)
        _ = runtime.renderFrame(at: 0.03)
        host.synchronize(runtime, in: view, force: false, callbacks: callbacks)
        #expect(runtime.commitCount == commit)
        let painted = try #require(runtime.element(byKey: "line-3"))
        #expect(line.accessibilityFrame() != initialFrame)
        #expect(line.accessibilityFrame().minY == CGFloat(painted.rect[1]))
        #expect(host.accessibilityHitTest(.init(x: 4, y: line.accessibilityFrame().midY), in: view)
                as? RuneNSAccessibilityElement === line)
    }
}
#endif
