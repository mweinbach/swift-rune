import Foundation
import Rune

/// Sections below the hero (`www/app/src/sections.rs`).
public enum WwwSections {
    public struct Picture: Sendable {
        public var name: String
        public var widths: [UInt32]
        public var pt: Float
        public var alt: String
        public var aspect: Float

        func image(images: ImageCache?, cx: Cx<WwwState>) -> CachedImage? {
            let shown = cx.layoutSize(name).flatMap { $0.first } ?? pt
            let scale = max(1.0, cx.env().scale)
            let plan = min(shown, shown * 2.2 / scale)
            let sources: [(String, UInt32)] = widths.map { ("img/\(name)-\($0).avif", $0) }
            return images?.urlSet(sources, sizePt: plan, scale: scale)
        }

        public func element(
            images: ImageCache?,
            cx: Cx<WwwState>,
            fit: SurfaceFit
        ) -> El<WwwState> {
            let e: El<WwwState> = el().key(name).role(.image).label(alt).wFull()
            if let img = image(images: images, cx: cx) {
                return e.pixelsFit(img.pixels, fit)
            }
            return e
        }
    }

    public struct ReadyKey: Equatable, Sendable {
        public var url: String?
        public var ready: Bool
    }

    public static func ready(
        images: ImageCache?,
        cx: Cx<WwwState>,
        pics: [Picture]
    ) -> ([ReadyKey], [CachedImage]) {
        let held = pics.compactMap { $0.image(images: images, cx: cx) }
        let digest = held.map { ReadyKey(url: $0.pixels.sourceURLString, ready: $0.isReady) }
        return (digest, held)
    }

    public static let hello = Picture(
        name: "hello",
        widths: [320, 640],
        pt: 320.0,
        alt: "A dark window reading \u{201C}Lights on\u{201D} above a blue switch that is on",
        aspect: 1.6
    )
    public static let metal = Picture(
        name: "metal",
        widths: [760, 1520],
        pt: 740.0,
        alt: "A ball of liquid chrome on black, reflecting a cool studio light",
        aspect: 16.0 / 9.0
    )
    public static let glass = Picture(
        name: "glass",
        widths: [380, 760],
        pt: 360.0,
        alt: "A frosted glass tile over a blue disc, sharp beside the glass and soft through it",
        aspect: 16.0 / 9.0
    )
    public static let light = Picture(
        name: "light",
        widths: [380, 760],
        pt: 360.0,
        alt: "Nine raised keys under one soft light, the middle one lit blue",
        aspect: 16.0 / 9.0
    )
    public static let session = Picture(
        name: "opencode-session",
        widths: [720, 1120, 1680, 2240],
        pt: 1120.0,
        alt: "OpenCode drawn by Rune: a session with a sidebar of projects and a conversation with code",
        aspect: 2560.0 / 1640.0
    )
    public static let home = Picture(
        name: "opencode-home",
        widths: [560, 1100],
        pt: 548.0,
        alt: "OpenCode drawn by Rune: the home screen with a prompt field",
        aspect: 2560.0 / 1640.0
    )
    public static let streaming = Picture(
        name: "opencode-streaming",
        widths: [560, 1100],
        pt: 548.0,
        alt: "OpenCode drawn by Rune: a reply streaming in",
        aspect: 2560.0 / 1640.0
    )

    public static func section(
        _ id: String,
        title: String,
        bp: WwwBreakpoint
    ) -> El<WwwState> {
        let h2 = bp.h2
        return col()
            .key(id)
            .role(.region)
            .label(title)
            .wFull()
            .pt(bp.phone ? 32.0 : 64.0)
            .pb(32.0)
            .child(
                text(title)
                    .key("\(id)-h")
                    .headingLevel(2)
                    .font(h2)
                    .color(WwwTokens.fg)
                    .wrap(.wrap)
                    .selectable(true)
                    .maxW(h2.size * 22.0)
            )
    }

    public static func fill(
        _ e: El<WwwState>,
        stacked: Bool,
        grow: Float
    ) -> El<WwwState> {
        stacked ? e.wFull() : e.w(0.0).grow(grow)
    }

