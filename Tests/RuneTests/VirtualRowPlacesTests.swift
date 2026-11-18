import Testing
@testable import Rune

@Suite("Virtual row key storage")
struct VirtualRowPlacesTests {
    private struct CollidingKey: Hashable, Sendable {
        let id: Int

        func hash(into hasher: inout Hasher) {
            hasher.combine(1)
        }
    }

    @Test func collisionsCompareTheOriginalKey() {
        let keys = [1, 2, 3].map(CollidingKey.init)
        let places = VirtualRowPlaces(keys)
        #expect(!places.hasDuplicates)
        for (index, key) in keys.enumerated() {
            #expect(places.index(of: key) == index)
        }
        #expect(places.index(of: CollidingKey(id: 4)) == nil)
        #expect(VirtualRowPlaces(keys + [keys[1]]).hasDuplicates)
    }

    @Test func repairReservesAuthoredSuffixes() {
        var rows = VirtualListBookkeeping()
        rows.setKeys(["row", "row", "row#dup1", "row"], commit: 1, offset: nil)
        #expect(rows.keys == ["row", "row#dup2", "row#dup1", "row#dup3"])
        #expect(rows.indexOf("row#dup1") == 2)
    }

    @Test func byteExactRowsKeepAuthoredKeysForFocusAndScopedSelection() throws {
        let composed = "dir/\u{e9}"
        let decomposed = "dir/e\u{301}"
        let literal = "dir/~utf8~c3a9"
        let markAfterSlash = "dir/\u{301}file"
        let ids = [composed, decomposed, literal, composed, composed + "#dup1", markAfterSlash, "plain"]
        let runtime = Runtime<[String]>(state: ids, viewport: Vec2(160, 180)) { ids, _ in
            col().key("files").size(160, 180).scrollY(stickBottom: false).child(
                col().key("rows").wFull().virtualRows(
                    count: ids.count, estimatedRowHeight: 20, byteExactKeys: true,
                    key: { ids, row in ids[row] },
                    build: { _, _ in el().wFull().h(20).focusable() }
                )
            )
        }
        _ = runtime.frame(at: 0)
        let ordered = [composed, decomposed, literal, composed + "#dup2", composed + "#dup1", markAfterSlash, "plain"]
        var paths: [String] = []
        for (row, id) in ordered.enumerated() {
            let node = try #require(runtime.element(byKey: id))
            #expect(node.key?.utf8.elementsEqual(id.utf8) == true)
            #expect(runtime.element(byKey: "rows/" + id)?.path == node.path)
            #expect(node.rect[1] == Float(row * 20))
            paths.append(node.path)
        }
        #expect(Set(paths).count == ordered.count)
        #expect(paths[5].contains("/@dir/"))
        #expect(paths.last?.hasSuffix("/@plain") == true)
        for row in [1, 2, 0] {
            runtime.update(at: 0.1) { _, tx in tx.focus(ordered[row]) }
            _ = runtime.frame(at: 0.1)
            #expect(runtime.focusedPath == paths[row])
        }
    }

    @Test(arguments: [false, true])
    func byteExactElementKeysKeepPublicSpellingBeforeAndAfterLayout(nativeFrame: Bool) throws {
        let ids = ["\u{e9}", "e\u{301}", "~utf8~c3a9", "\u{e9}", "\u{e9}#dup1"]
        let built: El<Int> = col().key("columns").children(ids.map { name in
            el().key(name, byteExact: true).h(20)
        })
        for (node, id) in zip(built.children, ids) {
            #expect(matchesAuthoredKey(node.keyId, id))
        }
        let repaired = KeyDiagnostics.repair(built)
        #expect(repaired.warnings.count == 1)
        #expect(matchesAuthoredKey(repaired.warnings.first?.key, ids[0]))
        #expect(matchesAuthoredKey(repaired.tree.children[3].keyId, ids[0] + "#dup2"))
        let runtime = Runtime<Int>(state: 0, viewport: Vec2(160, 160)) { _, _ in repaired.tree }
        if nativeFrame { _ = runtime.renderFrame(at: 0) } else { _ = runtime.frame(at: 0) }
        for (i, node) in repaired.tree.children.enumerated() {
            let id = try #require(node.keyId)
            #expect(runtime.element(byKey: "columns/" + id)?.rect[1] == Float(i * 20))
            #expect(runtime.presented(id)?.rect[1] == Float(i * 20))
        }

        let nested = Runtime<Int>(state: 0, viewport: Vec2(160, 80)) { _, _ in
            col().child(col().key("~utf8~c3a9").child(el().key("label").h(20)))
                .child(col().key("\u{e9}", byteExact: true).child(el().key("label").h(20)))
        }
        _ = nested.frame(at: 0)
        #expect(nested.element(byKey: "~utf8~c3a9/label")?.rect[1] == 0)
        #expect(nested.element(byKey: "\u{e9}/label")?.rect[1] == 20)
    }

