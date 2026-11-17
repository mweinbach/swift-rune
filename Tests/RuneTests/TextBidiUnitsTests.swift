import Testing
import Rune

@Suite struct TextBidiUnitsTests {
    @Test func splitsAtWhitespaceScalarsAndPreservesUTF8Offsets() {
        let source = "--first\u{a0}\u{301}abc /src/مرحبا.rs\u{2003}\u{301}end --last"
        #expect(TextBidiUnits.ltrUnits(in: source) == [0..<7, 15..<33, 42..<48])
    }

    @Test func retainsPairedDelimitersAndTrimsSentencePunctuation() {
        let source = "אבג «(a[0])» [renderView()] --flag,» » #693… [foo"
        #expect(TextBidiUnits.ltrUnits(in: source) == [9..<15, 18..<32, 33..<39, 46..<50])
    }

    @Test func nonASCIIPathsUseTheSameDriveAndByteExtensionRules() {
        let source = "ו/أو /資料 C:\\資料\\file 名前/é.12345678 名前/é.123456789 /é /د/ظ -1,-"
        #expect(TextBidiUnits.ltrUnits(in: source) == [16..<30, 31..<49, 81..<85])
    }

    @Test func longUnmatchedDelimitersTrimToTheSameTechnicalUnit() {
        let count = 8_192
        let source = String(repeating: "[", count: count) + "name.ext" + String(repeating: ")", count: count)
        #expect(TextBidiUnits.ltrUnits(in: source) == [count..<(count + 8)])
    }
}