    public static func topbar(_ s: WwwState, glow: WwwWordmark.Glow) -> El<WwwState> {
        row()
            .key("top")
            .htmlRole("banner")
            .wFull()
            .h(WwwTokens.topbarHeight)
            .justifyBetween()
            .centerY()
            .child(
                row()
                    .key("brand")
                    .href(WwwConstants.brand)
                    .label("Rune home")
                    .h(28.0)
                    .centerY()
                    .onHover { state, on, _ in
                        if on {
                            let now = state.clockNow()
                            state.glints.brand(now)
                        }
                    }
                    .child(WwwWordmark.wordmark(s.glyphs, cell: 2.0, glow: glow))
            )
            .child(
                row()
                    .key("nav")
                    .htmlRole("navigation")
                    .label("Rune")
                    .gap(24.0)
                    .child(WwwUI.navLink("nav-guide", "Guide", href: WwwConstants.docs, style: WwwTokens.text14))
                    .child(WwwUI.navLink("nav-github", "GitHub", href: WwwConstants.repo, style: WwwTokens.text14))
            )
    }

    public static func views(
        cx: Cx<WwwState>,
        images: ImageCache?,
        bp: WwwBreakpoint
    ) -> El<WwwState> {
        let stacked = bp.stackSplit
        let shot: El<WwwState> = col()
            .key("shot")
            .htmlRole("figure")
            .gap(8.0)
            .child(hello.element(images: images, cx: cx, fit: .fill).aspectRatio(hello.aspect).rounded(WwwTokens.r2))
            .child(WwwUI.prose("caption", "What it draws, rendered headless with `--snap`", style: WwwTokens.text13, color: WwwTokens.fg3))

        let split = (stacked ? col() : row())
            .key("split")
            .wFull()
            .gap(24.0)
            .mt(32.0)
            .child(fill(WwwCode.block("hello", snippet: WwwCode.helloView), stacked: stacked, grow: 1.0))
            .child(stacked ? shot.wFull().maxW(320.0) : shot.w(320.0))

        return section("views", title: "A view is a plain Rust function of your state.", bp: bp)
            .child(WwwUI.intro("views-p", "There is no markup and no macro language. `view` reads the state and returns elements; a handler changes the state and Rune draws what follows. Give an element `.motion()` and it moves to its new layout on a spring."))
            .child(split)
    }

    public static func springsIntro(_ bp: WwwBreakpoint) -> El<WwwState> {
        section("springs", title: "Every animation is a spring that keeps its speed when you change your mind.", bp: bp)
            .child(WwwUI.intro("springs-p", "Springs take SwiftUI's numbers, a duration and a bounce, and are solved exactly, so a retarget starts from where the value is and how fast it's going. Nothing animates on the first frame, a finger moves things directly, and reduced motion swaps travel for a short fade."))
    }

    public static func retargetCode() -> El<WwwState> {
        WwwCode.block("retarget", snippet: WwwCode.retarget).mt(32.0)
    }

    public static func frameIntro(_ bp: WwwBreakpoint) -> El<WwwState> {
        section("frame", title: "Every frame takes the same short path, from your input to one draw call.", bp: bp)
            .child(WwwUI.intro("frame-p", "Input changes your state. Rune calls your view, diffs it by key against the last one, lays it out with Taffy, moves what changed on springs and draws the whole window as one batch of instanced quads. At 120\u{00A0}Hz all of it has 8.33\u{00A0}ms, and an idle window draws nothing."))
    }

