import Testing
import Rune

@Suite("Rune Motion Exports Parity Tests (tests/motion_exports.rs)")
struct MotionExportsParityTests {
    @Test("transition_and_anim_arguments_are_nameable_from_rune")
    func transitionAndAnimArgumentsAreNameableFromRune() {
        let anchored = Transition.scale(0.96, anchor: Vec2(0.5, 0.0))
        #expect(anchored.insertion.anchor == Vec2(0.5, 0.0))

        let topDir: Vec2 = MotionEdge.top.unitVector
        #expect(topDir == Vec2(0, -1))

        let effect: TransitionEffect = TransitionEffect.scale(0.9).combined(with: .opacity(0.0))
        #expect(effect.zeroOpacity == 0.0)

        let reveal = Reveal(edge: .bottom, feather: 4.0)
        #expect(reveal.feather == 4.0)

        let bezier = Easing.cubicBezier(CubicBezier(0.2, 0.0, 0.0, 1.0))
        #expect(bezier.sample(0.0) == 0.0)

        let steps = Easing.steps(4, .jumpEnd)
        #expect(steps.sample(1.0) == 1.0)

        let decay = Decay.IOS_NORMAL
        #expect(decay.rate > 0)

        let spring = Spring.fromResponse(0.3, dampingFraction: 1.0)
        let anim: Anim<Float> = spring.blend(.additive).velocity(.zero)
        #expect(anim.blend == .additive)
        let _: Blend = .additive
        let _: Velocity<Float> = .zero
        let _: VelocityRule = .zero
        let _: StepPosition = .jumpEnd
    }
}
