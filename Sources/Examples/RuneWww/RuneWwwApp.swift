import Foundation
import Rune

public enum WwwConstants {
    public static let title: String = "Rune · A Rust UI framework with its own GPU renderer"
    public static let repo: String = "https://github.com/anomalyco/rune"
    public static let docs: String = "https://github.com/anomalyco/rune/blob/dev/crates/rune/README.md"
    public static let brand: String = "/rune/"
    public static let rev: String = ProcessInfo.processInfo.environment["RUNE_REV"] ?? "dev"
    public static let copiedDuration: Double = 1.6
}

public final class WwwImageBox: @unchecked Sendable {
    public var cache: ImageCache?
    public init() {}
}

public struct WwwState: Sendable {
    public var glyphs = WwwWordmark.Glyphs()
    public var card = WwwHero.Card()
    public var spring = WwwSprings.Demo()
    public var pipeline = WwwPipeline.Pipeline()
    public var glints = WwwWordmark.Glints()
    public var imageBox: WwwImageBox
    public var seen: Set<String> = []
    public var copiedUntil: Double?
    public var clockSeconds: Double = 0.0
    public var clockTimestamp: UInt64 = DispatchTime.now().uptimeNanoseconds
    public var notFound: Bool

    public init(imageBox: WwwImageBox = WwwImageBox(), notFound: Bool? = nil) {
        self.imageBox = imageBox
        self.notFound = notFound ?? (ProcessInfo.processInfo.environment["RUNE_WWW_PAGE"] == "404")
    }

    public func clockNow() -> Double {
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- clockTimestamp
        return clockSeconds + Double(elapsedNs) / 1_000_000_000.0
    }

    public mutating func markCopied() {
        copiedUntil = clockNow() + WwwConstants.copiedDuration
    }

    public mutating func poll(at t: Double, tx: inout Tx) -> Bool {
        clockSeconds = t
        clockTimestamp = DispatchTime.now().uptimeNanoseconds

        var changed = false
        var moving = false

        let wasSpring = spring.running
        let onSpring = spring.tick(t)
        changed = changed || wasSpring || onSpring
        moving = moving || onSpring

        let wasPipe = pipeline.active
        let onPipe = pipeline.tick(t)
        changed = changed || wasPipe || onPipe
        moving = moving || onPipe

        let (glinted, glinting, next) = glints.tick(t)
        changed = changed || glinted
        moving = moving || glinting
        if let next {
            tx.wakeAfter(max(0.0, next - t))
        }
        if let until = copiedUntil {
            if t >= until {
                copiedUntil = nil
                changed = true
            } else {
                tx.wakeAfter(until - t)
            }
        }
        if moving {
            tx.wakeAfter(0.0)
        }
        return changed
    }
}

@main
public enum RuneWwwApp {
    public static func view(_ s: WwwState, _ cx: inout Cx<WwwState>) -> El<WwwState> {
        let bp = cx.layoutWith("page") { r in WwwBreakpoint.of(r[2]) } ?? WwwBreakpoint(at: 1000)
        let reduced = cx.isReducedMotion()
        let t = s.clockSeconds
        let gutter = bp.gutter

        func framed(_ e: El<WwwState>) -> El<WwwState> {
            e.wFull().maxW(WwwTokens.contentWidth + 2.0 * gutter).px(gutter)
        }

        let mainBody: El<WwwState> = s.notFound
            ? col().child(WwwSections.notFound(bp))
            : home(s, cx: cx, bp: bp, reduced: reduced)

        return col()
            .key("page")
            .wFull()
            .bg(WwwTokens.bg)
            .itemsCenter()
            .child(framed(WwwSections.topbar(s, glow: s.glints.glow(.brand, now: t, reduced: reduced))))
            .child(framed(mainBody.key("main").role(.main)))
            .child(framed(WwwSections.footer()))
    }

    private static func home(
        _ s: WwwState,
        cx: Cx<WwwState>,
        bp: WwwBreakpoint,
        reduced: Bool
    ) -> El<WwwState> {
        let images = s.imageBox.cache
        let glow = s.glints.glow(.masthead, now: s.clockSeconds, reduced: reduced)

        let springsEl = WwwSections.springsIntro(bp)
            .child(WwwSprings.demo(s, cx: cx, bp: bp))
            .child(memo("retarget", bp) { WwwSections.retargetCode() })
        let frameEl = WwwSections.frameIntro(bp)
            .child(WwwPipeline.pipeline(s.pipeline, size: cx.layoutSize("pl"), bp: bp, reduced: reduced))

        let (helloKey, heldHello) = WwwSections.ready(images: images, cx: cx, pics: [WwwSections.hello])
        #if os(WASI)
        let eager = false
        #else
        let eager = true
        #endif
        func shown(_ name: String) -> Bool { eager || s.seen.contains(name) }
        let (galleryKey, heldGallery) = shown("renderer")
            ? WwwSections.ready(images: images, cx: cx, pics: [WwwSections.metal, WwwSections.glass, WwwSections.light])
            : ([], [])
        let (shotsKey, heldShots) = shown("opencode")
            ? WwwSections.ready(images: images, cx: cx, pics: [WwwSections.session, WwwSections.home, WwwSections.streaming])
            : ([], [])

        struct MemoPicsDeps: Equatable {
            var bp: WwwBreakpoint
            var pics: [WwwSections.ReadyKey]
        }

        return withExtendedLifetime((heldHello, heldGallery, heldShots)) {
            col()
                .wFull()
                .child(WwwHero.hero(s, cx: cx, bp: bp, glow: glow))
                .child(memo("views", MemoPicsDeps(bp: bp, pics: helloKey)) {
                    WwwSections.views(cx: cx, images: images, bp: bp)
                })
                .child(springsEl)
                .child(frameEl)
                .child(memo("renderer", MemoPicsDeps(bp: bp, pics: galleryKey)) {
                    WwwSections.gallery(cx: cx, images: images, bp: bp)
                })
                .child(memo("opencode", MemoPicsDeps(bp: bp, pics: shotsKey)) {
                    WwwSections.opencode(cx: cx, images: images, bp: bp)
                })
                .child(memo("agents", bp) { WwwSections.agents(bp) })
                .child(memo("platforms", bp) { WwwSections.platformsSection(bp) })
                .child(WwwSections.cta(bp, copied: s.copiedUntil != nil))
        }
    }

    public static func spec() -> AppSpec<WwwState> {
        let imageBox = WwwImageBox()
        return AppSpec(
            title: WwwConstants.title,
            size: Vec2(1200.0, 900.0),
            state: WwwState(imageBox: imageBox),
            families: ["Geist", "Geist Mono"],
            setup: { waker in
                imageBox.cache = ImageCache(wake: { waker.wake() })
            },
            poll: { state, t, tx in
                state.poll(at: t, tx: &tx)
            },
            view: { state, cx in
                view(state, &cx)
            }
        )
    }

    public static func app() -> App<WwwState> {
        let s = spec()
        return App(
            title: s.title,
            size: s.size,
            state: s.makeState(),
            view: s.view
        )
        .families(s.families)
        .setup { waker in
            s.setup?(waker)
        }
        .poll { state, t, tx in
            s.poll?(&state, t, &tx) ?? false
        }
        .webDocument()
        .fontUrl("fonts/geist.ttf")
        .fontUrl("fonts/geist-mono.ttf")
    }

    @MainActor
    public static func main() throws {
        try app().run()
    }
}