    private static func tile(
        cx: Cx<WwwState>,
        images: ImageCache?,
        p: Picture,
        caption: String,
        frame: (El<WwwState>) -> El<WwwState>
    ) -> El<WwwState> {
        let key = "\(p.name)-frame"
        let size = cx.layoutSize(key)
        let w = size.flatMap { $0.count >= 2 ? $0[0] : nil } ?? 360.0
        let h = size.flatMap { $0.count >= 2 ? $0[1] : nil } ?? 202.5
        let vignette: El<WwwState> = el()
            .key("vignette")
            .pin(top: 0.0, right: 0.0, bottom: 0.0, left: 0.0)
            .radialGradient(
                center: Vec2(0.5, 0.5),
                radius: .xy(w * 0.5, h * 0.5),
                stops: [
                    GradientStop(.transparent, at: 0.58),
                    GradientStop(.black, at: 1.0),
                ]
            )
            .a11yHidden()
        let img = p.element(images: images, cx: cx, fit: .fill).hFull()
        let frameEl = frame(
            el()
                .key(key)
                .wFull()
                .rounded(WwwTokens.r2)
                .clipRounded(WwwTokens.r2)
                .child(img)
                .child(vignette)
        )
        return col()
            .key("\(p.name)-tile")
            .htmlRole("figure")
            .wFull()
            .child(frameEl)
            .child(text(caption).key("caption").font(WwwTokens.text13).color(WwwTokens.fg3).wFull().textAlign(.center))
    }

    public static func gallery(
        cx: Cx<WwwState>,
        images: ImageCache?,
        bp: WwwBreakpoint
    ) -> El<WwwState> {
        let stacked = bp.stackGallery
        let metalEl = tile(cx: cx, images: images, p: metal, caption: "Liquid metal") { f in
            stacked ? f.aspectRatio(metal.aspect) : f.grow(1.0)
        }
        func small(_ p: Picture, _ caption: String) -> El<WwwState> {
            tile(cx: cx, images: images, p: p, caption: caption) { f in f.aspectRatio(p.aspect) }
        }
        let side: El<WwwState> = col()
            .key("side")
            .gap(24.0)
            .child(small(glass, "Frosted glass"))
            .child(small(light, "Raised keys under one light"))
        let body = (stacked ? col() : row())
            .key("gallery")
            .wFull()
            .gap(24.0)
            .mt(32.0)
            .child(stacked ? metalEl.wFull() : metalEl.w(24.0).grow(2.0))
            .child(fill(side, stacked: stacked, grow: 1.0))

        return section("renderer", title: "Metal, glass and light are drawn by the same renderer.", bp: bp)
            .child(WwwUI.intro("renderer-p", "They're GPU shaders, drawn live. These stills come straight out of Rune."))
            .child(body)
            .onVisible { state, on, _ in
                if on { state.seen.insert("renderer") }
            }
    }

    private static func screen(
        cx: Cx<WwwState>,
        images: ImageCache?,
        p: Picture
    ) -> El<WwwState> {
        let img = p.element(images: images, cx: cx, fit: .fill).aspectRatio(p.aspect)
        return col()
            .key("\(p.name)-fig")
            .htmlRole("figure")
            .wFull()
            .rounded(WwwTokens.r2)
            .clipRounded(WwwTokens.r2)
            .child(img)
            .child(el().key("outline").pin(top: 0.0, right: 0.0, bottom: 0.0, left: 0.0).rounded(WwwTokens.r2).border(1.0, WwwTokens.line).a11yHidden())
    }

    public static func opencode(
        cx: Cx<WwwState>,
        images: ImageCache?,
        bp: WwwBreakpoint
    ) -> El<WwwState> {
        let stacked = bp.stackGallery
        let pair = (stacked ? col() : row())
            .key("pair")
            .wFull()
            .gap(24.0)
            .child(fill(screen(cx: cx, images: images, p: home), stacked: stacked, grow: 1.0))
            .child(fill(screen(cx: cx, images: images, p: streaming), stacked: stacked, grow: 1.0))

        return section("opencode", title: "OpenCode's desktop app is the test Rune is built against.", bp: bp)
            .child(WwwUI.intro("opencode-p", "Rune's first big job is rebuilding OpenCode's desktop app and raising its bar: long streaming sessions, markdown and code, window chrome and scroll momentum. These screens are drawn by Rune."))
            .child(col().key("screens").wFull().gap(24.0).mt(32.0).child(screen(cx: cx, images: images, p: session)).child(pair))
            .onVisible { state, on, _ in
                if on { state.seen.insert("opencode") }
            }
    }