    @Test func runtimeRetainsUnmountedMeasurementsAcrossReorder() throws {
        let runtime = Runtime<[Int]>(state: Array(0..<512), viewport: Vec2(160, 80)) { rows, _ in
            col().size(160, 80).scrollY(stickBottom: false).child(
                col().key("rows").wFull().virtualRows(
                    count: rows.count, estimatedRowHeight: 20,
                    key: { ids, index in "row-\(ids[index])" },
                    build: { ids, index in el().wFull().h(ids[index] == 1 ? 37 : 20) }
                )
            )
        }
        _ = runtime.frame(at: 0)
        let initial = try #require(runtime.virtualLists.values.first)
        #expect(initial.measuredByKey["row-1"] == 37)

        runtime.update(at: 0.01) { rows, _ in rows.swapAt(1, 300) }
        _ = runtime.frame(at: 0.02)
        let reordered = try #require(runtime.virtualLists.values.first)
        #expect(!reordered.lastMountedRange.contains(300))
        #expect(reordered.rowPlaces.index(of: "row-1") == 300)
        #expect(reordered.measuredByKey["row-1"] == 37)
        #expect(reordered.measuredByKey["row-300"] == 20)

        runtime.update(at: 0.03) { rows, _ in rows[300] = 512 }
        _ = runtime.frame(at: 0.04)
        runtime.update(at: 0.05) { rows, _ in rows[300] = 1 }
        _ = runtime.frame(at: 0.06)
        let restored = try #require(runtime.virtualLists.values.first)
        #expect(restored.rowPlaces.index(of: "row-1") == 300)
        #expect(restored.measuredByKey["row-1"] == nil)
    }

    @Test func retainedMeasurementsIsolateEditsAcrossHeightPages() {
        let keys = (0..<515).map { "row-\($0)" }
        var rows = VirtualRowMeasurements()
        rows.replacePlaces(VirtualRowPlaces(keys))
        for i in [0, 255, 256, 514] { rows.setHeight(20, at: i) }
        rows.prepareOffsets(estimated: 20, gap: 1)
        let saved = rows

        rows.setHeight(nil, at: 255)
        rows.setHeight(35, at: 256)
        rows.setHeight(12, at: 257)
        rows.setHeight(7, at: 514)
        #expect(saved.heights[255] == 20)
        #expect(saved.heights[256] == 20)
        #expect(saved.heights[257] == nil)
        #expect(saved.heights[514] == 20)
        #expect(rows.heights[255] == nil)
        #expect(saved.offsets(estimated: 20, gap: 1).last == 10_814)
        #expect(rows.offsets(estimated: 20, gap: 1).last == 10_808)

        rows.replacePlaces(VirtualRowPlaces([keys[514], keys[255], "new", keys[256]]))
        #expect(Array(rows.heights) == [7, nil, nil, 35])
        #expect(saved.heights.count == 515)
    }

    @Test(arguments: [false, true])
    func reorderedMeasurementsMatchSurvivingKeysAcrossPages(dense: Bool) {
        let keys = (0..<1027).map { "row-\($0)" }
        var rows = VirtualRowMeasurements()
        rows.replacePlaces(VirtualRowPlaces(keys))
        for index in keys.indices where dense || index % 253 == 0 {
            rows.setHeight(Float(index % 51), at: index)
        }
        rows.prepareOffsets(estimated: 20, gap: 1)
        let snapshot = rows
        var reordered = Array(keys.reversed())
        reordered.removeSubrange(212..<310)
        reordered.insert("new", at: 702)
        rows.replacePlaces(VirtualRowPlaces(reordered))
        #expect(Array(rows.heights) == reordered.map { snapshot[$0] })
        #expect(snapshot.places.keys == keys)
        #expect(snapshot.heights[0] == 0)
        #expect(rows["new"] == nil)
    }

