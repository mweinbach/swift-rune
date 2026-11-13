import Foundation

/// The flags both builds share.
public struct ChaosConfig: Equatable, Sendable {
    public var seed: UInt64 = 1
    public var duration: Double = 20.0
    public var intensity: Double = 1.0
    public var metrics: String?
    public var hud: Bool = false
    public var emitScript: String?
    public var variant: String = "default"
    public var stay: Bool = false
    public var load: ChaosLoad?
    public var frames: String?
    public var hudFrom: String?
    public var naive: Bool = false

    public init(
        seed: UInt64 = 1,
        duration: Double = 20.0,
        intensity: Double = 1.0,
        metrics: String? = nil,
        hud: Bool = false,
        emitScript: String? = nil,
        variant: String = "default",
        stay: Bool = false,
        load: ChaosLoad? = nil,
        frames: String? = nil,
        hudFrom: String? = nil,
        naive: Bool = false
    ) {
        self.seed = seed
        self.duration = duration
        self.intensity = intensity
        self.metrics = metrics
        self.hud = hud
        self.emitScript = emitScript
        self.variant = variant
        self.stay = stay
        self.load = load
        self.frames = frames
        self.hudFrom = hudFrom
        self.naive = naive
    }

    public static func parse(_ args: [String]) throws -> (ChaosConfig, [String]) {
        var config = ChaosConfig()
        var rest: [String] = []
        var idx = 0
        var fixed: Int?
        var rampSpec: String?
        var hold: Double = 2.5
        var timed = false

        func parseUInt64(_ flag: String, _ v: String) throws -> UInt64 {
            guard let n = UInt64(v) else { throw ChaosError("\(flag): not a number: \(v)") }
            return n
        }
        func parseInt(_ flag: String, _ v: String) throws -> Int {
            guard let n = Int(v), n >= 0 else { throw ChaosError("\(flag): not a number: \(v)") }
            return n
        }
        func parseDouble(_ flag: String, _ v: String) throws -> Double {
            guard let n = Double(v) else { throw ChaosError("\(flag): not a number: \(v)") }
            return n
        }

        while idx < args.count {
            let arg = args[idx]
            idx += 1
            let flag: String
            let inline: String?
            if arg.hasPrefix("--"), let eq = arg.firstIndex(of: "=") {
                flag = String(arg[..<eq])
                inline = String(arg[arg.index(after: eq)...])
            } else {
                flag = arg
                inline = nil
            }
            func take() throws -> String {
                if let v = inline { return v }
                guard idx < args.count else { throw ChaosError("\(flag) needs a value") }
                let v = args[idx]
                idx += 1
                return v
            }

            switch flag {
            case "--seed":
                config.seed = try parseUInt64(flag, take())
            case "--intensity":
                config.intensity = try parseDouble(flag, take())
                guard config.intensity > 0.0 else {
                    throw ChaosError("--intensity must be above 0")
                }
            case "--duration":
                let v = try take()
                if v != "auto" {
                    config.duration = try parseDouble(flag, v)
                }
                timed = true
                rest.append("--duration")
                rest.append(v)
            case "--metrics":
                config.metrics = try take()
            case "--emit-script":
                config.emitScript = try take()
            case "--variant":
                config.variant = try take()
            case "--load":
                fixed = max(try parseInt(flag, take()), 1)
            case "--ramp":
                rampSpec = try take()
            case "--hold":
                hold = try parseDouble(flag, take())
            case "--frames":
                config.frames = try take()
            case "--hud-from":
                config.hudFrom = try take()
                config.hud = true
            case "--hud":
                config.hud = true
            case "--stay":
                config.stay = true
            case "--naive":
                config.naive = true
            default:
                rest.append(arg)
            }
        }

        switch (fixed, rampSpec) {
        case (.some, .some):
            throw ChaosError("--load and --ramp: pick one")
        case (.some(let n), .none):
            config.load = .fixed(n)
        case (.none, .some(let r)):
            config.load = try .parseRamp(r, hold: hold)
        case (.none, .none):
            config.load = nil
        }

        if !timed, let d = config.load?.duration {
            config.duration = d
            rest.append("--duration")
            rest.append("\(d)")
        }
        return (config, rest)
    }

    public func gap() -> (Double, Double) {
        (0.1 / intensity, 0.3 / intensity)
    }
}
