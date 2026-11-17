import Testing
@testable import Rune

@MainActor
@Suite("Wheel and gesture chains follow the top painted branch")
struct WheelChainParityTests {
    enum Panel: CaseIterable {
        case decorative, raised, anchored, sticky, button, transparent, inert, list

        var masksTimeline: Bool {
            switch self {
            case .decorative, .transparent, .inert: false
            default: true
            }
        }
    }

    private func fixture(_ panel: Panel) -> Runtime<Int> {
        Runtime(state: 0, viewport: Vec2(240, 180), pixelScale: 2) { _, _ in
            let timeline: El<Int> = el().key("timeline").absolute(x: 0, y: 0).size(240, 180)
                .scrollY().onSmartMagnify { state, _, _, _ in state += 1; return true }
                .child(el().h(800).wFull().shrink(0))
            var front: El<Int> = el().key("panel").absolute(x: 20, y: 40).size(100, 60)
                .bg(.black)
            switch panel {
            case .decorative: break
            case .raised: front = front.raise()
            case .anchored: front = front.above("anchor")
            case .sticky: front = front.stickyTop()
            case .button: front = front.onClick { _ in }
            case .transparent: front = front.raise().opacity(0)
            case .inert: front = front.raise().inert()
            case .list: front = front.scrollY().child(el().h(100).wFull().shrink(0))
            }
            return el().sizeFull().child(timeline)
                .child(el().key("anchor").absolute(x: 20, y: 110).size(100, 10))
                .child(front)
        }
    }

    @Test(arguments: Panel.allCases)
    func overlappingSiblings(panel: Panel) throws {
        for gpu in [false, true] {
            let rt = fixture(panel)
            for time in [0.0, 1.0 / 60.0] {
                if gpu { _ = rt.renderFrame(at: time) } else { _ = rt.frame(at: time) }
            }
            let rect = try #require(rt.elements().first(where: { $0.key == "panel" })).rect
            let point = Vec2(rect[0] + 10, rect[1] + 10)
            #expect(point.x >= 0 && point.x < 240 && point.y >= 0 && point.y < 180)
            #expect(rt.smartMagnify(at: point) == !panel.masksTimeline)
            #expect(rt.state == (panel.masksTimeline ? 0 : 1))
            rt.wheelXY(point.x, point.y, 0, -100, now: 1)
            #expect(rt.scrollOffset(forKey: "timeline").y == (panel.masksTimeline ? 0 : 100))
            if panel == .list {
                #expect(rt.scrollOffset(forKey: "panel").y == 40)
                // A new wheel run at the sibling's edge has nowhere to go.
                rt.wheelXY(point.x, point.y, 0, -20, now: 2)
                #expect(rt.scrollOffset(forKey: "timeline").y == 0)
            }
            // The same viewport can receive a fresh gesture outside the overlay.
            let previous = rt.scrollOffset(forKey: "timeline").y
            rt.wheelXY(175, 100, 0, -15, now: 3)
            #expect(rt.scrollOffset(forKey: "timeline").y == previous + 15)
        }
    }

    @Test func paintedOrderBeatsTreeOrder() {
        let rt = Runtime(state: (), viewport: Vec2(200, 120)) { _, _ in
            el().sizeFull()
                .child(el().absolute(x: 0, y: 0).size(70, 70).raise())
                .child(el().key("list").absolute(x: 0, y: 0).size(180, 100)
                    .scrollY().child(el().h(400).wFull().shrink(0)))
        }
        _ = rt.renderFrame(at: 0)
        rt.wheelXY(10, 10, 0, -50, now: 1)
        #expect(rt.scrollOffset(forKey: "list").y == 0)
        rt.wheelXY(90, 10, 0, -50, now: 2)
        #expect(rt.scrollOffset(forKey: "list").y == 50)
    }

    @Test func anInteractivePanelOnlyMasksInsideItsAncestorClip() {
        let rt = Runtime(state: (), viewport: Vec2(200, 120), pixelScale: 2) { _, _ in
            el().sizeFull()
                .child(el().key("list").sizeFull().scrollY().child(el().h(400).wFull().shrink(0)))
                .child(el().absolute(x: 10, y: 10).size(40, 50).clip()
                    .child(el().absolute(x: 0, y: 0).size(120, 50).onClick { _ in }))
        }
        _ = rt.renderFrame(at: 0)
        rt.wheelXY(25, 25, 0, -30, now: 1)
        #expect(rt.scrollOffset(forKey: "list").y == 0)
        rt.wheelXY(80, 25, 0, -30, now: 2)
        #expect(rt.scrollOffset(forKey: "list").y == 30)
    }
}
