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
    var t: Double = 0.0
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

@main
enum RuneShowreelApp {
    static func makeApp() -> App<ShowreelState> {
        var app = App<ShowreelState>(
            title: "Showreel",
            size: Vec2(ShowreelKit.W, ShowreelKit.H),
            dark: true,
            state: ShowreelState(),
            view: showreelView
        )
        .families(["Inter", "IBM Plex Mono"])
        .poll { s, t, _ in
            let changed = s.t != t
            s.t = t
            return changed
        }

        for scene in ShowreelScene.allCases {
            app = app.scene(scene.rawValue) { state, _ in
                state.scene = scene
            }
        }
        return app
    }

    static func main() throws {
        try makeApp().run()
    }
}
