import Testing
@testable import RuneTaffy

@Suite("Compact layout style storage")
struct CompactStyleStorageTests {
    @Test func runeStylesFitOneCacheLine() {
        if MemoryLayout<Int>.size == 8 {
            #expect(MemoryLayout<CompactStyle>.size == 64)
            #expect(MemoryLayout<CompactStyle>.stride == 64)
        } else {
            #expect(MemoryLayout<CompactStyle>.stride <= 64)
        }

        #expect(CompactStyle.default.position == .static)
        let dimensions: [Dimension] = [.auto, .zero, .length(42.5), .percent(0.375), .maxContent]
        for width in dimensions {
            for height in dimensions {
                var style = CompactStyle.runeBase(.columnReverse)
                style.size = Size(width: width, height: height)
                style.minSize = Size(width: .length(10), height: .percent(0.25))
                style.maxSize = Size(width: .auto, height: .length(500))
                style.padding = Rect(left: .length(4), right: .percent(0.125), top: .length(8), bottom: .length(12))
                style.gap = Size(width: .length(6), height: .percent(0.25))
                style.setGrow(1.5)
                style.flexShrink = 0.25
                style.flexWrap = .wrap
                style.setOverflow(.hidden, .scroll)
                style.alignItems = .center
                style.alignSelf = .flexEnd
                style.justifyContent = .spaceBetween
                style.alignContent = .stretch

                #expect(style.position == .relative)
                #expect(style.size == Size(width: width, height: height))
                #expect(style.minSize == Size(width: .length(10), height: .percent(0.25)))
                #expect(style.maxSize == Size(width: .auto, height: .length(500)))
                #expect(style.padding.right == .percent(0.125))
                #expect(style.gap.height == .percent(0.25))
                #expect(style.flexShrink == 0.25 && style.flexGrow == 1.5 && style.flexBasis == .zero)
                #expect(style.flexWrap == .wrap && style.flexDirection == .columnReverse)
                #expect(style.overflow == Point(x: .hidden, y: .scroll))
                #expect(style.alignItems == .center && style.alignSelf == .flexEnd)
                #expect(style.justifyContent == .spaceBetween && style.alignContent == .stretch)
                #expect(style.heapBytes() == 0)
            }
        }
    }

    @Test func extendedValuesAreExactAndReleaseTheirLastAllocation() {
        let base = CompactStyle.runeBase()
        var style = base
        let precise = Float(bitPattern: 0x3EAB_CDEF)
        style.flexGrow = precise
        style.flexShrink = -Float.leastNonzeroMagnitude
        style.gap = Size(width: .percent(precise), height: .length(2))
        style.flexBasis = .fitContentPercent(precise)
        style.gridTemplateColumns = [.fr(1)]
        style.inset.left = .percent(precise)

        #expect(style.flexGrow.bitPattern == precise.bitPattern)
        #expect(style.flexShrink.bitPattern == (-Float.leastNonzeroMagnitude).bitPattern)
        #expect(style.gap == Size(width: .percent(precise), height: .length(2)))
        #expect(style.flexBasis == .fitContentPercent(precise))
        #expect(style.heapBytes() > 0)

        let retained = style
        style.flexGrow = 0
        style.flexShrink = 0
        style.gap = Size(width: .zero, height: .zero)
        style.flexBasis = .auto
        style.gridTemplateColumns.removeAll()
        #expect(style.heapBytes() > 0)
        style.inset.left = .auto
        #expect(style.heapBytes() == 0)
        #expect(style == base)
        #expect(Set([style, base, retained]).count == 2)
        #expect(retained.inset.left == .percent(precise))
        #expect(retained.gridTemplateColumns == [.fr(1)])
        #expect(retained.gap.width == .percent(precise))

        let negativeZero = CompactStyle(flexGrow: -0.0, flexBasis: .length(-0.0))
        let positiveZero = CompactStyle(flexGrow: 0, flexBasis: .length(0))
        #expect(negativeZero.flexGrow.bitPattern == Float(-0.0).bitPattern)
        if case .length(let value) = negativeZero.flexBasis {
            #expect(value.bitPattern == Float(-0.0).bitPattern)
        } else {
            Issue.record("lost flex basis unit")
        }
        #expect(negativeZero == positiveZero)
        #expect(Set([negativeZero, positiveZero]).count == 1)
    }

    @Test func intrinsicLengthsAndBoxPlacementSurvivePacking() {
        let values: [Dimension] = [.length(-13), .percent(0.125), .minContent, .maxContent,
                                   .fitContentPx(123.25), .fitContentPercent(0.12345), .auto]
        var style = CompactStyle(display: .block)
        for width in values {
            for height in values {
                let pair = Size(width: width, height: height)
                style.size = pair
                style.minSize = pair
                style.maxSize = pair
                #expect(style.size == pair && style.minSize == pair && style.maxSize == pair)
            }
        }
        var inline = CompactStyle(display: .block)
        let wrapper = inline.takeBoxPlacement()
        #expect(inline.display == .flex && wrapper.display == .flex)
        #expect(wrapper.position == .static && inline.position == .relative)

        for coldKeyword in [Dimension.minContent, .fitContentPx(99), .fitContentPercent(0.4)] {
            var block = CompactStyle(display: .block, size: Size(width: coldKeyword, height: .auto))
            let wrapper = block.takeBoxPlacement()
            #expect(wrapper.size.width == coldKeyword)
            #expect(block.display == .block)
        }
        var grid = CompactStyle(display: .grid, gridTemplateColumns: [.fr(1)])
        _ = grid.takeBoxPlacement()
        #expect(grid.display == .grid && grid.gridTemplateColumns == [.fr(1)])
    }
}
