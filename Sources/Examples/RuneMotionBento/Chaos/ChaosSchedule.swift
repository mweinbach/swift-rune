import Foundation

public struct ChaosEvent: Equatable, Sendable {
    public var t: Double
    public var action: ChaosAction

    public init(t: Double, action: ChaosAction) {
        self.t = t
        self.action = action
    }
}

public enum ChaosSchedule {
    public static let start: Double = 0.6
    public static let tapLead: Double = 0.01
    private static let kinds: [UInt32] = [5, 4, 4, 9, 12, 8, 6, 8, 6, 6, 3, 8, 6, 8, 6]

    private static func pick(_ rng: inout ChaosRng, _ m: ChaosModel) -> ChaosAction {
        func other(_ n: Int, _ current: Int) -> UInt8 {
            UInt8((current + 1 + rng.below(n - 1)) % n)
        }
        switch rng.weighted(kinds) {
        case 0: return .scene(other(ChaosConstants.scenes.count, m.scene))
        case 1: return .tempUp
        case 2: return .tempDown
        case 3: return .light(UInt8(rng.below(4)))
        case 4: return .fader(UInt8(rng.below(ChaosConstants.faders.count)))
        case 5: return .puck
        case 6: return .queue
        case 7: return .feed
        case 8: return .focus(other(ChaosConstants.dock.count, m.focus))
        case 9: return .energy
        case 10: return .chipsMore
        case 11: return .chip(UInt8(rng.below(min(m.chipsShown(), ChaosConstants.chips.count))))
        case 12: return .orb
        case 13: return .transfer(UInt8(rng.below(3)))
        default: return .visitors
        }
    }

    public static func schedule(_ config: ChaosConfig) -> [ChaosEvent] {
        var rng = ChaosRng(seed: config.seed)
        var model = ChaosModel(seed: config.seed)
        var events: [ChaosEvent] = []
        let (lo, hi) = config.gap()
        var t = start
        var nextBurst = start + rng.range(1.2, 2.2)
        while t < config.duration {
            let action = pick(&rng, model)
            model.apply(action)
            events.append(ChaosEvent(t: t, action: action))
            if t >= nextBurst {
                let n = 6 + rng.below(7)
                for _ in 0..<n {
                    t += rng.range(0.03, 0.06)
                    if t >= config.duration {
                        break
                    }
                    let burstAction = pick(&rng, model)
                    model.apply(burstAction)
                    events.append(ChaosEvent(t: t, action: burstAction))
                }
                t += rng.range(0.35, 0.6)
                nextBurst = t + rng.range(2.0, 3.0)
            } else {
                t += rng.range(lo, hi)
            }
        }
        return events
    }

    public static func scriptJSON(_ config: ChaosConfig) -> String {
        var out = "{\"events\": [\n"
        for e in schedule(config) {
            out += String(
                format: "  {\"t\": %.4f, \"type\": \"tap\", \"key\": \"%@\", \"hold\": %@},\n",
                e.t - tapLead,
                e.action.key,
                "\(tapLead)"
            )
        }
        out += String(format: "  {\"t\": %.4f, \"type\": \"mark\", \"name\": \"end\"}\n]}\n", config.duration + 1.0)
        return out
    }
}

public struct ChaosPlayer: Sendable {
    private let events: [ChaosEvent]
    private var nextIndex: Int = 0

    public init(config: ChaosConfig) {
        self.events = ChaosSchedule.schedule(config)
    }

    public mutating func due(at t: Double) -> ArraySlice<ChaosEvent> {
        let start = nextIndex
        while nextIndex < events.count && events[nextIndex].t <= t {
            nextIndex += 1
        }
        return events[start..<nextIndex]
    }

    public var isDone: Bool {
        nextIndex == events.count
    }

    public var nextAt: Double? {
        nextIndex < events.count ? events[nextIndex].t : nil
    }

    public var count: Int { events.count }
    public var isEmpty: Bool { events.isEmpty }
}