    @Test func denseRemapPreservesDifferentKeysWithTheSameHash() {
        let keys = (0..<64).map(CollidingKey.init)
        let old = VirtualRowPlaces(keys)
        var heights = VirtualRowHeights(count: keys.count)
        for index in keys.indices { heights[index] = Float(index) }

        var reordered = Array(keys.reversed())
        reordered[11] = CollidingKey(id: 100)
        let mapped = heights.remapped(from: old, to: VirtualRowPlaces(reordered))
        #expect(Array(mapped) == reordered.map { old.index(of: $0).map(Float.init) })
    }

    @Test func repeatedKeysUseTheLastOldOccurrenceForEveryNewOccurrence() {
        var rows = VirtualRowMeasurements()
        rows.replacePlaces(VirtualRowPlaces(["a", "b", "a", "b", "c"]))
        rows.setHeight(11, at: 0)
        rows.setHeight(12, at: 1)
        rows.setHeight(13, at: 2)
        rows.setHeight(14, at: 4)
        let snapshot = rows

        rows.replacePlaces(VirtualRowPlaces(["b", "a", "c", "a", "b", "new"]))
        #expect(Array(rows.heights) == [nil, 13, 14, 13, nil, nil])
        rows.replacePlaces(VirtualRowPlaces(["a", "new", "b"]))
        #expect(Array(rows.heights) == [13, nil, nil])
        #expect(Array(snapshot.heights) == [11, 12, 13, nil, 14])
    }

    @Test func cachedOffsetsRespectRowIdentityEstimateGapAndSnapshot() {
        var list = RuntimeVirtualListState()
        list.lastKeys = ["a", "b", "c"]
        list.gap = 3
        list.measuredByKey.prepareOffsets(estimated: 20, gap: list.gap)
        let before = list
        list.measuredByKey["b"] = 35
        list.measuredByKey.prepareOffsets(estimated: 20, gap: list.gap)
        #expect(before.computeOffsets(estimated: 20).prefix == [0, 23, 46, 66])
        #expect(list.computeOffsets(estimated: 20).prefix == [0, 23, 61, 81])
        list.lastKeys = ["b", "a", "new"]
        list.gap = 4
        let prefix = list.computeOffsets(estimated: 10).prefix
        #expect(prefix == [0, 39, 53, 63])
        #expect(list.visibleRange(offset: 35, viewport: 4, prefix: prefix, count: 3).isEmpty)
        #expect(list.visibleRange(offset: 35, viewport: 5, prefix: prefix, count: 3) == 1..<2)
        #expect(list.visibleRange(offset: 48, viewport: 6, prefix: prefix, count: 3) == 1..<3)
    }

    @Test func largeReplacementPreservesMeasurementsAndBirthsByIdentity() {
        let count = 100_000
        let middle = count / 2
        var keys = (0..<count).map { "transcript-message-\($0)" }
        var list = VirtualListBookkeeping()
        list.setEstimate(2)
        list.viewport = 20
        _ = list.setKeys(keys, commit: 1, offset: nil)
        let oldKey = keys[middle]
        let removed = keys[0]
        list.setHeight(key: oldKey, height: 9)
        list.shown.insert(oldKey)
        list.frameBegins()

        keys.swapAt(middle, middle + 3)
        keys[0] = "new"
        let anchor = list.setKeys(keys, commit: 2, offset: Float(middle * 2))
        #expect(anchor == .init(key: oldKey, top: Float(middle * 2)))
        #expect(list.indexOf(oldKey) == middle + 3)
        #expect(list.height(forKey: oldKey) == 9)
        #expect(list.prefix(middle + 4) == Float((middle + 4) * 2 + 7))
        let survivorWasQuiet = list.mountsQuietly(index: middle + 3, commit: 2)
        let newRowWasQuiet = list.mountsQuietly(index: 0, commit: 2)
        #expect(survivorWasQuiet)
        #expect(!newRowWasQuiet)
        #expect(!list.has(removed))
        list.setHeight(key: removed, height: 50)
        #expect(list.height(forKey: removed) == 2)

        // A removed row which comes back is born on this commit and starts unmeasured.
        _ = list.setKeys([oldKey], commit: 3, offset: nil)
        _ = list.setKeys([removed, oldKey], commit: 4, offset: nil)
        #expect(list.height(forKey: removed) == 2)
        let returnedRowWasQuiet = list.mountsQuietly(index: 0, commit: 4)
        #expect(!returnedRowWasQuiet)
    }
}
