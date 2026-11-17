import Foundation
import Testing
@testable import Rune

struct WebCursorProjectionTests {
    @Test func cursorUpdatesCarryImagesOnlyWhenTheyEnterTheCache() throws {
        var projection = WebCursorProjection()
        func update(_ cursor: Cursor) throws -> [String: Any] {
            let packet = projection.update(cursor)
            let data = try #require(packet)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13,
                            73, 72, 68, 82, 0, 0, 0, 32, 0, 0, 0, 32]
        let image = Cursor.image(CursorImage(png: png, hot: SIMD2(20, 4)))
        #expect(try update(.hidden)["css"] as? String == "none")
        #expect(projection.update(.hidden) == nil)
        let first = try update(image)
        #expect(first["css"] as? String == #"image-set(url("{url}") 2x) 15 4, auto"#)
        #expect(first["png"] as? String == Data(png).base64EncodedString())
        #expect(try update(.resizeColumn)["css"] as? String == "col-resize")
        let reused = try update(image)
        #expect(reused["id"] as? Int == first["id"] as? Int)
        #expect(reused["png"] == nil)
        var evicted: Int?
        for n in 0..<32 {
            let invalid = try update(.image(CursorImage(png: [UInt8(n)], hot: .zero)))
            #expect(invalid["css"] as? String == "default")
            #expect(invalid["error"] != nil)
            if let id = invalid["evict"] as? Int { evicted = id }
        }
        #expect(evicted == first["id"] as? Int)
        #expect(try update(image)["png"] != nil)
    }
}
