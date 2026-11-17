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
}
