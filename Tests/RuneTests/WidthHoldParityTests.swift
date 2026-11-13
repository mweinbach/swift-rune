import Foundation
import Testing
@testable import Rune

@Suite("WidthHold & Size Parity (width_hold_tests.rs & size_tests.rs)")
struct WidthHoldParityTests {
    // MARK: - crates/rune/src/runtime/width_hold_tests.rs

    @Test("a_width_change_defers_heights_then_lets_a_streaming_row_shrink")
    func widthChangeDefersHeightsThenLetsStreamingRowShrink() {
        let hold = WidthHold.rewrap(at: 2.0)
        #expect(hold.defers(at: 2.0) && hold.defers(at: 2.11))
        #expect(!hold.defers(at: 2.12), "heights land once the width is stable")
        #expect(!hold.mayShrink(at: 2.12) && !hold.mayShrink(at: 2.39))
        #expect(hold.mayShrink(at: 2.4), "a streaming row may shrink once the rewrap is well past")
    }

    @Test("no_width_change_defers_nothing")
    func noWidthChangeDefersNothing() {
        for at in [-1.0, 0.0, 5.0] {
            #expect(!WidthHold.off.defers(at: at) && WidthHold.off.mayShrink(at: at), "at \(at)")
        }
    }

    // MARK: - crates/rune/src/runtime/size_tests.rs

    @Test("elements_and_nodes_stay_small")
    func elementsAndNodesStaySmall() {
        let elBytes = MemoryLayout<El<()>>.stride
        let nodeBytes = MemoryLayout<Runtime<()>.FlatNode>.stride
        #expect(
            elBytes <= 800 && nodeBytes <= 512,
            "El is \(elBytes) bytes and FlatNode is \(nodeBytes) bytes"
        )
    }
}
