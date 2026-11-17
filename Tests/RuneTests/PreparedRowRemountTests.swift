import Testing
@testable import Rune

/// The two real, prepared remounts in `runtime/virtual/pins_tests.rs`.
@Suite("Virtual selection pins during prepared remount")
struct PreparedRowRemountTests {
    private final class Builds {
        var rows: [String] = []
        var checkEndpointGeometry = false
        var endpointWidths: [Float] = []
    }

    private func exercise(selecting name: String) throws {
        let builds = Builds()
        let runtime = Runtime<Void>(state: (), viewport: Vec2(640, 420), pixelScale: 2) { _, _ in
            func list(_ name: String) -> El<Void> {
                col().key("s" + name).wFull().grow(1).scroll(stickBottom: false).child(
                    col().key(name).wFull().growth(.default).selectionGroup().virtualRows(
                        count: 400, estimatedRowHeight: 20,
                        key: { _, index in index < 3 ? ["a", "b", "c"][index] : "r\(index)" },
                        build: { _, index in
                            builds.rows.append("\(name)/\(index)")
                            if builds.checkEndpointGeometry && (index == 0 || index == 399) {
                                builds.endpointWidths.append(layoutRect("s" + name)?[2] ?? 0)
                            }
                            let row: El<Void> = col().wFull().h(20).selectionCopy { _ in nil }
                                .child(text("row \(index)").key("t0").wFull().selectable())
                            return index < 150 ? row : row.child(col().key("inner").virtualize(20))
                        }
                    )
                )
            }
            return col().sizeFull().children([list("one"), list("two")])
        }
        var time = 0.0
        func frame() {
            time += 1.0 / 120.0
            _ = runtime.frame(at: time)
        }
        frame()
        runtime.update(at: time) { _, tx in tx.selectAllText(name) }
        frame()
        let path = try #require(runtime.virtualLists.keys.first { $0.hasSuffix("/@" + name) })
        for _ in 0..<40 {
            if (runtime.virtualLists[path]?.lastMountedRange.lowerBound ?? 0) > 40 { break }
            runtime.wheelXY(320, name == "one" ? 100 : 310, dx: 0, dy: -200, at: time)
            frame()
        }
        for _ in 0..<40 where runtime.isAnimating { frame() }
        let range = try #require(runtime.virtualLists[path]?.lastMountedRange)
        try #require(range.lowerBound > 1 && range.upperBound < 150)

        let ends = ["a", "r399"]
        let pins = try #require(runtime.virtualSelectionSources[path]?.pinnedRows)
        func textRows() -> [String] {
            pins.rows.values.filter { $0.children.contains { $0.isSelectable && $0.keyId == "t0" } }
                .compactMap(\.keyId).sorted()
        }
        func providerRows() -> [String] {
            pins.rows.values.filter(\.hasSelectionCopyHandler).compactMap(\.keyId).sorted()
        }
        #expect(runtime.virtualSelectionPinnedRows(path) == ends)
        #expect(textRows() == ends)
        #expect(providerRows() == ends)
        let capacity = pins.rows.capacity

        let first = try #require(runtime.virtualLists.first { $0.key.hasSuffix("/@one") }?.value)
        runtime.scrollOffsets[first.scrollPath] = Vec2(0, 3_400)
        builds.rows = []
        builds.checkEndpointGeometry = true
        let pass = runtime.tryVirtualRemountPass(at: time, cut: false, commitKind: .animate,
            commitMotion: nil, commitColorSpring: nil, commitCut: false, prevMountedIds: Set(runtime.nodeById.keys))
        #expect(pass == nil)
        #expect(builds.rows.contains { $0.hasPrefix("one/") && $0 != "one/399" && (Int($0.dropFirst(4)) ?? 0) >= 150 })
        #expect(runtime.virtualSelectionPinnedRows(path) == ends)
        if name == "one" {
            #expect(builds.rows.prefix(2).elementsEqual(["one/0", "one/399"]))
            #expect(builds.endpointWidths == [640, 640])
            #expect(textRows() == ends)
            #expect(providerRows() == ends)
        } else {
            #expect(!builds.rows.contains { $0.hasPrefix("two/") })
            #expect(textRows().isEmpty)
            #expect(providerRows().isEmpty)
            #expect(pins.rows.capacity >= capacity)
        }
    }

    @Test func collectsPinnedRowsBeforeItsOwnNestedFallback() throws {
        try exercise(selecting: "one")
    }

    @Test func clearsLaterListsBeforeAnEarlierNestedFallback() throws {
        try exercise(selecting: "two")
    }
}
