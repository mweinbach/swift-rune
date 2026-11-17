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
