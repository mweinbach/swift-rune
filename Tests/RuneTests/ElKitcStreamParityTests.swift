import Testing
@testable import Rune

@Suite("Kitc Stream Overflow & Pace Parity")
struct ElKitcStreamParityTests {

    @Test("stream_overflow (#264): overflowing edge leaves only streaming rows unclipped while fold stays clipped")
    func overflowingEdgeLeavesOnlyStreamingRowsUnclipped() {
        struct S {
            var replyH: Float = 20
            var foldH: Float = 20
            var edge: StreamEdge = .feather
        }

        func runMasks(edge: StreamEdge) -> (reply: [Float], fold: [Float]) {
            let rt = Runtime<S>(
                state: S(edge: edge),
                viewport: Vec2(320, 400),
                pixelScale: 1.0,
                systemDark: true
            ) { s, _ in
                col().size(320, 400)
                    .child(
                        col().wFull().growth(GrowthSpec(edge: s.edge))
                            .child(col().key("reply").wFull().streaming(true).child(el().wFull().h(s.replyH).bg(.white)))
                            .child(col().key("fold").wFull().arrivesWhole().child(el().wFull().h(s.foldH).bg(.white)))
                    )
            }
            _ = rt.frame(at: 0.0)
            rt.update { s, _ in
                s.replyH = 160
                s.foldH = 160
            }
            var t = 0.0
            var replyMasks: [Float] = []
            var foldMasks: [Float] = []
            for _ in 0..<20 {
                t += 1.0 / 120.0
                _ = rt.frame(at: t)
                replyMasks.append(rt.growthRowMask(forKey: "reply"))
                foldMasks.append(rt.growthRowMask(forKey: "fold"))
            }
            return (replyMasks, foldMasks)
        }

        let baseline = runMasks(edge: .feather)
        #expect(baseline.reply.contains { $0 >= 0.0 })
        #expect(baseline.fold.contains { $0 >= 0.0 })

        var overflowFeather = StreamEdge.feather
        overflowFeather.overflow = true
        let over = runMasks(edge: overflowFeather)
        #expect(over.reply.allSatisfy { $0 < 0.0 }, "overflowing edge leaves streaming reply unclipped: \(over.reply)")
        #expect(over.fold.contains { $0 >= 0.0 }, "overflowing edge still clips non-streaming fold: \(over.fold)")
    }

    @Test("stream_pace (#265): a stream climbs steadily at any pace")
    func streamPaceLagRemainsSmoothAndBounded() {
        struct Chat {
            var text: String = ""
            var streaming: Bool = true
        }

        let words = [
            "the", "follower", "keeps", "pace", "with", "whatever", "arrives,", "so", "a", "slow", "reply",
            "creeps", "steadily", "and", "a", "fast", "one", "keeps", "up", "without", "kicking", "for",
            "each", "line;", "words", "fade", "in", "under", "the", "edge", "as", "they", "come,", "and",
            "nothing", "stops", "dead", "until", "the", "stream", "pauses.",
        ]

        func pace(_ name: String) -> [Double] {
            let n = 160
            switch name {
            case "slow", "slow, wide":
                return (0..<n).map { Double($0) * 0.3 }
            case "medium":
                return (0..<n).map { Double($0) * 0.05 }
            case "fast":
                return (0..<n).map { Double($0 / 6) / 60.0 }
            default:
                var t = 0.0
                var out: [Double] = []
                var seed: UInt32 = 7
                func rand() -> Double {
                    seed = seed &* 1_103_515_245 &+ 12_345
                    return Double(seed >> 16) / 65_536.0
                }
                while out.count < n {
                    let burst = 4 + Int(rand() * 9.0)
                    for _ in 0..<burst {
                        out.append(t)
                        t += 0.012
                    }
                    t += 0.1 + rand() * 0.8
                }
                return Array(out.prefix(n))
            }
        }

        func climb(at times: [Double], width: Float) -> (ys: [Float], lags: [Float]) {
            let rt = Runtime<Chat>(
                state: Chat(text: "", streaming: true),
                viewport: Vec2(width, 400),
                pixelScale: 2.0,
                systemDark: true
            ) { s, _ in
                var stack: El<Chat> = col().key("stack").wFull().growth(GrowthSpec())
                for i in 0..<12 {
                    stack = stack.child(el().key("r\(i)").wFull().h(60))
                }
                stack = stack.child(
                    col().key("reply").wFull().streaming(s.streaming)
                        .child(text(s.text).wrap(.wrap).wFull().reveal(0.18))
                )
                return col().wFull().hFull().child(
                    col().key("scroll").wFull().grow(1).shrink().scroll(stickBottom: true).child(stack)
                )
            }
            var clock = 0.0
            _ = rt.frame(at: clock)
            for _ in 0..<60 {
                clock += 1.0 / 120.0
                _ = rt.frame(at: clock)
            }

            var ys: [Float] = []
            var lags: [Float] = []
            var next = 0
            var t = 0.0
            let end = (times.last ?? 0.0) + 1.5
            while t < end {
                t += 1.0 / 120.0
                var changed = false
                while next < times.count && times[next] <= t {
                    let word = words[next % words.count]
                    next += 1
                    let stillStreaming = next < times.count
                    rt.update { s, _ in
                        if !s.text.isEmpty { s.text.append(" ") }
                        s.text.append(word)
                        s.streaming = stillStreaming
                    }
                    changed = true
                }
                _ = changed
                clock += 1.0 / 120.0
                _ = rt.frame(at: clock)
                let topY = rt.elements().first(where: { $0.key == "r0" })!.rect[1]
                ys.append(topY)
                let h = rt.growthPresentedHeight(forKey: "reply") ?? 0
                let target = rt.growthTargetHeight(forKey: "reply") ?? h
                lags.append(target - h)
            }
            return (ys, lags)
        }

        for name in ["slow", "slow, wide", "medium", "fast", "bursty"] {
            let at = pace(name)
            let (ys, lags) = climb(at: at, width: name.hasSuffix("wide") ? 1000 : 420)
            let steps: [Float] = zip(ys, ys.dropFirst()).map { $0.0 - $0.1 }
            let first = steps.firstIndex(where: { $0 > 0.02 })
            #expect(first != nil, "\(name): expected reply to overflow")
            if let first {
                let last = min(steps.count, Int(at[at.count - 1] * 120.0))
                let rests = (first..<last).filter { steps[$0] < 0.005 }
                #expect(rests.isEmpty, "\(name): rests \(rests.count) times, first at frame \(rests.first.map(String.init) ?? "-")")
            }
            if name != "fast" {
                let most = lags.max() ?? 0
                #expect(most < 20.0, "\(name): trails its text by \(most) pt")
            }
            let landed = min(lags.count - 1, Int(at[at.count - 1] * 120.0) + 60)
            #expect(lags[landed...].allSatisfy { $0 < 0.05 }, "\(name): still \(lags[landed]) pt short 0.5 s after the last word")
        }
    }
}
