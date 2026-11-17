#if os(macOS) && canImport(AppKit)
import AppKit
import os
import Testing
@testable import Rune

@MainActor
@Suite("Concurrent native field queries")
struct A11yFieldSnapshotTests {
    @Test func retainedFieldReadsOneSelectionWhileTheHostUpdates() async throws {
        let host = MacOSAccessibilityHost()
        let view = NSView()
        let failures = OSAllocatedUnfairLock(initialState: 0)
        func refresh(emoji: Bool) {
            let action: AccessibilityAction = emoji ? .increment : .press
            let node = AccessibilityNode(id: "draft", role: .textInput, value: emoji ? "🦀Z" : "abc",
                                         isFocused: true, textSelection: emoji ? [0, 4, 0, 5] : [0, 0, 0, 1],
                                         actions: [.setValue, action])
            host.update(tree: node, parentView: view, onSelectText: { id, range in
                // In the emoji value, both ends of this UTF-16 range resolve after the crab.
                let expected = emoji ? 4..<4 : 1..<2
                if id != "draft" || range != expected { failures.withLock { $0 += 1 } }
            }, onAction: { id, received in
                if id != "draft" || received != action { failures.withLock { $0 += 1 } }
            })
        }

        refresh(emoji: false)
        let field = try #require(host.accessibilityFocusedUIElement() as? RuneAXTextField)
        let held = MacOSUnsafeSendableBox(field)
        let (started, signal) = AsyncStream<Void>.makeStream()
        let read = Task.detached {
            signal.yield(())
            signal.finish()
            for i in 0..<1_024 {
                let text = held.value.accessibilitySelectedText()
                if text != "a", text != "Z" { return false }
                held.value.setAccessibilitySelectedTextRange(NSRange(location: 1, length: 1))
                _ = held.value.accessibilityPerformPress()
                _ = held.value.accessibilityPerformIncrement()
                if i.isMultiple(of: 8) { await Task.yield() }
            }
            return true
        }
        for await _ in started { break }
        for i in 0..<128 {
            refresh(emoji: i.isMultiple(of: 2))
            await Task.yield()
        }
        #expect(await read.value)
        #expect(failures.withLock { $0 } == 0)
    }
}
#endif
