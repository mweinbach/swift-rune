import Foundation

public enum ChaosConstants {
    public static let scenes: [String] = ["Focus", "Relax", "Away", "Night"]
    public static let lights: [String] = ["Studio", "Desk lamp", "Hallway", "Porch"]
    public static let faders: [String] = ["Kick", "Bass", "Keys", "Vox", "FX"]
    public static let sceneNotes: [String] = [
        "Cool, bright light. Notifications held.",
        "Warm light and something slow playing.",
        "Lights off, cameras armed, heat eased.",
        "Dim amber light. Quiet hours.",
    ]
    public static let dock: [String] = ["Energy", "Genres", "Orb", "Transfers", "Visitors"]
    public static let dockKeys: [String] = ["energy", "chips", "orb", "transfers", "visitors"]
    public static let chips: [String] = ["Ambient", "Lo-fi", "Jazz", "Rain", "Synth", "Piano", "Cafe", "Forest"]
    public static let chipsFolded: Int = 4
    public static let tracks: [(String, String)] = [
        ("Night Drive", "Lumen"),
        ("Paper Moons", "Hollow Coast"),
        ("Glasshouse", "Ines Varga"),
        ("Slow Orbit", "Kites"),
        ("Low Tide", "Marlowe"),
        ("Afterglow", "Sable Youth"),
        ("Neon Rain", "Oda"),
        ("Soft Static", "Fen"),
    ]
    public static let queueLen: Int = 4
    public static let feedKinds: [String] = [
        "Front door unlocked",
        "Motion in the hallway",
        "Washer finished",
        "Package delivered",
        "Living room at 21°",
        "Garage closed",
        "Doorbell rang",
        "Air purifier on",
    ]
    public static let feedLen: Int = 4
    public static let files: [String] = ["mix-final.wav", "photos-oct.zip", "backup.tar"]
    public static let energyBars: Int = 7
    public static let visits: Int = 12
    public static let visitMax: UInt32 = 48
    public static let tempMin: Float = 16.0
    public static let tempMax: Float = 28.0
}

public enum ChaosAction: Equatable, Hashable, Sendable {
    case scene(UInt8)
    case tempUp
    case tempDown
    case light(UInt8)
    case fader(UInt8)
    case puck
    case queue
    case feed
    case focus(UInt8)
    case energy
    case chipsMore
    case chip(UInt8)
    case orb
    case transfer(UInt8)
    case visitors

    public var key: String {
        switch self {
        case .scene(let i): return "scene/seg\(i)"
        case .tempUp: return "thermo/up"
        case .tempDown: return "thermo/down"
        case .light(let i): return "lights/light\(i)"
        case .fader(let i): return "mixer/fader\(i)"
        case .puck: return "xy/pad"
        case .queue: return "queue/head/skip"
        case .feed: return "feed/head/test"
        case .focus(let i): return "\(ChaosConstants.dockKeys[Int(i) % ChaosConstants.dockKeys.count])/head"
        case .energy: return "energy/bars"
        case .chipsMore: return "chips/head/more"
        case .chip(let i): return "chips/chip\(i)"
        case .orb: return "orb/orb"
        case .transfer(let i): return "transfers/row\(i)"
        case .visitors: return "visitors/count"
        }
    }
}

public struct ChaosFeedItem: Equatable, Sendable {
    public var id: UInt32
    public var kind: Int
    public var minute: UInt32
}

public struct ChaosCard: Equatable, Sendable {
    public var id: UInt32
    public var track: Int
}

public struct ChaosVisit: Equatable, Sendable {
    public var id: UInt32
    public var count: UInt32
}

public struct ChaosOrb: Equatable, Sendable {
    public var size: Float
    public var hue: Float
    public var round: Float
    public var turn: Float
}

private let rFader = 0
private let rPuck = 1
private let rQueue = 2
private let rFeed = 3
private let rEnergy = 4
private let rOrb = 5
private let rTransfer = 6
private let rVisitors = 7

public struct ChaosModel: Equatable, Sendable {
    public var events: UInt32 = 0
    public var scene: Int = 0
    public var temp: Float = 21.5
    public var lights: [Bool] = [true, false, true, false]
    public var faders: [Float] = [0.72, 0.58, 0.44, 0.66, 0.3]
    public var puck: [Float] = [0.62, 0.38]
    public var queue: [ChaosCard] = []
    public var feed: [ChaosFeedItem] = []
    public var focus: Int = 0
    public var energy: [Float] = [0.42, 0.55, 0.38, 0.7, 0.62, 0.48, 0.8]
    public var kwhTenths: UInt32 = 128
    public var chipsOpen: Bool = false
    public var chips: [Bool] = [true, false, true, false, false, false, false, false]
    public var orb = ChaosOrb(size: 0.8, hue: 245.0, round: 0.5, turn: 0.0)
    public var transfers: [Float] = [0.35, 0.7, 0.12]
    public var visitors: UInt32 = 1284
    public var visits: [ChaosVisit] = []
    private var nextId: UInt32 = 0
    private var minute: UInt32 = 2
    private var rng: [ChaosRng]

