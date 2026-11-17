#if canImport(UIKit) && !os(watchOS)
import Testing
import UIKit
import Metal
import QuartzCore
import RuneMotion
@testable import Rune

@MainActor
struct IOSHostTouchTests {
    @Test("UIKit follows the active tree row while Rune keeps keyboard focus on the tree")
    func activeTreeRowFocus() throws {
        let runtime = Runtime(state: "first", viewport: Vec2(160, 80)) { cursor, _ in
            col().key("files").role(.tree).focusable().activeDescendant(cursor).children([
                el().key("first").role(.treeItem).label("First file").size(100, 24),
                el().key("second").role(.treeItem).label("Second file").size(100, 24),
            ])
        }
        let view = try RuneIOSView(frame: .zero, runtime: runtime)
        func focusedRows() throws -> [RuneUIAccessibilityElement] {
            func walk(_ elements: [RuneUIAccessibilityElement]) -> [RuneUIAccessibilityElement] {
                elements.flatMap { node in
                    let children = node.accessibilityElements as? [RuneUIAccessibilityElement] ?? []
                    return (node.isRuneFocused ? [node] : []) + walk(children)
                }
            }
            return walk(try #require(view.accessibilityElements as? [RuneUIAccessibilityElement]))
        }
        _ = runtime.frame(at: 0)
        #expect(runtime.accessibilityAction("files", .focus, at: 0.1))
        _ = runtime.frame(at: 0.1)
        let first = try #require(focusedRows().first)
        #expect(first.nodeId == "first")
        runtime.update(at: 0.2) { state, _ in state = "second" }
        _ = runtime.frame(at: 0.2)
        #expect(try focusedRows().map(\.nodeId) == ["second"])
        #expect(!first.isRuneFocused)
        #expect(runtime.focusedKey == "files")
    }

    @Test("All UIKit hosts use the Command key for primary shortcuts")
    func primaryKeyboardModifier() {
        #expect(KeyPlatform.current == .mac)
        #expect(Mods(cmd: true).primaryCommand)
        #expect(!Mods(ctrl: true).primaryCommand)
    }

    @Test("UIKit preserves app callbacks and waits for a drawable before reporting ready")
    func embeddedApp() throws {
        let app = App("Embedded", size: Vec2(200, 120), init: { 0 }) { count, _ in
            el().key("button").role(.button).size(80, 40).label("Count \(count)").onClick { $0 += 1 }
        }.onFocus { state, _, _ in state += 1 }
        let controller = try IOSApp.makeViewController(app)
        let view = controller.runeView
        let runtime = view.runtime
        runtime.dispatchFocus(false, at: 0)
        #expect(runtime.state == 1)
        view.renderTick()
        #expect(!view.didSignalReady)
        #expect(runtime.viewCommitCount == 0)
        _ = runtime.renderFrame(at: 0)
        let elements = try #require(view.accessibilityElements as? [RuneUIAccessibilityElement])
        let first = try #require(elements.first { $0.accessibilityIdentifier == "button" })
        runtime.update(at: 0.5) { state, _ in state += 1 }
        _ = runtime.renderFrame(at: 0.5)
        let updated = try #require((view.accessibilityElements as? [RuneUIAccessibilityElement])?.first {
            $0.accessibilityIdentifier == "button"
        })
        #expect(updated === first)
        #expect(updated.accessibilityLabel == "Count 2")
    }

    @Test("A linear-light UIKit scene gets an sRGB Metal drawable capable of backdrop sampling",
          .enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func linearDrawable() throws {
        let spec = AppSpec(title: "Linear", srgbBlend: false, state: false) { _, _ in el() }
        let controller = try IOSApp.makeViewController(spec)
        let layer = try #require(controller.runeView.layer as? CAMetalLayer)
        #expect(layer.device != nil)
        #expect(layer.pixelFormat == .bgra8Unorm_srgb)
        #expect(!layer.framebufferOnly)
    }

    @Test("The first contact owns the pan until it lifts or the host detaches")
    func primaryContactAndTeardown() throws {
        let runtime = Runtime(state: 0, viewport: Vec2(200, 200), pixelScale: 1) { _, _ in
            col().key("list").size(200, 200).scrollY(stickBottom: false)
                .children((0..<20).map { i in
                    el().key("row\(i)").size(200, 40).onClick { taps in taps += 1 }
                })
        }
        let view = try RuneIOSView(frame: .zero, runtime: runtime)
        _ = runtime.frame(at: 0)

        view.deliverContact(id: 1, phase: .started, at: Vec2(50, 120), eventTimestamp: nil, time: 0.01)
        view.deliverContact(id: 2, phase: .started, at: Vec2(50, 30), eventTimestamp: nil, time: 0.02)
        view.deliverContact(id: 2, phase: .ended, at: Vec2(50, 30), eventTimestamp: nil, time: 0.03)
        #expect(runtime.touching())

        view.deliverContact(id: 1, phase: .moved, at: Vec2(50, 70), eventTimestamp: nil, time: 0.04)
        #expect(runtime.scrollOffset(forKey: "list").y == 50)
        view.willMove(toWindow: nil)
        #expect(!runtime.touching())
        #expect(runtime.state == 0)

        view.deliverContact(id: 3, phase: .started, at: Vec2(50, 40), button: .primary, eventTimestamp: nil, time: 1)
        #expect(!runtime.touching())
        view.deliverContact(id: 3, phase: .ended, at: Vec2(50, 40), eventTimestamp: nil, time: 1.02)
        #expect(runtime.state == 1)
    }
}
#endif
