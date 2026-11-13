import Foundation
import Rune
import RuneMotion

enum Grab {
    case lamp(Vec2)
    case card(Vec2)
    case lens(Vec2)
    case key(Int)
}

enum LabShotKind: Equatable {
    case ripple
    case rippleCard
    case ping
    case shockwave
    case zap
    case sparkles
}

struct LabShot {
    let kind: LabShotKind
    let at: Vec2
    let t0: Float
}

struct LabPerf {
    var cpuMs: Float = 0.0
    var gpuMs: Float? = nil
    var draws: UInt32 = 0
    var live: Bool = false
}

struct LabState {
    var scene: LabScene = .lamp
    var reduced: Bool = false
    var vals: [[Float]] = defaultKnobValues()
    var now: Double = 0.0
    var perf: LabPerf = LabPerf()
    var lamp: Vec2 = lampRest
    var keys: [Animated<Float>] = (0..<keyCount).map { _ in Animated<Float>(0.0) }
    var recording: Bool = true
    var uploading: Bool = true
    var neonOn: Bool = true
    var shots: [LabShot] = []
    var card: Animated<Vec2> = Animated<Vec2>(cardRest)
    var lastDragPos: Vec2? = nil
    var cardVelocity: Vec2 = .zero
    var lens: Vec2 = lensRest
    var grab: Grab? = nil

    func k(_ scene: LabScene, _ id: String) -> Float {
        guard let i = knobSpecs(for: scene).firstIndex(where: { $0.id == id }) else {
            fatalError("No knob \(id) in \(scene.id)")
        }
        return vals[scene.idx][i]
    }

    func on(_ scene: LabScene, _ id: String) -> Bool {
        k(scene, id) > 0.5
    }

    mutating func select(_ scene: LabScene) {
        if self.scene != scene {
            self.scene = scene
            self.grab = nil
        }
    }
}

private func onLabKey(_ s: inout LabState, _ e: KeyEvent, _ tx: inout Tx) -> Bool {
    let all = LabScene.allCases
    let i = s.scene.idx
    switch e.key {
    case .arrowUp:
        s.select(all[(i + all.count - 1) % all.count])
        return true
    case .arrowDown:
        s.select(all[(i + 1) % all.count])
        return true
    default:
        return false
    }
}

@main
enum RuneLabApp {
    static func makeApp() -> App<LabState> {
        App<LabState>(
            title: "Rune Lab",
            size: Vec2(1320, 800),
            minSize: Vec2(1080, 640),
            state: LabState(),
            view: labView
        )
        .families(["Inter", "IBM Plex Mono"])
        .modifierKeys(true)
        .onKey(onLabKey)
        .poll { s, t, _ in
            let moved = s.now != t
            s.now = t
            let beforeShots = s.shots.count
            s.shots.removeAll { (Float(t) - $0.t0) >= 1.5 }
            let shotExpired = s.shots.count != beforeShots
            return shotExpired
                || (moved && (!s.shots.isEmpty || !s.card.isSettled(at: t) || s.keys.contains { !$0.isSettled(at: t) }))
        }
        .scene("lamp") { s, _ in s.scene = .lamp }
        .scene("flashlight") { s, _ in s.scene = .flashlight }
        .scene("gi") { s, _ in s.scene = .gi }
        .scene("keys") { s, _ in s.scene = .keys }
        .scene("godrays") { s, _ in s.scene = .godRays }
        .scene("glow") { s, _ in s.scene = .glow }
        .scene("pulses") { s, _ in s.scene = .pulses }
        .scene("electric") { s, _ in s.scene = .electric }
        .scene("fire") { s, _ in s.scene = .fire }
        .scene("motion") { s, _ in s.scene = .motion }
        .scene("lens") { s, _ in s.scene = .lens }
        .scene("lens-frost") { s, _ in
            s.scene = .lens
            if let i = knobSpecs(for: .lens).firstIndex(where: { $0.id == "frost" }) {
                s.vals[LabScene.lens.idx][i] = 1.0
            }
        }
        .scene("extras") { s, _ in s.scene = .extras }
        .scene("motion-thrown") { s, _ in
            s.scene = .motion
            s.card.set(Vec2(-60, 300))
            s.card.release(
                velocity: Vec2(2400, -900),
                target: Vec2(470, 160),
                curve: .spring(Spring(duration: 0.6, bounce: 0)),
                at: 0.0
            )
        }
        .scene("fire-reduced") { s, _ in
            s.scene = .fire
            s.reduced = true
        }
    }

    static func main() throws {
        try makeApp().run()
    }
}