    public init(seed: UInt64) {
        self.rng = (0..<8).map { i in
            ChaosRng(seed: (seed &* 0x2545_f491_4f6c_dd1d) ^ UInt64(i + 1))
        }
        for track in 0..<ChaosConstants.queueLen {
            let cid = nextID()
            queue.append(ChaosCard(id: cid, track: track))
        }
        for count: UInt32 in [12, 18, 9, 22, 30, 26, 14, 19, 33, 28, 21, 17] {
            let vid = nextID()
            visits.append(ChaosVisit(id: vid, count: count))
        }
        for kind in [2, 0, 5] {
            let fid = nextID()
            minute += 3
            feed.insert(ChaosFeedItem(id: fid, kind: kind, minute: minute), at: 0)
        }
    }

    private mutating func nextID() -> UInt32 {
        nextId += 1
        return nextId
    }

    public func chipsShown() -> Int {
        chipsOpen ? ChaosConstants.chips.count : ChaosConstants.chipsFolded
    }

    public func energyKwh() -> String {
        "\(kwhTenths / 10).\(kwhTenths % 10)"
    }

    public func tempLabel() -> String {
        String(format: "%.1f°", temp)
    }

    public func tempFraction() -> Float {
        (temp - ChaosConstants.tempMin) / (ChaosConstants.tempMax - ChaosConstants.tempMin)
    }

    public mutating func apply(_ action: ChaosAction) {
        events += 1
        switch action {
        case .scene(let i):
            scene = Int(i) % ChaosConstants.scenes.count
        case .tempUp:
            temp = min(temp + 0.5, ChaosConstants.tempMax)
        case .tempDown:
            temp = max(temp - 0.5, ChaosConstants.tempMin)
        case .light(let i):
            lights[Int(i) % 4].toggle()
        case .fader(let i):
            let idx = Int(i) % ChaosConstants.faders.count
            let current = faders[idx]
            var next = rng[rFader].rangef(0.12, 0.96)
            if abs(next - current) < 0.2 {
                next = current > 0.5 ? current - 0.35 : current + 0.35
            }
            faders[idx] = next
        case .puck:
            puck = [rng[rPuck].rangef(0.08, 0.92), rng[rPuck].rangef(0.1, 0.9)]
        case .queue:
            queue.removeFirst()
            let last = queue.last?.track ?? 0
            let track = (last + 1 + rng[rQueue].below(ChaosConstants.tracks.count - 1)) % ChaosConstants.tracks.count
            let cid = nextID()
            queue.append(ChaosCard(id: cid, track: track))
        case .feed:
            let kind = rng[rFeed].below(ChaosConstants.feedKinds.count)
            minute = (minute + 1 + UInt32(rng[rFeed].below(4))) % 60
            let fid = nextID()
            feed.insert(ChaosFeedItem(id: fid, kind: kind, minute: minute), at: 0)
            if feed.count > ChaosConstants.feedLen {
                feed.removeLast(feed.count - ChaosConstants.feedLen)
            }
        case .focus(let i):
            focus = Int(i) % ChaosConstants.dock.count
        case .energy:
            for idx in energy.indices {
                energy[idx] = rng[rEnergy].rangef(0.15, 1.0)
            }
            kwhTenths += 3 + UInt32(rng[rEnergy].below(23))
        case .chipsMore:
            chipsOpen.toggle()
        case .chip(let i):
            chips[Int(i) % ChaosConstants.chips.count].toggle()
        case .orb:
            let rounds: [Float] = [0.5, 0.32, 0.22]
            let turns: [Float] = [45.0, 90.0, 135.0]
            orb = ChaosOrb(
                size: rng[rOrb].rangef(0.55, 1.0),
                hue: (orb.hue + rng[rOrb].rangef(40.0, 140.0)).truncatingRemainder(dividingBy: 360.0),
                round: rounds[rng[rOrb].below(3)],
                turn: orb.turn + turns[rng[rOrb].below(3)]
            )
        case .transfer(let i):
            let step = rng[rTransfer].rangef(0.15, 0.4)
            let idx = Int(i) % 3
            transfers[idx] = transfers[idx] >= 1.0 ? 0.0 : min(transfers[idx] + step, 1.0)
        case .visitors:
            let count = 1 + UInt32(rng[rVisitors].below(Int(ChaosConstants.visitMax)))
            visitors += count
            let vid = nextID()
            visits.removeFirst()
            visits.append(ChaosVisit(id: vid, count: count))
        }
    }
}
