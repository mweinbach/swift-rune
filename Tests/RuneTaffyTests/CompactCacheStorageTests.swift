import Testing
@testable import RuneTaffy

@Suite("Compact layout cache storage")
struct CompactCacheStorageTests {
    @Test func commonFinalAndTwoMeasuresStayInsideNinetySixBytes() {
        if MemoryLayout<Int>.size == 8 {
            #expect(MemoryLayout<CompactCache>.size == 96)
            #expect(MemoryLayout<CompactCache>.stride == 96)
        } else {
            #expect(MemoryLayout<CompactCache>.stride <= 96)
        }
        #expect(MemoryLayout<BoxLayout>.stride == 32)

        var cache = CompactCache()
        let final = LayoutInput()
        let finalOutput = LayoutOutput(size: Size(width: 100, height: 33),
                                       contentSize: Size(width: 140, height: 66),
                                       firstBaselines: Point(x: nil, y: 12.25))
        cache.store(final, output: finalOutput)
        var measure = LayoutInput(runMode: .computeSize)
        for width: Float in [12, 13] {
            measure.knownDimensions.width = width
            cache.store(measure, output: LayoutOutput(size: Size(width: width, height: 8)))
        }
        #expect(cache.heapBytes() == 0)
        #expect(cache.get(final) == finalOutput)
        #expect(cache.get(measure)?.size.width == 13)
        measure.knownDimensionsAreDefinite.width = false
        #expect(cache.get(measure) == nil)
    }

    @Test func coldFinalAndOverflowPreserveCOWAndCapacityOnClear() {
        var cache = CompactCache()
        let final = LayoutInput()
        let output = LayoutOutput(size: Size(width: 123, height: 56), contentSize: Size(width: 210, height: 77),
                                  firstBaselines: Point(x: 0.5, y: 16.75), topMargin: .fromMargin(22),
                                  bottomMargin: .fromMargin(-9), marginsCanCollapseThrough: true)
        cache.store(final, output: output)
        var measure = LayoutInput(runMode: .computeSize)
        for slot in 0..<9 {
            measure.knownDimensions.width = Float(slot)
            measure.knownDimensionsAreDefinite.width = slot.isMultiple(of: 2)
            cache.store(measure, output: .fromOuterSize(Size(width: Float(slot), height: 9)))
        }
        let bytes = cache.heapBytes()
        var copy = cache
        #expect(bytes > 0)
        #expect(cache.get(final) == output)
        #expect(copy.get(measure)?.size.width == 8)
        #expect(cache.clear() == .cleared)
        #expect(cache.heapBytes() == bytes)
        #expect(cache.get(final) == nil && cache.get(measure) == nil)
        #expect(cache.clear() == .alreadyEmpty)
        #expect(copy.get(final) == output && copy.get(measure)?.size.width == 8)
        let plain = LayoutOutput(size: .zero)
        copy.store(final, output: plain)
        #expect(copy.get(final) == plain)
        #expect(cache.get(final) == nil)
        cache.store(measure, output: plain)
        #expect(cache.get(measure) == plain)
        #expect(copy.get(measure)?.size.width == 8)
    }

    @Test func optionalAndNonfiniteBaselineRemainDistinct() {
        var cache = CompactCache()
        let key = LayoutInput()
        let y = Float(bitPattern: 0x7FC0_4567)
        var result = LayoutOutput(size: .zero, firstBaselines: Point(x: nil, y: y))
        cache.store(key, output: result)
        #expect(cache.get(key)?.firstBaselines.y?.bitPattern == y.bitPattern)
        result.firstBaselines.y = nil
        cache.store(key, output: result)
        #expect(cache.get(key) == result)
    }