    public static let facts: [(String, String)] = [
        ("A reference renderer.", "`rune-ref` draws the same scenes on the CPU, and golden tests hold the GPU within two levels per channel of it."),
        ("A motion audit.", "Example apps run scripted scenarios headless at 120\u{00A0}fps, and a checker flags snaps, pops, jumps and retargets that lose their speed."),
        ("Over 2,600 tests", "across the framework, its components and its motion."),
    ]

    public static func agents(_ bp: WwwBreakpoint) -> El<WwwState> {
        let stacked = bp.stackSplit
        var list: El<WwwState> = (stacked ? col() : row())
            .key("facts")
            .role(.list)
            .wFull()
            .gap(24.0)
            .mt(32.0)
        for (i, (lead, rest)) in facts.enumerated() {
            let item: El<WwwState> = col()
                .key("fact-\(i)")
                .role(.listItem)
                .gap(4.0)
                .child(text(lead).key("lead").font(WwwTokens.text14Medium).color(WwwTokens.fg).wrap(.wrap).selectable(true))
                .child(WwwUI.prose("rest", rest, style: WwwTokens.text14, color: WwwTokens.fg2))
            list = list.child(fill(item, stacked: stacked, grow: 1.0))
        }
        return section("agents", title: "An agent can build, run and check a Rune app without a screen.", bp: bp)
            .child(WwwUI.intro("agents-p", "Tests drive the real runtime: tap an element by key, step the clock, read where things are. Any app renders headless to a PNG with `--snap`, to a strip of frames with `--frames`, and prints its element tree with `--tree`."))
            .child(WwwCode.block("hello-test", snippet: WwwCode.helloTest).mt(32.0))
            .child(list)
    }

    public static let platforms: [(String, String)] = [
        ("macOS", "Rune's own Metal backend"),
        ("Windows", "wgpu; windows stay hidden until their first frame"),
        ("Linux", "wgpu on X11 and Wayland"),
        ("iOS", "Embedded in UIKit or SwiftUI"),
        ("Web", "WebGPU on one canvas, experimental"),
    ]

    public static func platformsSection(_ bp: WwwBreakpoint) -> El<WwwState> {
        let stacked = bp.stackSplit
        var list: El<WwwState> = (stacked ? col() : row())
            .key("platforms-list")
            .role(.list)
            .wFull()
            .mt(32.0)
            .rounded(WwwTokens.r2)
            .border(1.0, WwwTokens.line)
        for (i, (name, note)) in platforms.enumerated() {
            let base: El<WwwState> = stacked
                ? row().justifyBetween().centerY().gap(16.0)
                : col().gap(4.0)
            var item = fill(base, stacked: stacked, grow: 1.0)
                .key(name.lowercased())
                .role(.listItem)
                .p(16.0)
                .child(text(name).key("name").font(WwwTokens.text16Medium).color(WwwTokens.fg))
                .child(
                    text(note)
                        .key("note")
                        .font(WwwTokens.text13)
                        .color(WwwTokens.fg3)
                        .wrap(.wrap)
                        .shrink()
                        .textAlign(stacked ? .trailing : .leading)
                )
            if i > 0 {
                let ruleEl: El<WwwState> = el().key("rule").bg(WwwTokens.line).a11yHidden()
                item = item.child(
                    stacked
                        ? ruleEl.pin(top: 0.0, right: 0.0, left: 0.0).h(1.0)
                        : ruleEl.pin(top: 0.0, bottom: 0.0, left: 0.0).w(1.0)
                )
            }
            list = list.child(item)
        }
        return section("platforms", title: "The same code runs on macOS, Windows, Linux, iOS and the web.", bp: bp)
            .child(list)
    }

    public static func cargoLine() -> String {
        "rune = { git = \"\(WwwConstants.repo)\", rev = \"\(WwwConstants.rev)\" }"
    }

