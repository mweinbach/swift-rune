import Foundation
import Rune
import RuneFX
import RuneMotion

enum ShowreelScene: String, CaseIterable, Sendable {
    case word
    case card
    case deploy
    case glass
    case fire
    case pricing
    case ask
    case shock
    case keys
    case tabs
    case type

    var defaultTime: Double {
        switch self {
        case .word: return 1.8
        case .card: return 1.8
        case .deploy: return 3.6
        case .glass: return 1.8
        case .fire: return 1.6
        case .pricing: return 1.5
        case .ask: return 2.4
        case .shock: return 1.4
        case .keys: return 1.2
        case .tabs: return 2.0
        case .type: return 4.3
        }
    }
}

struct ShowreelState {
    var scene: ShowreelScene = .word
    var t: Double = ShowreelScene.word.defaultTime
}

func showreelView(_ s: ShowreelState, _ cx: inout Cx<ShowreelState>) -> El<ShowreelState> {
    switch s.scene {
    case .word: return ShowreelScenesPart1.wordView(s, card: false)
    case .card: return ShowreelScenesPart1.wordView(s, card: true)
    case .deploy: return ShowreelScenesPart1.deployView(s)
    case .glass: return ShowreelScenesPart1.glassView(s)
    case .fire: return ShowreelScenesPart1.fireView(s)
    case .pricing: return ShowreelScenesPart2.pricingView(s)
    case .ask: return ShowreelScenesPart2.askView(s)
    case .shock: return ShowreelScenesPart2.shockView(s)
    case .keys: return ShowreelScenesPart3.keysView(s)
    case .tabs: return ShowreelScenesPart3.tabsView(s)
    case .type: return ShowreelScenesPart3.typeView(s)
    }
}

var spec = AppSpec<ShowreelState>(
    title: "Showreel",
    size: Vec2(ShowreelKit.W, ShowreelKit.H),
    dark: true,
    state: ShowreelState(),
    onKey: { state, event, _ in
        let all = ShowreelScene.allCases
        let idx = all.firstIndex(of: state.scene) ?? 0
        switch event.key {
        case .arrowRight, .tab:
            let next = all[(idx + 1) % all.count]
            state.scene = next
            state.t = next.defaultTime
            return true
        case .arrowLeft:
            let prev = all[(idx - 1 + all.count) % all.count]
            state.scene = prev
            state.t = prev.defaultTime
            return true
        case .space:
            state.t += 0.25
            return true
        case .text("r"), .text("R"):
            state.t = 0.0
            return true
        case .text(let ch) where ch.count == 1:
            let map: [String: Int] = [
                "1": 0, "2": 1, "3": 2, "4": 3, "5": 4,
                "6": 5, "7": 6, "8": 7, "9": 8, "0": 9, "-": 10,
            ]
            if let targetIdx = map[ch], targetIdx < all.count {
                let target = all[targetIdx]
                state.scene = target
                state.t = target.defaultTime
                return true
            }
            return false
        default:
            return false
        }
    },
    view: showreelView
)

for scene in ShowreelScene.allCases {
    spec = spec.scene(scene.rawValue) { state in
        state.scene = scene
        state.t = scene.defaultTime
    }
}

try RuneApp.run(spec)
