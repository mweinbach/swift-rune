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

private var spec = AppSpec(
    title: "Rune Lab",
    size: Vec2(1320, 800),
    minSize: Vec2(1080, 640),
    state: LabState(),
    onKey: onLabKey,
    view: labView
)
.scene("lamp") { $0.scene = .lamp }
.scene("flashlight") { $0.scene = .flashlight }
.scene("gi") { $0.scene = .gi }
.scene("keys") { $0.scene = .keys }
.scene("godrays") { $0.scene = .godRays }
.scene("glow") { $0.scene = .glow }
.scene("pulses") { $0.scene = .pulses }
.scene("electric") { $0.scene = .electric }
.scene("fire") { $0.scene = .fire }
.scene("motion") { $0.scene = .motion }
.scene("lens") { $0.scene = .lens }
.scene("lens-frost") {
    $0.scene = .lens
    if let i = knobSpecs(for: .lens).firstIndex(where: { $0.id == "frost" }) {
        $0.vals[LabScene.lens.idx][i] = 1.0
    }
}
.scene("extras") { $0.scene = .extras }
.scene("motion-thrown") {
    $0.scene = .motion
    $0.card.set(Vec2(-60, 300))
    $0.card.release(
        velocity: Vec2(2400, -900),
        target: Vec2(470, 160),
        curve: .spring(Spring(duration: 0.6, bounce: 0)),
        at: 0.0
    )
}
.scene("fire-reduced") {
    $0.scene = .fire
    $0.reduced = true
}

try RuneApp.run(spec)
