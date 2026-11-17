import Testing
@testable import Rune

@Suite("Text flight source capture")
struct TextFlightSourceTests {
    @Test("A flight starts only from text visible in the last frame", arguments: [false, true], [false, true])
    func capturesDrawnSource(sticky: Bool, native: Bool) throws {
        let rt = Runtime<Bool>(state: false, viewport: Vec2(240, 240), pixelScale: 1) { sent, _ in
            let source: El<Bool> = text(sent ? "" : "flight").key("source")
            return col().size(240, 240)
                .child(col().key("scroll").size(240, 100).scroll(stickBottom: false)
                    .child(col().wFull()
                        .child(el().h(140))
                        .child(sticky ? source.stickyTop(0) : source)
                        .child(el().h(200))))
                .child(text("flight").key("destination"))
        }

        func draw(at time: Double) {
            if native { _ = rt.renderFrame(at: time) } else { _ = rt.frame(at: time) }
        }

        draw(at: 0)
        rt.update(at: 0) { _, tx in tx.scrollToInstant("scroll", x: 0, y: 175) }
        draw(at: 0)
        draw(at: 1)

        rt.update(at: 1) { sent, tx in
            sent = true
            tx.flyText("source", to: "destination")
        }
        draw(at: 1)

        if sticky {
            let flight = try #require(rt.activeTextFlights.first)
            #expect(abs(flight.state.source.y) < 0.5)
        } else {
            #expect(rt.activeTextFlights.isEmpty)
        }
    }
}