    @Test func lastBaselinesAndNegativeScrollOverflowOriginRoundTrip() {
        var cache = CompactCache()
        let finalKey = LayoutInput(runMode: .performLayout)

        // 1. Both lastBaselines and negative scrollOverflowOrigin round-trip through cold final storage.
        var output = LayoutOutput(
            size: Size(width: 120, height: 64),
            contentSize: Size(width: 240, height: 180),
            firstBaselines: Point(x: nil, y: 14.25),
            lastBaselines: Point(x: 4.5, y: 58.75),
            scrollOverflowOrigin: Point(x: -22.5, y: -11.25)
        )
        #expect(output.scrollableOverflowRect == Rect(left: -22.5, right: 240, top: -11.25, bottom: 180))

        cache.store(finalKey, output: output)
        #expect(cache.heapBytes() > 0)
        let fetched = cache.get(finalKey)
        #expect(fetched == output)
        #expect(fetched?.lastBaselines == Point(x: 4.5, y: 58.75))
        #expect(fetched?.scrollOverflowOrigin == Point(x: -22.5, y: -11.25))
        #expect(fetched?.scrollableOverflowRect == Rect(left: -22.5, right: 240, top: -11.25, bottom: 180))

        // 2. Mutating via scrollableOverflowRect updates both scrollOverflowOrigin and contentSize.
        output.scrollableOverflowRect = Rect(left: -7.5, right: 160, top: -3.25, bottom: 90)
        #expect(output.scrollOverflowOrigin == Point(x: -7.5, y: -3.25))
        #expect(output.contentSize == Size(width: 160, height: 90))
        var cowCopy = cache
        cache.store(finalKey, output: output)
        #expect(cache.get(finalKey) == output)
        #expect(cowCopy.get(finalKey)?.scrollOverflowOrigin == Point(x: -22.5, y: -11.25))

        // 3. Only lastBaselines (zero overflow origin) still allocates cold storage and round-trips.
        var lastOnlyCache = CompactCache()
        let lastOnly = LayoutOutput.fromSizesAndBaselines(
            size: Size(width: 80, height: 40),
            contentSize: Size(width: 80, height: 40),
            firstBaselines: Point(x: nil, y: 12),
            lastBaselines: Point(x: nil, y: 36.5)
        )
        lastOnlyCache.store(finalKey, output: lastOnly)
        #expect(lastOnlyCache.heapBytes() > 0)
        #expect(lastOnlyCache.get(finalKey) == lastOnly)

        // 4. Non-finite NaN payload in lastBaselines round-trips bit-for-bit.
        let nanLast = Float(bitPattern: 0x7FC0_1234)
        let withNanLast = LayoutOutput(
            size: Size(width: 20, height: 20),
            lastBaselines: Point(x: nil, y: nanLast)
        )
        lastOnlyCache.store(finalKey, output: withNanLast)
        #expect(lastOnlyCache.get(finalKey)?.lastBaselines.y?.bitPattern == nanLast.bitPattern)

        // 5. Only negative scrollOverflowOrigin (nil lastBaselines) allocates cold storage and round-trips.
        var negOriginCache = CompactCache()
        let negOnly = LayoutOutput(
            size: Size(width: 60, height: 30),
            contentSize: Size(width: 60, height: 30),
            scrollOverflowOrigin: Point(x: -15, y: 0)
        )
        negOriginCache.store(finalKey, output: negOnly)
        #expect(negOriginCache.heapBytes() > 0)
        #expect(negOriginCache.get(finalKey) == negOnly)

        // 6. Overwriting with a plain inline output clears cold final data and restores zero origin & nil lastBaselines.
        let plain = LayoutOutput(
            size: Size(width: 60, height: 30),
            contentSize: Size(width: 75, height: 35),
            firstBaselines: Point(x: nil, y: 10)
        )
        negOriginCache.store(finalKey, output: plain)
        let plainFetched = negOriginCache.get(finalKey)
        #expect(plainFetched == plain)
        #expect(plainFetched?.scrollOverflowOrigin == .zero)
        #expect(plainFetched?.lastBaselines == Point(x: nil, y: nil))
    }

    @Test func negativeOverflowAndLastBaselinePropagateThroughLeafAndContainerCache() {
        var store = LayoutStore()
        store.beginCommit()
        let (leaf, _) = store.syncNode(
            key: 10,
            nodeIndex: 1,
            style: TaffyStyle(
                size: Size(width: .length(40), height: .length(20)),
                margin: Rect(left: .length(-12), right: .zero, top: .length(-5), bottom: .zero),
                flexShrink: 0
            ),
            measure: 1,
            forceMeasureDirty: false,
            childMark: store.beginChildren(),
            childrenDirty: false
        )
        let mark = store.beginChildren()
        store.pushChild(leaf)
        var (root, _) = store.syncNode(
            key: 1,
            nodeIndex: 0,
            style: TaffyStyle(display: .flex, size: Size(width: .length(100), height: .length(50)), flexDirection: .row),
            measure: nil,
            forceMeasureDirty: false,
            childMark: mark,
            childrenDirty: true
        )
        store.endCommit(root: &root) { _, _ in }

        let room = Size<AvailableSpace>(width: .definite(100), height: .definite(50))
        store.computeLayout(root: root, availableSpace: room) { input, _, _ in
            LayoutOutput(
                size: Size(width: input.knownDimensions.width ?? 40, height: input.knownDimensions.height ?? 20),
                contentSize: Size(width: 40, height: 20),
                firstBaselines: Point(x: nil, y: 11),
                lastBaselines: Point(x: nil, y: 18),
                scrollOverflowOrigin: Point(x: -3, y: -2)
            )
        }
        // Negative margin places leaf at (-12, -5) inside root.
        let leafBox = store.boxLayout(leaf)
        #expect(leafBox.x == -12)
        #expect(leafBox.y == -5)
    }
}
