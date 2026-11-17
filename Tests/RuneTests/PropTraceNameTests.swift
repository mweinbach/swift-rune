import Testing
@testable import Rune
import RuneMotion

/// `runtime::motion::props::prop_name` through Swift's prop ids, and `Runtime.touchedTracks`
/// (`Runtime::touched_tracks`) reporting those names instead of raw ids. Upstream has no test for
/// these names; this is the Swift regression.
@Suite("Prop trace names")
struct PropTraceNameTests {
    @Test("the shared built-ins keep prop_name's BUILTIN names")
    func builtinsKeepTheirNames() {
        let expected = [
            "opacity", "frame", "offset", "scale", "rotation", "blur",
            "radius", "fill-color", "mask", "scroll", "presence", "travel",
        ]
        for (raw, name) in expected.enumerated() {
            #expect(PropTraceName.name(PropId(UInt16(raw))) == name, "id \(raw)")
        }
        // The element's fill springs on `Props.FILL`, upstream's `P_FILL`.
        #expect(PropTraceName.name(Props.FILL.id) == "fill-color")
        #expect(PropTraceName.name(Props.OPACITY.id) == "opacity")
        #expect(PropTraceName.name(Props.SCROLL.id) == "scroll")
    }

    @Test("every runtime custom prop has its upstream trace name")
    func customPropsHaveUpstreamNames() {
        #expect(PropTraceName.name(Props.BORDER.id) == "border-color")
        #expect(PropTraceName.name(Props.TEXT_COLOR.id) == "text-color")
        #expect(PropTraceName.name(Props.SCALE.id) == "scale")
        #expect(PropTraceName.name(Props.BLUR.id) == "blur")
        #expect(PropTraceName.name(Props.BORDER_BOTTOM.id) == "border-bottom-color")
        #expect(PropTraceName.name(Props.ICON_TURN.id) == "icon-turn")
        #expect(PropTraceName.name(Props.GROUP_REST.id) == "group-rest")
        #expect(PropTraceName.name(Props.PRESS_SCALE.id) == "press-scale")
        #expect(PropTraceName.name(Props.HOVER.id) == "hover")
        #expect(PropTraceName.name(Props.PRESS.id) == "press")
        #expect(PropTraceName.name(Runtime<Int>.hoverProp.id) == "hover")
        #expect(PropTraceName.name(Runtime<Int>.pressProp.id) == "press")
        for k in 0..<8 {
            #expect(PropTraceName.name(Runtime<Int>.shadowGeomProp(k).id) == "shadow", "shadow geometry \(k)")
            #expect(PropTraceName.name(Runtime<Int>.shadowColorProp(k).id) == "shadow-color", "liveStore shadow colour \(k)")
            #expect(PropTraceName.name(shadowColorProps[k].id) == "shadow-color", "scene shadow colour \(k)")
        }
        for (k, prop) in radialStopProps.enumerated() where prop.id != Props.GROUP_REST.id {
            #expect(PropTraceName.name(prop.id) == "radial-color", "radial stop \(k)")
        }
    }

    @Test("an unknown id reads custom, as upstream")
    func unknownIdsReadCustom() {
        for raw: UInt16 in [18, 19, 20, 63, 97, 119, 128, 4000] {
            #expect(PropTraceName.name(PropId(raw)) == "custom", "id \(raw)")
        }
    }

    @Test("live bindings take the name of the track upstream's latch writes")
    func liveBindingsTakeTheirLatchNames() {
        let expected: [(BoundLiveProperty.Target, String)] = [
            (.opacity, "opacity"), (.scale, "scale"), (.blur, "blur"), (.offset, "offset"),
            (.trim, "trim"), (.rect, "frame"), (.fill, "fill-color"), (.textColor, "text-color"),
            (.borderColor, "border-color"), (.shadowColor, "shadow-color"),
            (.gradientTop, "gradient-color"), (.gradientBottom, "gradient-color"),
        ]
        for (target, name) in expected {
            #expect(PropTraceName.liveTargetName(target) == name, "\(target)")
        }
    }

    @Test("touched tracks name a springing fill, border and shadow, never a raw id")
    func touchedTracksNameSpringingPaint() throws {
        let rt = Runtime<Bool>(state: false, viewport: Vec2(200, 100), pixelScale: 1.0, systemDark: true) { on, _ in
            col().key("root").size(200, 100).child(
                el().key("card").size(80, 40)
                    .bg(on ? .white : .black)
                    .border(1, on ? .black : .white)
                    .shadow(Shadow(y: on ? 8 : 2, blur: on ? 16 : 4, color: on ? Color.black.alpha(0.5) : Color.black.alpha(0.1)))
                    .motion(MotionTokens.SETTLE)
            )
        }
        var t = 0.0
        _ = rt.frame(at: t)
        let card = try #require(rt.flatNodes.first { $0.key == "card" }?.path)

        rt.update(at: t) { s, _ in s = true }
        var seen: [String: Bool] = [:]
        for _ in 0..<3 {
            t += 1.0 / 60.0
            _ = rt.frame(at: t)
            for track in rt.touchedTracks() {
                #expect(!track.prop.hasPrefix("prop:"), "raw id in trace: \(track)")
                #expect(track.prop != "custom", "unnamed runtime track: \(track)")
                if track.path == card { seen[track.prop] = seen[track.prop] == true || track.active }
            }
        }
        for name in ["fill-color", "border-color", "shadow", "shadow-color"] {
            #expect(seen[name] == true, "card's \(name) springs in the trace: \(seen)")
        }
    }
}
