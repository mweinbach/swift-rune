import RuneMotion

/// Trace names for animation tracks: `runtime::motion::props::prop_name` and the live
/// properties `runtime::motion::live_latch` binds, as `Runtime.touchedTracks` (upstream
/// `Runtime::touched_tracks`, read by `tooling::trace`) reports them.
///
/// Upstream keeps every runtime track in one scene store under its own custom ids
/// (`P_FILL = 64` … `P_TRIM = 95`). The Swift port keeps the same tracks under different ids
/// and splits them over two stores, so the names map through Swift's ids:
///
/// | Swift track | id | upstream |
/// |---|---|---|
/// | `Props.FILL` (the element's fill) | 7 | `P_FILL` 64 "fill-color" |
/// | `Props.BORDER` | 12 | `P_BORDER` 65 "border-color" |
/// | `Props.TEXT_COLOR` | 13 | `P_TEXT` 66 "text-color" |
/// | `Props.SCALE` (`El.scale`) | 14 | `P_SCALE` 89 "scale" |
/// | `Props.BLUR` | 15 | `prop::BLUR` 5 "blur" |
/// | `Props.HOVER` / `Runtime.hoverProp` | 16 / 0x484F | `P_HOVER` 73 "hover" |
/// | `Props.PRESS` / `Runtime.pressProp` | 17 / 0x5052 | `P_PRESS` 74 "press" |
/// | `Props.BORDER_BOTTOM` | 21 | `P_BORDER_BOTTOM` 78 "border-bottom-color" |
/// | `Props.ICON_TURN` | 22 | `P_ICON_TURN` 88 "icon-turn" |
/// | `Runtime.shadowGeomProp(k)` | 64 + 2k | `P_SHADOW_GEO` 90…93 "shadow" |
/// | `Runtime.shadowColorProp(k)` | 64 + 2k + 1 | `P_SHADOWS` 69…72 "shadow-color" |
/// | `radialStopProps[k]` | 80 + k | `P_RADIAL` 80…87 "radial-color" |
/// | `Props.GROUP_REST` | 94 | `P_GROUP_REST` 94 "group-rest" |
/// | `Props.PRESS_SCALE` | 96 | `P_PRESS_SCALE` 79 "press-scale" |
/// | `shadowColorProps[k]` | 120 + k | `P_SHADOWS` 69…72 "shadow-color" |
///
/// Live bindings (`BoundLiveProperty`) spring in `liveStore` under a per-binding node; they take
/// the name of the property upstream's latch writes (`liveTargetName`), so a live trim reads
/// "trim" and a live gradient stop "gradient-color". Upstream's "outline-color" has no Swift
/// track: the port paints outlines at their authored colour.
internal enum PropTraceName {
    /// `prop_name`'s `BUILTIN`: the shared `rune_motion::prop` ids `0..<12`.
    static let builtin: [String] = [
        "opacity", "frame", "offset", "scale", "rotation", "blur",
        "radius", "fill", "mask", "scroll", "presence", "travel",
    ]

    /// Names a track by its Swift prop id; anything else is "custom", as upstream.
    static func name(_ id: PropId) -> String {
        let raw = Int(id.rawValue)
        switch raw {
        // The runtime springs an element's fill on `Props.FILL`, which upstream keeps on `P_FILL`.
        case Int(Props.FILL.id.rawValue): return "fill-color"
        case 0..<Props.builtinCount: return builtin[raw]
        case Int(Props.BORDER.id.rawValue): return "border-color"
        case Int(Props.TEXT_COLOR.id.rawValue): return "text-color"
        case Int(Props.SCALE.id.rawValue): return "scale"
        case Int(Props.BLUR.id.rawValue): return "blur"
        case Int(Props.HOVER.id.rawValue), 0x484F: return "hover"
        case Int(Props.PRESS.id.rawValue), 0x5052: return "press"
        case Int(Props.BORDER_BOTTOM.id.rawValue): return "border-bottom-color"
        case Int(Props.ICON_TURN.id.rawValue): return "icon-turn"
        case 64..<80: return raw % 2 == 0 ? "shadow" : "shadow-color"
        case Int(Props.GROUP_REST.id.rawValue): return "group-rest"
        case 80..<96: return "radial-color"
        case Int(Props.PRESS_SCALE.id.rawValue): return "press-scale"
        case 120..<128: return "shadow-color"
        default: return "custom"
        }
    }

    /// The name of the track upstream's `live_latch` writes for a bound live property.
    static func liveTargetName(_ target: BoundLiveProperty.Target) -> String {
        switch target {
        case .opacity: return "opacity"
        case .scale: return "scale"
        case .blur: return "blur"
        case .offset: return "offset"
        case .trim: return "trim"
        case .rect: return "frame"
        case .fill: return "fill-color"
        case .textColor: return "text-color"
        case .borderColor: return "border-color"
        case .shadowColor: return "shadow-color"
        case .gradientTop, .gradientBottom: return "gradient-color"
        }
    }
}

extension Runtime {
    /// `liveStore`'s tracks the last tick sampled, by element path and trace name: shadow
    /// springs, hover and press levels and live bindings, which upstream keeps in its scene store.
    /// Tracks whose element left the tree have no path to report and are skipped.
    internal func liveTouchedTracks() -> [(path: String, prop: String, active: Bool)] {
        let touched = liveStore.touchedTracks()
        guard !touched.isEmpty else { return [] }
        var owners: [NodeId: (path: String, name: String?)] = [:]
        owners.reserveCapacity(flatNodes.count * 3)
        for node in flatNodes {
            owners[node.nodeId] = (node.path, nil)
            owners[Self.hoverTrackId(node.nodeId)] = (node.path, "hover")
            owners[Self.pressTrackId(node.nodeId)] = (node.path, "press")
            for b in node.el.liveBindings {
                owners[NodeId.hash("live:\(node.path):\(b.target)")] = (node.path, PropTraceName.liveTargetName(b.target))
            }
        }
        var out: [(path: String, prop: String, active: Bool)] = []
        for (track, node, prop) in touched {
            guard let owner = owners[node] else { continue }
            out.append((owner.path, owner.name ?? PropTraceName.name(prop), liveStore.isActive(track)))
        }
        return out
    }
}