    private static func cargoSpans(_ line: String) -> [RichSpan] {
        var spans = [RichSpan(0..<4).color(WwwTokens.codeCall)]
        var inString: Int?
        var byteOffset = 0
        for scalar in line.unicodeScalars {
            let len = scalar.utf8.count
            if scalar == "\"" {
                if let start = inString {
                    spans.append(RichSpan(start..<(byteOffset + len)).color(WwwTokens.codeString))
                    inString = nil
                } else {
                    inString = byteOffset
                }
            } else if inString == nil && (scalar == "=" || scalar == "{" || scalar == "}" || scalar == ",") {
                spans.append(RichSpan(byteOffset..<(byteOffset + len)).color(WwwTokens.fg2))
            }
            byteOffset += len
        }
        return spans
    }

    public static func cta(_ bp: WwwBreakpoint, copied: Bool) -> El<WwwState> {
        let cargo = cargoLine()
        let copy: El<WwwState> = row()
            .key("copy")
            .role(.button)
            .label(copied ? "Copied" : "Copy")
            .focusable(true)
            .h(28.0)
            .px(12.0)
            .mr(8.0)
            .rounded(14.0)
            .centerY()
            .bg(WwwTokens.surface2)
            .hover(Color.white.alpha(0.04))
            .onClick { state, tx in
                tx.copyText(cargoLine())
                state.markCopied()
            }
            .child(text(copied ? "Copied" : "Copy").font(WwwTokens.text12Medium).color(WwwTokens.fg2).a11yHidden())

        let copyLine: El<WwwState> = row()
            .key("copyline")
            .wFull()
            .maxW(832.0)
            .mt(32.0)
            .centerY()
            .rounded(WwwTokens.r2)
            .bg(WwwTokens.surface1)
            .border(1.0, WwwTokens.line)
            .child(
                col()
                    .key("scroll")
                    .w(0.0)
                    .grow(1.0)
                    .minW(0.0)
                    .scrollX()
                    .scrollEdgeFade(24.0)
                    .child(
                        rich(cargo, cargoSpans(cargo))
                            .key("cargo")
                            .font(WwwTokens.mono13)
                            .color(WwwTokens.fg)
                            .selectable(true)
                            .px(16.0)
                            .py(12.0)
                    )
            )
            .child(copy)

        return section("cta", title: "Pin a commit and start with one view.", bp: bp)
            .pb(96.0)
            .child(WwwUI.intro("cta-p", "Rune isn't on crates.io yet. Add it from Git at a commit, then start from `examples/hello`."))
            .child(copyLine)
            .child(
                row()
                    .key("actions")
                    .flexWrap()
                    .gap(12.0)
                    .mt(32.0)
                    .child(WwwUI.button("cta-guide", "Read the guide", href: WwwConstants.docs, kind: .primary))
                    .child(WwwUI.button("cta-examples", "Browse the examples", href: "\(WwwConstants.repo)/tree/dev/examples", kind: .secondary))
            )
    }

    public static func footer() -> El<WwwState> {
        row()
            .key("footer")
            .htmlRole("contentinfo")
            .wFull()
            .justifyBetween()
            .flexWrap()
            .rowGap(8.0)
            .columnGap(24.0)
            .py(32.0)
            .child(WwwUI.hairline("rule").pin(top: 0.0, right: 0.0, left: 0.0))
            .child(text("Rune is open source under the MIT license.").key("license").font(WwwTokens.text13).color(WwwTokens.fg3).selectable(true))
            .child(WwwUI.linked("made", "Made by [Anomaly](https://anoma.ly).", style: WwwTokens.text13, color: WwwTokens.fg3))
    }

    public static func notFound(_ bp: WwwBreakpoint) -> El<WwwState> {
        col()
            .key("notfound")
            .wFull()
            .py(96.0)
            .minH(480.0)
            .child(
                text("There's no page here.")
                    .key("notfound-h")
                    .headingLevel(1)
                    .font(TextStyle(size: 40.0, weight: 500.0).lh(48.0).letterSpacing(-1.0))
                    .color(WwwTokens.fg)
                    .wrap(.wrap)
            )
            .child(
                WwwUI.linked(
                    "notfound-p",
                    "Try [Rune's home page](\(WwwConstants.brand)) or the [code on GitHub](\(WwwConstants.repo)).",
                    style: bp.lede,
                    color: WwwTokens.fg2
                )
                .mt(24.0)
            )
    }
}
