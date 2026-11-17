import Darwin
import Foundation
import Testing
@testable import Rune
import RuneMotion
import RuneRef

// MARK: - Shared Test Harness for `phases_tests.rs` & `phases_poster_tests.rs`

fileprivate enum PhaseTestHarness {
    static let defaultNow: Double = 100.0

    static func oldMeta() -> VideoPhases.PhaseMeta {
        VideoPhases.PhaseMeta(duration: 1.0, size: (64, 36), frame: 0.25, sound: false)
    }

    static func oldItemMeta() -> VideoPhases.PhaseMeta {
        VideoPhases.PhaseMeta(duration: 2.0, size: (32, 18), frame: 1.0 / 30.0, sound: false)
    }

    enum Reports: Equatable {
        case loading
        case ready
        case failed
    }

    enum FrameReport: Equatable {
        case same
        case new(Double)
        case pushFails
    }

    struct Script: Equatable {
        var onMain: Bool = true
        var makeFails: Bool = false
        var item: Reports = .loading
        var frame: FrameReport = .same
        var itemTime: Double = 0.0
        var current: Double = 0.0
        var playerRate: Float = 0.0

        static let loading = Script()
        static let ready = Script(item: .ready, itemTime: 0.4, current: 0.4, playerRate: 1.0)
        static let frame = Script(item: .ready, frame: .new(0.3), itemTime: 0.3, current: 0.3, playerRate: 1.0)
        static let atSeek = Script(item: .ready, itemTime: 0.3, current: 0.3, playerRate: 1.0)
        static let end = Script(item: .ready, itemTime: 1.0, current: 1.0, playerRate: 1.0)
        static let stopped = Script(item: .ready, itemTime: 0.4, current: 0.4, playerRate: 0.0)
        static let itemFails = Script(item: .failed)
        static let makeFails = Script(makeFails: true)
        static let pushFails = Script(item: .ready, frame: .pushFails, itemTime: 0.4, current: 0.4, playerRate: 1.0)
        static let offMain = Script(onMain: false, item: .ready, itemTime: 0.4, current: 0.4, playerRate: 1.0)
    }

    enum Done: Equatable {
        case facts
        case frame
        case frameFails
        case err
    }

    enum Sym {
        case play
        case pause
        case seek(Double)
        case rate(Float)
        case looping(Bool)
        case muted(Bool)
        case open
        case openFails
        case fail
        case clock(Double)
        case preload
        case loadAudio
        case done(Done)
        case wait(UInt64)
        case park
        case apply
        case pull(Script)
    }

    enum Cmd: Equatable {
        case none
        case ask(Double)
        case poster(UInt64)
        case make
        case drop
        case unpark
        case park
        case orient
        case muted(Bool)
        case seek(Double)
        case rate(Float)
        case restart(Float)
        case frame(UInt64)
        case placeholder
        case returned(Bool)
        case onMain
        case readRate
    }

    /// Fixed-capacity inline log (up to 16 commands per step) for zero-allocation combinatoric walks.
    struct CmdLog: Equatable {
        private var c0: Cmd = .none
        private var c1: Cmd = .none
        private var c2: Cmd = .none
        private var c3: Cmd = .none
        private var c4: Cmd = .none
        private var c5: Cmd = .none
        private var c6: Cmd = .none
        private var c7: Cmd = .none
        private var c8: Cmd = .none
        private var c9: Cmd = .none
        private var c10: Cmd = .none
        private var c11: Cmd = .none
        private var c12: Cmd = .none
        private var c13: Cmd = .none
        private var c14: Cmd = .none
        private var c15: Cmd = .none
        private(set) var count: UInt8 = 0

        mutating func push(_ cmd: Cmd) {
            switch count {
            case 0: c0 = cmd
            case 1: c1 = cmd
            case 2: c2 = cmd
            case 3: c3 = cmd
            case 4: c4 = cmd
            case 5: c5 = cmd
            case 6: c6 = cmd
            case 7: c7 = cmd
            case 8: c8 = cmd
            case 9: c9 = cmd
            case 10: c10 = cmd
            case 11: c11 = cmd
            case 12: c12 = cmd
            case 13: c13 = cmd
            case 14: c14 = cmd
            case 15: c15 = cmd
            default: preconditionFailure("CmdLog overflow")
            }
            count &+= 1
        }

        mutating func clear() {
            count = 0
        }

        func element(at idx: Int) -> Cmd {
            switch idx {
            case 0: return c0
            case 1: return c1
            case 2: return c2
            case 3: return c3
            case 4: return c4
            case 5: return c5
            case 6: return c6
            case 7: return c7
            case 8: return c8
            case 9: return c9
            case 10: return c10
            case 11: return c11
            case 12: return c12
            case 13: return c13
            case 14: return c14
            case 15: return c15
            default: return .none
            }
        }

        func contains(_ target: Cmd) -> Bool {
            for i in 0..<Int(count) where element(at: i) == target {
                return true
            }
            return false
        }

        func countMatching(_ pred: (Cmd) -> Bool) -> Int {
            var n = 0
            for i in 0..<Int(count) where pred(element(at: i)) {
                n += 1
            }
            return n
        }

        static func == (lhs: CmdLog, rhs: CmdLog) -> Bool {
            guard lhs.count == rhs.count else { return false }
            for i in 0..<Int(lhs.count) {
                if lhs.element(at: i) != rhs.element(at: i) { return false }
            }
            return true
        }
    }

    struct Pending2<T: Equatable>: Equatable {
        var first: T? = nil
        var second: T? = nil

        mutating func queue(_ request: T) {
            if first == nil {
                first = request
            } else {
                second = request
            }
        }

        mutating func answer(newest: T) -> T {
            if let a = first {
                first = second
                second = nil
                return a
            }
            return newest
        }
    }

    enum SettleView: Equatable {
        case still
        case seeking(Double, Double)
        case holding(Double)
    }

    struct View: Equatable {
        var state: PlayerState
        var playing: Bool
        var ended: Bool
        var drawn: Bool
        var anchorClock: Double?
        var anchorTime: Double?
        var rate: Float
        var seek: Double?
        var time: Double
        var duration: Double?
        var sizeW: UInt32?
        var sizeH: UInt32?
        var generation: UInt64
        var frameId: UInt64
        var poster: UInt8
        var fence: UInt64
        var player: Bool
        var ready: Bool
        var created: Double?
        var playerMuted: Bool
        var playerRate: Float
        var settle: SettleView
        var shown: Double?
        var live: Bool
        var log: CmdLog
    }

    // MARK: Old Reference Model (transcribed from `phases_tests.rs`)

    enum OldPoster: UInt8, Equatable {
        case unasked = 0
        case due = 1
        case withheld = 2
    }

    enum OldSettle: Equatable {
        case still
        case seeking(since: Double, to: Double)
        case holding(to: Double)

        mutating func seek(_ to: Double, sameFrame: Bool, now: Double) {
            self = sameFrame ? .holding(to: to) : .seeking(since: now, to: to)
        }

        mutating func framed() {
            if case .seeking = self {
                self = .still
            }
        }

        mutating func observe(current: Double, playing: Bool, audio: Bool) {
            switch self {
            case .seeking(_, let to) where audio && abs(current - to) < 0.25:
                self = .still
            case .holding(let to) where playing || abs(current - to) < 1e-3:
                self = .still
            default:
                break
            }
        }

        mutating func expire(now: Double) {
            if case .seeking(let since, _) = self, (now - since) > 2.0 {
                self = .still
            }
        }

        var pending: Bool { self != .still }
        var waiting: Bool {
            if case .seeking = self { return true }
            return false
        }
    }

    struct OldPlayer {
        var rate: Float
        var muted: Bool
        var ready: Bool
        var created: Double
        var settle: OldSettle
        var shown: Double?
    }

    struct Old: @unchecked Sendable {
        var audio: Bool
        var playing: Bool = false
        var rate: Float = 1.0
        var looping: Bool = false
        var muted: Bool
        var seek: Double? = nil
        var time: Double = 0.0
        var duration: Double? = nil
        var size: (UInt32, UInt32)? = nil
        var meta: VideoPhases.PhaseMeta? = nil
        var ended: Bool = false
        var failed: VideoPhases.PhaseError? = nil
        var placeholder: Bool = false
        var generation: UInt64 = 0
        var frameId: UInt64 = 0
        var anchorClock: Double? = nil
        var anchorTime: Double? = nil
        var player: OldPlayer? = nil
        var poster: OldPoster = .unasked
        var done: (UInt64, Done)? = nil
        var fence: UInt64 = 0
        var asked: UInt64 = 0
        var fenceAt: Double? = nil
        var pending: Pending2<UInt64> = Pending2()
        var now: Double
        var log: CmdLog = CmdLog()

        init(audio: Bool, now: Double) {
            self.audio = audio
            self.muted = !audio
            self.now = now
        }

        mutating func play() {
            if failed != nil { return }
            if ended {
                ended = false
                seek = 0.0
                time = 0.0
            }
            playing = true
            anchorClock = nil
            anchorTime = nil
        }

        mutating func pause() {
            playing = false
            anchorClock = nil
            anchorTime = nil
        }

        mutating func doSeek(_ seconds: Double) {
            let s = seconds.isFinite ? max(0.0, seconds) : 0.0
            let clamped = duration.map { min(s, $0) } ?? s
            seek = clamped
            time = clamped
            ended = false
            anchorClock = nil
            anchorTime = nil
        }

        mutating func setRate(_ r: Float) {
            rate = r
            anchorClock = nil
            anchorTime = nil
        }

        var state: PlayerState {
            if let e = failed {
                return .failed(e.message)
            } else if meta == nil {
                return .loading
            } else if playing {
                return .playing
            } else if ended {
                return .ended
            } else {
                return .ready
            }
        }

        var opened: Bool { meta != nil || failed != nil }

        mutating func open(_ result: Result<VideoPhases.PhaseMeta, VideoPhases.PhaseError>) {
            switch result {
            case .success(let m):
                meta = m
                duration = m.duration
                size = m.size
                time = min(time, m.duration)
                seek = seek.map { min($0, m.duration) }
                generation &+= 1
            case .failure(let e):
                doFail(e)
            }
        }

        mutating func doFail(_ error: VideoPhases.PhaseError) {
            if failed == nil {
                failed = error
                playing = false
                generation &+= 1
            }
        }

        mutating func nextFrameId() -> UInt64 {
            frameId &+= 1
            return frameId
        }

        mutating func advanceVirtual(_ now: Double) {
            guard let m = meta else { return }
            if let t = seek {
                seek = nil
                time = min(t, m.duration)
                anchorClock = nil
                anchorTime = nil
            }
            if !playing { return }
            let startClock: Double
            let startTime: Double
            if let ac = anchorClock, let at = anchorTime, ac <= now {
                startClock = ac
                startTime = at
            } else {
                startClock = now
                startTime = time
                anchorClock = startClock
                anchorTime = startTime
            }
            let t = startTime + max(0.0, now - startClock) * Double(rate)
            if t < m.duration {
                time = t
            } else if looping && m.duration > 0.0 {
                time = t.truncatingRemainder(dividingBy: m.duration)
            } else {
                time = m.duration
                playing = false
                ended = true
                anchorClock = nil
                anchorTime = nil
                generation &+= 1
            }
        }

        mutating func observe(_ observedTime: Double, atEnd: Bool) -> Bool {
            time = duration.map { min(max(0.0, observedTime), $0) } ?? observedTime
            guard playing && atEnd else { return false }
            if looping {
                time = 0.0
                return true
            }
            playing = false
            ended = true
            generation &+= 1
            return false
        }

        mutating func loadAudio() {
            if poster == .unasked && !opened {
                requestPoster(at: 0.0)
            }
        }

        mutating func preload() {
            if audio || player != nil || poster != .unasked || failed != nil { return }
            requestPoster(at: time)
        }

        mutating func requestPoster(at: Double) {
            poster = audio ? .withheld : .due
            if !audio && fenceAt != at {
                fence &+= 1
                fenceAt = at
            }
            asked = fence
            pending.queue(fence)
            log.push(.ask(at))
        }

        mutating func takePoster(surface: Bool) {
            guard let (askedSeq, d) = done else { return }
            done = nil
            if failed != nil { return }
            let current = (askedSeq == fence)
            switch d {
            case .err:
                if current && !overtaken && (!audio || !opened) {
                    doFail(.loadFailed)
                }
            case .facts, .frame, .frameFails:
                if !opened {
                    open(.success(oldMeta()))
                }
                if current && !overtaken && d != .facts && surface && player == nil && poster == .due {
                    let id = nextFrameId()
                    if d == .frameFails {
                        doFail(.posterPushFailed)
                    } else {
                        log.push(.poster(id))
                    }
                }
            }
        }

        var overtaken: Bool {
            guard let askedTime = fenceAt, let target = seek else { return false }
            let clamp: (Double) -> Double = { t in duration.map { min(t, $0) } ?? t }
            return clamp(target) != clamp(askedTime)
        }

        mutating func dropPlayer() {
            if player != nil {
                player = nil
                log.push(.drop)
            }
        }

        mutating func checkItem(_ s: Script, _ now: Double) -> Bool {
            guard var p = player else { return false }
            let failure: VideoPhases.PhaseError?
            if s.item == .failed {
                failure = .itemFailed
            } else if s.item != .ready && (now - p.created) > 30.0 {
                failure = .timedOutLoading
            } else {
                failure = nil
            }
            if let e = failure {
                doFail(e)
                dropPlayer()
                return false
            }
            if s.item == .ready && !p.ready {
                p.ready = true
                player = p
                log.push(.orient)
                if !opened {
                    open(.success(oldItemMeta()))
                }
            }
            return true
        }

        mutating func ensurePlayer(_ s: Script, _ now: Double) -> Bool {
            if player != nil { return true }
            if audio && !opened {
                if poster == .unasked {
                    requestPoster(at: 0.0)
                }
                return false
            }
            if s.makeFails {
                doFail(.couldNotMakePlayer)
                return false
            }
            log.push(.make)
            if time > 0.0 && seek == nil {
                seek = time
            }
            player = OldPlayer(rate: 0.0, muted: false, ready: false, created: now, settle: .still, shown: nil)
            if !audio {
                fence &+= 1
                fenceAt = nil
            }
            poster = .withheld
            return true
        }

        mutating func reconcile(_ now: Double) {
            guard var p = player else { return }
            if p.muted != muted {
                log.push(.muted(muted))
                p.muted = muted
            }
            if p.ready, let t = seek {
                seek = nil
                log.push(.seek(t))
                let sameFrame = !playing && (meta.flatMap { m in
                    p.shown.map { m.frameIndex($0) == m.frameIndex(t) }
                } ?? false)
                p.settle.seek(t, sameFrame: sameFrame, now: now)
            }
            if p.ready {
                let r = playing ? rate : 0.0
                if p.rate != r {
                    log.push(.rate(r))
                    p.rate = r
                }
            }
            player = p
        }

        mutating func follow(_ s: Script, _ now: Double, frameTime: Double?) {
            guard var p = player else { return }
            p.settle.observe(current: s.current, playing: playing, audio: frameTime == nil)
            let seeking = p.settle.pending
            let stopped = p.rate > 0.0 && {
                log.push(.readRate)
                return s.playerRate == 0.0
            }()
            let atEnd = !seeking && ((duration.map { s.current >= $0 - 1e-3 } ?? false) || stopped)
            let observedTime: Double
            if seeking {
                observedTime = time
            } else if playing && !atEnd {
                observedTime = max(0.0, frameTime ?? s.current)
            } else {
                observedTime = s.current
            }
            if observe(observedTime, atEnd: atEnd) {
                log.push(.restart(rate))
                p.rate = rate
                p.settle.seek(0.0, sameFrame: false, now: now)
                generation &+= 1
            } else if !playing {
                p.rate = 0.0
            }
            player = p
        }

        mutating func finish(_ now: Double) -> Bool {
            guard var p = player else { return false }
            p.settle.expire(now: now)
            player = p
            let active = playing || p.settle.waiting || !p.ready
            let park = p.ready && !active
            log.push(park ? .park : .unpark)
            return active
        }

        mutating func pull(_ s: Script) -> Bool {
            let now = self.now
            takePoster(surface: true)
            if failed != nil {
                dropPlayer()
                return false
            }
            log.push(.onMain)
            if !s.onMain { return false }
            if player == nil && !playing {
                let want: Double?
                if let t = seek {
                    seek = nil
                    want = t
                } else {
                    want = (poster == .unasked) ? time : nil
                }
                if let at = want {
                    requestPoster(at: at)
                }
                return false
            }
            let fresh = (player == nil)
            if !ensurePlayer(s, now) { return false }
            if fresh { log.push(.unpark) }
            if !checkItem(s, now) { return false }
            reconcile(now)
            if player?.ready == true {
                switch s.frame {
                case .same:
                    break
                case .new(let shown):
                    let id = nextFrameId()
                    log.push(.frame(id))
                    player!.shown = shown
                    player!.settle.framed()
                case .pushFails:
                    _ = nextFrameId()
                    doFail(.framePushFailed)
                    dropPlayer()
                    return false
                }
                follow(s, now, frameTime: s.itemTime)
            }
            return finish(now)
        }

        mutating func stepAudio(_ s: Script) -> Bool {
            log.push(.onMain)
            if !s.onMain { return false }
            let now = self.now
            takePoster(surface: false)
            if failed != nil {
                dropPlayer()
                return false
            }
            if player == nil && !playing { return false }
            let fresh = (player == nil)
            if !ensurePlayer(s, now) { return false }
            if fresh { log.push(.unpark) }
            if !checkItem(s, now) { return false }
            reconcile(now)
            if player?.ready != true { return true }
            follow(s, now, frameTime: nil)
            return finish(now)
        }

        mutating func sharedPull(_ s: Script) -> Bool {
            if audio { return stepAudio(s) }
            let active = pull(s)
            if failed != nil && !placeholder {
                placeholder = true
                log.push(.placeholder)
            }
            return active && failed == nil
        }

        mutating func apply(_ s: Script) {
            if failed != nil { return }
            if audio {
                let needsTick = stepAudio(s)
                log.push(.returned(needsTick))
                return
            }
            if player == nil { return }
            reconcile(now)
            if playing { log.push(.unpark) }
        }

        mutating func park() {
            let p = player
            player = nil
            if !audio && (p?.shown == nil) && p != nil {
                poster = .unasked
            }
        }

        mutating func run(_ sym: Sym) {
            switch sym {
            case .play: play()
            case .pause: pause()
            case .seek(let t): doSeek(t)
            case .rate(let r): setRate(r)
            case .looping(let l): looping = l
            case .muted(let m): muted = m
            case .open: open(.success(oldMeta()))
            case .openFails: open(.failure(.openFailed))
            case .fail: doFail(.genericFailed)
            case .clock(let t): advanceVirtual(t)
            case .preload: preload()
            case .loadAudio: loadAudio()
            case .done(let d): done = (pending.answer(newest: asked), d)
            case .wait(let s): now += Double(s)
            case .park: park()
            case .apply: apply(.ready)
            case .pull(let s):
                let active = sharedPull(s)
                log.push(.returned(active))
            }
        }

        func view() -> View {
            let settleView: SettleView
            if let p = player {
                switch p.settle {
                case .still: settleView = .still
                case .seeking(let since, let to): settleView = .seeking(since, to)
                case .holding(let to): settleView = .holding(to)
                }
            } else {
                settleView = .still
            }
            return View(
                state: state,
                playing: playing,
                ended: ended && failed == nil,
                drawn: placeholder && failed != nil,
                anchorClock: playing ? anchorClock : nil,
                anchorTime: playing ? anchorTime : nil,
                rate: rate,
                seek: seek,
                time: time,
                duration: duration,
                sizeW: size?.0,
                sizeH: size?.1,
                generation: generation,
                frameId: frameId,
                poster: poster.rawValue,
                fence: fence,
                player: player != nil,
                ready: player?.ready == true,
                created: player?.created,
                playerMuted: player?.muted == true,
                playerRate: player?.rate ?? 0.0,
                settle: settleView,
                shown: player?.shown,
                live: player.map { $0.ready && $0.rate > 0.0 && !$0.settle.waiting } ?? false,
                log: log
            )
        }
    }

    // MARK: New Model (running real `VideoPhases.phaseStep` + `VideoTurn.phaseTurn`)

    struct Fake: PhasePort {
        var script: Script = .ready
        var checked: Bool = false
        var surface: Bool
        var done: (AttemptToken, Done)? = nil
        var kept: Done? = nil
        var asked: AttemptToken = AttemptToken(0)
        var pending: Pending2<AttemptToken> = Pending2()
        var player: Bool = false
        var now: Double
        var log: CmdLog = CmdLog()

        mutating func onMain() -> Bool {
            if !checked {
                checked = true
                log.push(.onMain)
            }
            return script.onMain
        }

        mutating func takePoster() -> (AttemptToken, Result<VideoPhases.PhaseMeta, VideoPhases.PhaseError>)? {
            guard let (attempt, d) = done else { return nil }
            done = nil
            if d == .err {
                return (attempt, .failure(.loadFailed))
            }
            kept = d
            return (attempt, .success(oldMeta()))
        }

        mutating func showPoster(nextId: () -> UInt64) -> Result<Void, VideoPhases.PhaseError> {
            let k = kept
            kept = nil
            switch (k, surface) {
            case (.frame?, true):
                let id = nextId()
                log.push(.poster(id))
                return .success(())
            case (.frameFails?, true):
                _ = nextId()
                return .failure(.posterPushFailed)
            default:
                return .success(())
            }
        }

        mutating func askPoster(at: Double, attempt: AttemptToken) {
            asked = attempt
            pending.queue(attempt)
            log.push(.ask(at))
        }

        mutating func makePlayer() -> Result<Double, VideoPhases.PhaseError> {
            if script.makeFails {
                return .failure(.couldNotMakePlayer)
            }
            log.push(.make)
            player = true
            return .success(now)
        }

        mutating func dropPlayer() {
            player = false
            log.push(.drop)
        }

        mutating func unpark() {
            log.push(.unpark)
        }

        func item() -> VideoPhases.PhaseItem {
            switch script.item {
            case .loading: return .loading
            case .ready: return .ready
            case .failed: return .failed(.itemFailed)
            }
        }

        mutating func orient() {
            log.push(.orient)
        }

        func itemFacts() -> VideoPhases.PhaseMeta {
            oldItemMeta()
        }

        func alive() -> Bool { player }

        mutating func setMuted(_ muted: Bool) {
            log.push(.muted(muted))
        }

        mutating func setVolume(_: Float) {}

        mutating func seekTo(_ at: Double) {
            log.push(.seek(at))
        }

        mutating func setRate(_ rate: Float) {
            log.push(.rate(rate))
        }

        mutating func restart(_ rate: Float) {
            log.push(.restart(rate))
        }

        mutating func frame(nextId: () -> UInt64) -> (Double, Result<Double?, VideoPhases.PhaseError>) {
            let landed: Result<Double?, VideoPhases.PhaseError>
            switch script.frame {
            case .same:
                landed = .success(nil)
            case .new(let shown):
                let id = nextId()
                log.push(.frame(id))
                landed = .success(shown)
            case .pushFails:
                _ = nextId()
                landed = .failure(.framePushFailed)
            }
            return (script.itemTime, landed)
        }

        func current() -> Double { script.current }

        mutating func stopped() -> Bool {
            log.push(.readRate)
            return script.playerRate == 0.0
        }
    }

    struct New: @unchecked Sendable {
        var c: VideoPhases.PhaseControl
        var fake: Fake

        init(audio: Bool, now: Double) {
            let kind: MediaKind = audio ? .audio : .video
            self.c = VideoPhases.PhaseControl(kind: kind, muted: !audio)
            self.fake = Fake(surface: !audio, now: now)
        }

        mutating func tick(_ script: Script) -> Bool {
            let audio = (c.kind == .audio)
            if audio {
                fake.log.push(.onMain)
                if !script.onMain { return false }
            }
            fake.script = script
            fake.checked = audio
            let now = fake.now
            switch VideoTurn.phaseTurn(&c, port: &fake, now: now) {
            case .idle: return false
            case .loading: return true
            case .finished:
                let (active, park) = (c.isActive, c.isParkable)
                fake.log.push(park ? .park : .unpark)
                return active
            }
        }

        mutating func sharedPull(_ script: Script) -> Bool {
            let active = tick(script)
            if c.kind == .audio { return active }
            for effect in VideoPhases.phaseStep(&c, .drawn) where effect == .placeholder {
                fake.log.push(.placeholder)
            }
            return active && !c.isFailed
        }

        mutating func apply() {
            if c.isFailed { return }
            if c.kind == .audio {
                let needsTick = tick(.ready)
                fake.log.push(.returned(needsTick))
                return
            }
            if !fake.player { return }
            let now = fake.now
            fake.script = .ready
            VideoTurn.phaseReconcile(&c, port: &fake, now: now)
            if c.isPlaying {
                fake.log.push(.unpark)
            }
        }

        mutating func send(_ event: VideoPhases.PhaseEvent) {
            let effects = VideoPhases.phaseStep(&c, event)
            VideoTurn.phaseCarry(&c, port: &fake, effects: effects)
        }

        mutating func run(_ sym: Sym) {
            switch sym {
            case .play: send(.play)
            case .pause: send(.pause)
            case .seek(let t): send(.seek(t))
            case .rate(let r): send(.rate(r))
            case .looping(let l): c.looping = l
            case .muted(let m): c.muted = m
            case .open: c.open(.success(oldMeta()))
            case .openFails: c.open(.failure(.openFailed))
            case .fail: c.fail(.genericFailed)
            case .clock(let t): c.advanceVirtual(at: t)
            case .preload: send(.preload)
            case .loadAudio: send(.loadAudio)
            case .done(let d): fake.done = (fake.pending.answer(newest: fake.asked), d)
            case .wait(let s): fake.now += Double(s)
            case .park:
                _ = VideoPhases.phaseStep(&c, .parked)
                fake.player = false
            case .apply: apply()
            case .pull(let s):
                let active = sharedPull(s)
                fake.log.push(.returned(active))
            }
        }

        func view() -> View {
            precondition(c.stage.hasPlayer == fake.player, "stage must match native player presence")
            let created: Double?
            let playerMuted: Bool
            let playerRate: Float
            let settleView: SettleView
            let shown: Double?
            switch c.stage {
            case .loading(let cr, let m, _):
                created = cr
                playerMuted = m
                playerRate = 0.0
                settleView = .still
                shown = nil
            case .ready(let cr, let m, _, let r, let settle, let sh):
                created = cr
                playerMuted = m
                playerRate = r
                if settle.isWaiting {
                    settleView = .seeking(settle.since, settle.time)
                } else if settle.isHolding {
                    settleView = .holding(settle.time)
                } else {
                    settleView = .still
                }
                shown = sh
            default:
                created = nil
                playerMuted = false
                playerRate = 0.0
                settleView = .still
                shown = nil
            }
            let posterVal: UInt8
            switch c.stage {
            case .unasked: posterVal = 0
            case .poster: posterVal = 1
            default: posterVal = 2
            }
            let drawn: Bool
            if case .failed(_, true) = c.run { drawn = true } else { drawn = false }
            return View(
                state: c.state,
                playing: c.isPlaying,
                ended: c.run == .ended,
                drawn: drawn,
                anchorClock: c.run.anchor?.0,
                anchorTime: c.run.anchor?.1,
                rate: c.rate,
                seek: c.seek,
                time: c.time,
                duration: c.duration,
                sizeW: c.size?.0,
                sizeH: c.size?.1,
                generation: c.generation,
                frameId: c.frameId,
                poster: posterVal,
                fence: c.posters.current,
                player: c.stage.hasPlayer,
                ready: c.stage.isReady,
                created: created,
                playerMuted: playerMuted,
                playerRate: playerRate,
                settle: settleView,
                shown: shown,
                live: c.isLive,
                log: fake.log
            )
        }
    }

    static func clip(audio: Bool, _ script: [Sym]) -> New {
        var n = New(audio: audio, now: defaultNow)
        for sym in script {
            n.run(sym)
        }
        return n
    }

    static func postersShown(_ n: New) -> Int {
        n.fake.log.countMatching {
            if case .poster = $0 { return true }
            return false
        }
    }

    static func descend(
        _ new: New,
        _ old: Old,
        alphabet: [Sym],
        depth: Int,
        walked: inout UInt64
    ) {
        if depth == 0 { return }
        for sym in alphabet {
            var n = new
            var o = old
            n.run(sym)
            o.run(sym)
            if n.view() != o.view() {
                #expect(n.view() == o.view(), "mismatch after symbol \(sym)")
                return
            }
            n.fake.log.clear()
            o.log.clear()
            walked &+= 1
            descend(n, o, alphabet: alphabet, depth: depth - 1, walked: &walked)
        }
    }

    static func walk(prefix: [Sym], alphabet: [Sym], depth: Int) {
        let now = defaultNow
        for audio in [false, true] {
            var new = New(audio: audio, now: now)
            var old = Old(audio: audio, now: now)
            for sym in prefix {
                new.run(sym)
                old.run(sym)
                #expect(new.view() == old.view())
                new.fake.log.clear()
                old.log.clear()
            }
            struct SendablePtr<T>: @unchecked Sendable {
                let ptr: UnsafeMutablePointer<T>
            }
            let counts = UnsafeMutablePointer<UInt64>.allocate(capacity: alphabet.count)
            counts.initialize(repeating: 0, count: alphabet.count)
            defer { counts.deallocate() }
            let sendableCounts = SendablePtr(ptr: counts)
            let baseNew = new
            let baseOld = old

            DispatchQueue.concurrentPerform(iterations: alphabet.count) { idx in
                var n = baseNew
                var o = baseOld
                let sym = alphabet[idx]
                n.run(sym)
                o.run(sym)
                if n.view() != o.view() {
                    #expect(n.view() == o.view(), "mismatch at root symbol \(sym)")
                    return
                }
                n.fake.log.clear()
                o.log.clear()
                var localWalked: UInt64 = 1
                descend(n, o, alphabet: alphabet, depth: depth - 1, walked: &localWalked)
                sendableCounts.ptr[idx] = localWalked
            }

            var totalWalked: UInt64 = 0
            for idx in 0..<alphabet.count {
                totalWalked &+= counts[idx]
            }
            var expectedMin: UInt64 = 1
            for _ in 0..<depth {
                expectedMin *= UInt64(alphabet.count)
            }
            #expect(totalWalked >= expectedMin)
        }
    }
}

// MARK: - 1. Video Phases Poster Parity Tests (`phases_poster_tests.rs`, 12 tests)

@Suite("Video Phases Poster Parity Tests")
struct VideoPhasesPosterParityTests {
    fileprivate typealias H = PhaseTestHarness

    @Test("a_poster_error_overtaken_by_a_seek_waits_for_the_new_time")
    func aPosterErrorOvertakenByASeekWaitsForTheNewTime() {
        var n = H.clip(audio: false, [.pull(.loading), .seek(0.3)])
        let stale = n.fake.asked
        n.fake.done = (stale, .err)
        n.run(.pull(.loading))

        #expect(!n.c.isFailed)
        #expect(n.fake.log.contains(.ask(0.3)))
        let current = n.fake.asked
        #expect(current != stale)

        n.fake.done = (current, .frame)
        n.run(.pull(.loading))
        #expect(H.postersShown(n) == 1)
    }

    @Test("a_poster_frame_overtaken_by_a_seek_does_not_show_before_the_new_time")
    func aPosterFrameOvertakenByASeekDoesNotShowBeforeTheNewTime() {
        var n = H.clip(audio: false, [.pull(.loading), .seek(0.3)])
        let stale = n.fake.asked
        n.fake.done = (stale, .frame)
        n.run(.pull(.loading))

        #expect(H.postersShown(n) == 0)
        #expect(n.c.meta != nil)
        let current = n.fake.asked
        #expect(current != stale)

        n.fake.done = (current, .frame)
        n.run(.pull(.loading))
        #expect(H.postersShown(n) == 1)
    }

    @Test("a_seek_past_the_end_still_shows_the_poster_its_length_clamps_to")
    func aSeekPastTheEndStillShowsThePosterItsLengthClampsTo() {
        var n = H.clip(audio: false, [.seek(1.0), .pull(.loading), .seek(2.0)])
        let stale = n.fake.asked
        n.fake.done = (stale, .frame)
        n.run(.pull(.loading))

        #expect(n.c.duration == 1.0)
        #expect(H.postersShown(n) == 1)
    }

    @Test("a_poster_after_a_failed_one_leaves_the_placeholder")
    func aPosterAfterAFailedOneLeavesThePlaceholder() {
        var n = H.clip(audio: false, [.pull(.loading), .seek(0.3), .pull(.loading), .done(.err), .pull(.loading)])
        #expect(n.fake.log.countMatching { if case .ask = $0 { return true }; return false } == 2)
        #expect(!n.c.isFailed)
        n.run(.done(.err))
        n.run(.pull(.loading))
        #expect(n.c.run == .failed(error: .loadFailed, drawn: true))
        #expect(n.fake.log.contains(.placeholder))
        let frameId = n.c.frameId

        n.fake.done = (n.fake.asked, .frame)
        n.run(.pull(.loading))

        #expect(H.postersShown(n) == 0)
        #expect(n.c.frameId == frameId)
        #expect(n.c.run == .failed(error: .loadFailed, drawn: true))
    }

    @Test("a_late_poster_error_leaves_a_working_player_playing")
    func aLatePosterErrorLeavesAWorkingPlayerPlaying() {
        var n = H.clip(audio: false, [.preload, .play, .pull(.frame)])
        #expect(n.fake.log.contains(.frame(1)))
        let generation = n.c.generation

        n.run(.done(.err))
        n.run(.pull(.frame))

        #expect(n.c.isPlaying)
        #expect(n.c.stage.isReady)
        #expect(!n.fake.log.contains(.drop))
        #expect(n.c.generation == generation)
    }

    @Test("a_request_from_before_a_player_does_not_answer_the_one_after_it")
    func aRequestFromBeforeAPlayerDoesNotAnswerTheOneAfterIt() {
        var n = H.clip(audio: false, [.preload, .play, .pull(.loading), .pause, .park, .pull(.loading)])
        let stale = AttemptToken(0)
        let current = n.fake.asked
        #expect(stale != current)
        #expect(n.c.stage == .poster)

        n.fake.done = (stale, .frame)
        n.run(.pull(.loading))
        #expect(H.postersShown(n) == 0)
        #expect(n.c.meta != nil)

        n.fake.done = (current, .frame)
        n.run(.pull(.loading))
        #expect(H.postersShown(n) == 1)
    }

    @Test("a_poster_for_an_older_paused_seek_neither_shows_nor_fails")
    func aPosterForAnOlderPausedSeekNeitherShowsNorFails() {
        var n = H.clip(audio: false, [.pull(.loading), .seek(0.3), .pull(.loading)])
        #expect(n.fake.log.countMatching { if case .ask = $0 { return true }; return false } == 2)
        let older = n.fake.pending.first!
        let newer = n.fake.asked
        #expect(older != newer)

        n.fake.done = (older, .frame)
        n.run(.pull(.loading))
        #expect(H.postersShown(n) == 0)
        #expect(n.c.meta != nil)

        n.fake.done = (older, .err)
        n.run(.pull(.loading))
        #expect(!n.c.isFailed)

        n.fake.done = (newer, .frame)
        n.run(.pull(.loading))
        #expect(H.postersShown(n) == 1)
    }

    @Test("posters_for_repeated_seeks_to_one_time_all_show")
    func postersForRepeatedSeeksToOneTimeAllShow() {
        var c = VideoPhases.PhaseControl()
        let meta = VideoPhases.PhaseMeta(duration: 1.0, size: (64, 36), frame: 0.25, sound: false)
        var owed: AttemptToken? = nil
        var shown = 0
        for _ in 0..<30 {
            _ = VideoPhases.phaseStep(&c, .seek(0.3))
            let effects = VideoPhases.phaseStep(&c, .pull)
            guard effects.count == 1, case .askPoster(_, let attempt) = effects.array[0] else {
                Issue.record("expected AskPoster")
                return
            }
            let prev = owed
            owed = attempt
            if let answered = prev,
               VideoPhases.phaseStep(&c, .posterDone(attempt: answered, result: .success(meta))) == .one(.showPoster) {
                shown += 1
            }
        }
        #expect(shown == 29)
    }

    @Test("a_superseded_poster_keeps_the_clips_frame_timing")
    func aSupersededPosterKeepsTheClipsFrameTiming() {
        var c = VideoPhases.PhaseControl()
        let preloadEffects = VideoPhases.phaseStep(&c, .preload)
        guard preloadEffects.count == 1, case .askPoster(0.0, let stale) = preloadEffects.array[0] else {
            Issue.record("expected AskPoster(0.0, ...)")
            return
        }
        _ = VideoPhases.phaseStep(&c, .play)
        let now = 100.0
        _ = VideoPhases.phaseStep(&c, .playerMade(created: now))
        let sixty = VideoPhases.PhaseMeta(duration: 1.0, size: (64, 36), frame: 1.0 / 60.0, sound: false)
        #expect(VideoPhases.phaseStep(&c, .posterDone(attempt: stale, result: .success(sixty))).isEmpty)
        for effect in VideoPhases.phaseStep(&c, .item(.ready, now: now)) {
            if effect == .readFacts {
                c.open(.success(VideoPhases.PhaseMeta(duration: 1.0, size: (64, 36), frame: 1.0 / 30.0, sound: false)))
            }
        }
        _ = VideoPhases.phaseStep(&c, .framed(shown: 0.0))
        _ = VideoPhases.phaseStep(&c, .pause)
        _ = VideoPhases.phaseStep(&c, .seek(0.02))
        _ = VideoPhases.phaseStep(&c, .reconcile(now: now))

        #expect(c.meta?.frame == 1.0 / 60.0)
        if case .ready(_, _, _, _, let settle, _) = c.stage {
            #expect(settle.isWaiting)
        } else {
            Issue.record("expected ready stage")
        }
    }

    @Test("an_audio_load_failure_fails_the_clip")
    func anAudioLoadFailureFailsTheClip() {
        let n = H.clip(audio: true, [.loadAudio, .done(.err), .pull(.ready)])
        #expect(n.c.state == .failed("load failed"))
    }

    @Test("an_audio_load_error_after_another_open_changes_nothing")
    func anAudioLoadErrorAfterAnotherOpenChangesNothing() {
        var n = H.clip(audio: true, [.loadAudio, .open, .play, .pull(.ready)])
        #expect(n.c.stage.isReady)
        let generation = n.c.generation

        n.run(.done(.err))
        n.run(.pull(.ready))

        #expect(n.c.state == .playing)
        #expect(!n.fake.log.contains(.drop))
        #expect(n.c.generation == generation)
    }

    @Test("an_audio_load_error_before_another_open_fails_the_clip")
    func anAudioLoadErrorBeforeAnotherOpenFailsTheClip() {
        var n = H.clip(audio: true, [.loadAudio, .play, .done(.err), .pull(.ready)])
        #expect(n.c.state == .failed("load failed"))
        n.run(.open)
        n.run(.pull(.ready))
        #expect(n.c.state == .failed("load failed"))
        #expect(!n.fake.log.contains(.make))
    }

    @Test("overlapping_requests_either_side_of_a_player_answer_for_themselves")
    func overlappingRequestsEitherSideOfAPlayerAnswerForThemselves() {
        H.walk(
            prefix: [.preload, .play, .pull(.loading), .pause, .park, .pull(.loading)],
            alphabet: [.play, .pause, .seek(0.3), .done(.err), .done(.frame), .done(.facts), .park, .pull(.loading), .pull(.frame)],
            depth: 6
        )
    }

    @Test("paused_seeks_answer_for_their_own_requests")
    func pausedSeeksAnswerForTheirOwnRequests() {
        H.walk(
            prefix: [.pull(.loading), .seek(0.3), .pull(.loading)],
            alphabet: [.seek(0.6), .done(.err), .done(.frame), .done(.frameFails), .open, .play, .pull(.loading), .pull(.frame)],
            depth: 6
        )
    }

    @Test("late_poster_answers_in_any_order_match_the_fenced_flags")
    func latePosterAnswersInAnyOrderMatchTheFencedFlags() {
        H.walk(
            prefix: [],
            alphabet: [.play, .pause, .seek(0.3), .preload, .done(.err), .done(.frame), .done(.frameFails), .fail, .park, .pull(.loading), .pull(.frame)],
            depth: 6
        )
    }
}

// MARK: - 2. Video Phases Parity Tests (`phases_tests.rs`, 8 tests)

@Suite("Video Phases Parity Tests")
struct VideoPhasesParityTests {
    fileprivate typealias H = PhaseTestHarness

    @Test("the_handle_and_the_headless_clock_match_the_old_flags")
    func theHandleAndTheHeadlessClockMatchTheOldFlags() {
        H.walk(
            prefix: [],
            alphabet: [.play, .pause, .seek(0.3), .seek(9.0), .seek(.nan), .rate(2.0), .looping(true), .open, .openFails, .fail, .clock(0.0), .clock(0.4), .clock(2.0)],
            depth: 5
        )
    }

    @Test("a_playing_headless_clip_ends_loops_and_rewinds_like_the_old_flags")
    func aPlayingHeadlessClipEndsLoopsAndRewindsLikeTheOldFlags() {
        H.walk(
            prefix: [.open, .play],
            alphabet: [.play, .pause, .seek(0.3), .rate(2.0), .looping(true), .looping(false), .clock(0.0), .clock(0.4), .clock(2.0)],
            depth: 6
        )
    }

    @Test("every_report_in_any_order_matches_the_old_flags")
    func everyReportInAnyOrderMatchesTheOldFlags() {
        H.walk(
            prefix: [],
            alphabet: [
                .play, .pause, .seek(0.3), .muted(false),
                .done(.frame), .done(.facts), .done(.frameFails), .done(.err),
                .preload, .loadAudio, .fail, .park, .apply, .wait(31),
                .pull(.loading), .pull(.frame), .pull(.end), .pull(.stopped),
                .pull(.itemFails), .pull(.makeFails), .pull(.pushFails), .pull(.offMain),
            ],
            depth: 5
        )
    }

    @Test("posters_and_players_race_like_the_old_flags")
    func postersAndPlayersRaceLikeTheOldFlags() {
        H.walk(
            prefix: [],
            alphabet: [.play, .pause, .seek(0.3), .done(.frame), .done(.facts), .preload, .pull(.loading), .pull(.frame), .park],
            depth: 7
        )
    }

    @Test("a_failing_poster_or_frame_stops_the_clip_like_the_old_flags")
    func aFailingPosterOrFrameStopsTheClipLikeTheOldFlags() {
        H.walk(
            prefix: [],
            alphabet: [.play, .done(.frameFails), .done(.frame), .pull(.loading), .pull(.pushFails), .pull(.frame), .park],
            depth: 6
        )
    }

    @Test("a_ready_player_seeks_ends_and_parks_like_the_old_flags")
    func aReadyPlayerSeeksEndsAndParksLikeTheOldFlags() {
        H.walk(
            prefix: [.open, .play, .pull(.ready)],
            alphabet: [.play, .pause, .seek(0.3), .seek(0.31), .rate(2.0), .looping(true), .wait(3), .apply, .park, .pull(.frame), .pull(.atSeek), .pull(.end), .pull(.stopped)],
            depth: 6
        )
    }

    @Test("a_loading_player_times_out_like_the_old_flags")
    func aLoadingPlayerTimesOutLikeTheOldFlags() {
        H.walk(
            prefix: [.play, .done(.facts), .pull(.loading)],
            alphabet: [.seek(0.3), .muted(false), .pause, .wait(31), .wait(3), .apply, .pull(.loading), .pull(.ready), .park],
            depth: 5
        )
    }

    @Test("the_newest_seek_replaces_an_earlier_one")
    func theNewestSeekReplacesAnEarlierOne() {
        let now = 100.0
        var s = VideoPhases.Settle()
        s.seek(to: 3.0, sameFrame: false, now: now)
        #expect(s.isWaiting)
        s.seek(to: 0.5, sameFrame: true, now: now)
        #expect(!s.isWaiting && s.isPending)
        s.observe(current: 0.5, playing: false, isAudio: false)
        #expect(s.isStill)
    }

    @Test("a_seek_lands_with_a_frame_or_for_audio_at_its_position")
    func aSeekLandsWithAFrameOrForAudioAtItsPosition() {
        let now = 100.0
        var video = VideoPhases.Settle()
        video.seek(to: 2.0, sameFrame: false, now: now)
        video.observe(current: 2.0, playing: false, isAudio: false)
        #expect(video.isWaiting)
        video.framed()
        #expect(video.isStill)

        var audio = VideoPhases.Settle()
        audio.seek(to: 2.0, sameFrame: false, now: now)
        audio.observe(current: 1.0, playing: true, isAudio: true)
        #expect(audio.isWaiting)
        audio.observe(current: 2.1, playing: true, isAudio: true)
        #expect(audio.isStill)
    }

    @Test("a_hold_ends_when_playback_moves_on_and_a_frame_does_not_end_it")
    func aHoldEndsWhenPlaybackMovesOnAndAFrameDoesNotEndIt() {
        let now = 100.0
        var s = VideoPhases.Settle()
        s.seek(to: 0.5, sameFrame: true, now: now)
        s.framed()
        #expect(s.isHolding && !s.isWaiting && s.time == 0.5)
        s.observe(current: 0.4, playing: true, isAudio: false)
        #expect(s.isStill)
    }

    @Test("a_seek_that_never_lands_expires")
    func aSeekThatNeverLandsExpires() {
        let now = 100.0
        var s = VideoPhases.Settle()
        s.seek(to: 2.0, sameFrame: false, now: now)
        s.expire(now: now + VideoPhases.seekPatienceSeconds)
        #expect(s.isWaiting)
        s.expire(now: now + VideoPhases.seekPatienceSeconds + 0.001)
        #expect(s.isStill)
        s.seek(to: 1.0, sameFrame: true, now: now)
        s.expire(now: now + 60.0)
        #expect(s.isHolding && !s.isWaiting && s.time == 1.0)
    }
}

// MARK: - 3. Video Runtime Extended Parity Tests (`video/tests.rs`, 16 tests)

@Suite("Video Runtime Extended Parity Tests", .serialized)
struct VideoRuntimeExtendedParityTests {
    private static func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
    }

    private final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func inc() { lock.lock(); count += 1; lock.unlock() }
        func get() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    @Test("a_waker_set_after_a_failure_hears_it_once")
    func aWakerSetAfterAFailureHearsItOnce() {
        MediaPlaybackGate.setEnabled(false)
        let a = Player.url("tap.ogv")
        #expect(a.snapshot().state.isFailed)
        let calls = AtomicCounter()
        a.setWaker { calls.inc() }
        a.settleStateWaker()
        a.play()
        #expect(calls.get() == 1)
    }

    @Test("a_clip_dropped_during_a_parking_pass_is_destroyed_outside_the_lock")
    func aClipDroppedDuringAParkingPassIsDestroyedOutsideTheLock() {
        Player.resetParkedForTest()
        defer { Player.resetParkedForTest() }

        final class FlagBox: @unchecked Sendable {
            private let lock = NSLock()
            var value: Bool? = nil
            func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
            func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return value }
        }
        final class Probe: @unchecked Sendable {
            let box: FlagBox
            init(_ box: FlagBox) { self.box = box }
            deinit {
                box.set(Player.parkedLockFreeForTest())
            }
        }

        final class PlayerHolder: @unchecked Sendable {
            var player: Player?
            init(_ p: Player) { self.player = p }
        }
        let box = FlagBox()
        let holder = PlayerHolder(Player.audio("missing-park-drop.m4a"))
        ({
            let probe = Probe(box)
            holder.player!.setWaker {
                _ = probe
            }
        })()
        let other = Player.audio("missing-park-other.m4a")

        #expect(Player.parkedWithForTest(holder.player!).isEmpty)
        Player.onKeptForTest {
            holder.player = nil
        }
        #expect(Player.parkedWithForTest(other).isEmpty)
        #expect(box.get() == true)
    }

    @Test("a_warm_parking_pass_keeps_its_buffers_capacity")
    func aWarmParkingPassKeepsItsBuffersCapacity() {
        Player.resetParkedForTest()
        defer { Player.resetParkedForTest() }

        let url = Self.fixtureURL("rgbw.mp4")
        let clips = (0..<4).map { _ in Player(source: .file(url)) }
        for _ in 0..<5 {
            for clip in clips {
                #expect(Player.parkedWithForTest(clip).isEmpty)
            }
        }
        let warm = Player.heldCapacityForTest()
        #expect(warm >= clips.count)
        for _ in 0..<100 {
            for clip in clips {
                #expect(Player.parkedWithForTest(clip).isEmpty)
            }
        }
        #expect(Player.heldCapacityForTest() == warm)
    }

    @Test("playing_after_the_end_restarts_from_zero")
    func playingAfterTheEndRestartsFromZero() {
        MediaPlaybackGate.setEnabled(false)
        let v = Player.file("missing-restart.mp4")
        v.openMetadataForTest(VideoMeta(kind: .video, duration: 1.0, size: (64, 36), hasSound: false, frameDuration: 0.25))
        v.setEndedForTest(at: 1.0)
        #expect(v.state == .ended)
        v.play()
        #expect(v.time == 0.0)
        #expect(v.isPlaying == true)
    }

    @Test("display_positions_loop_or_end")
    func displayPositionsLoopOrEnd() {
        var m = VideoPhases.Machine(isAudio: false, playing: false, looping: false, muted: true, volume: 1.0, rate: 1.0)
        m.duration = 1.0
        _ = m.apply(.play, at: 0.0)
        #expect(m.observe(time: 0.4, atEnd: false) == false)
        #expect(m.time == 0.4)
        m.looping = true
        #expect(m.observe(time: 1.0, atEnd: true) == true)
        #expect(m.time == 0.0 && m.playing == true)
        m.looping = false
        #expect(m.observe(time: 1.2, atEnd: true) == false)
        #expect(m.time == 1.0 && m.playing == false && m.ended == true)
    }

    @Test("frames_snap_to_whole_frames_inside_the_clip")
    func framesSnapToWholeFramesInsideTheClip() {
        let m = VideoMeta(kind: .video, duration: 1.0, size: (64, 36), hasSound: false, frameDuration: 0.25)
        #expect(m.frameCount == 4)
        #expect(m.frameIndex(at: 0.0) == 0)
        #expect(m.frameIndex(at: 0.2499) == 0)
        #expect(m.frameIndex(at: 0.25) == 1)
        #expect(m.frameIndex(at: 1.0) == 3)
        #expect(m.frameIndex(at: -1.0) == 0)
        #expect(m.frameTime(for: 1) == 0.375)
        #expect(m.frameTime(for: 3) == 0.875)
    }

    @Test("the_last_handle_or_element_frees_the_player")
    func theLastHandleOrElementFreesThePlayer() {
        final class WeakToken {
            weak var value: AnyObject?
            init(_ value: AnyObject?) { self.value = value }
        }
        var v: Player? = Player.file("missing-free.mp4")
        let weakShared = WeakToken(v?.sharedTokenForTest)
        var inTree: NativeSurface? = v?.surface
        #expect(inTree != nil)
        v = nil
        #expect(weakShared.value != nil)
        inTree = nil
        #expect(weakShared.value == nil)
    }

    @Test("headless_audio_opens_on_read_and_holds_time")
    func headlessAudioOpensOnReadAndHoldsTime() throws {
        MediaPlaybackGate.setEnabled(false)
        let a = Player.audio(Self.fixtureURL("silence.m4a").path)
        a.setMuted(true)
        #expect(a.state == .ready)
        let d = try #require(a.duration)
        #expect(abs(d - 1.0) < 0.1)
        #expect(a.size == nil)
        a.play()
        #expect(a.state == .playing)
        #expect(a.time == 0.0)
        a.seek(to: 0.4)
        #expect(a.time == 0.4)

        let wav = Player.audio(Self.fixtureURL("silence.wav").path)
        let wavDur = try #require(wav.duration)
        #expect(abs(wavDur - 0.5) < 0.01)

        let video = Player.audio(Self.fixtureURL("rgbw.mp4").path)
        if case .failed(let msg) = video.state {
            #expect(msg.contains("no playable audio track"))
        } else {
            Issue.record("expected rgbw.mp4 opened as audio to fail, got \(video.state)")
        }
    }

    private static func scrolledVideoView(_ v: Player, _: inout Cx<Player>) -> El<Player> {
        col().key("list").size(32, 18).scroll(stickBottom: false).child(
            col().wFull()
                .child(el().key("clip").size(32, 18).video(v, .fit))
                .child(el().wFull().h(200))
        )
    }

    @Test("a_playing_clip_scrolling_across_the_clip_edge_commits_nothing")
    func aPlayingClipScrollingAcrossTheClipEdgeCommitsNothing() throws {
        MediaPlaybackGate.setEnabled(false)
        let v = Player(source: .file(Self.fixtureURL("rgbw.mp4")), playing: false, looping: true)
        v.setLooping(true)

        let rt = Runtime<Player>(
            state: v,
            viewport: Vec2(32, 18),
            pixelScale: 2.0,
            view: Self.scrolledVideoView
        )
        v.play()

        #if canImport(Metal)
        let renderer = try MetalRenderer()
        func centerRGB(_ scene: RefScene) throws -> (UInt8, UInt8, UInt8) {
            let out = try renderer.renderOffscreen(scene, surfaces: rt.surfaces)
            let i = (18 * 64 + 32) * 4
            return (out.rgba[i], out.rgba[i + 1], out.rgba[i + 2])
        }
        func near(_ got: (UInt8, UInt8, UInt8), _ want: (UInt8, UInt8, UInt8)) -> Bool {
            abs(Int(got.0) - Int(want.0)) <= 24 &&
            abs(Int(got.1) - Int(want.1)) <= 24 &&
            abs(Int(got.2) - Int(want.2)) <= 24
        }

        _ = rt.frame(at: 0.0)
        let s1 = rt.frame(at: 0.1)
        #expect(near(try centerRGB(s1), (255, 0, 0)))

        let steadyCommits = rt.viewCommitCount
        _ = rt.frame(at: 0.15)
        #expect(rt.viewCommitCount == steadyCommits)

        rt.wheel(WheelEvent(dx: 0, dy: -40), at: Vec2(10, 10), now: 0.15)
        _ = rt.frame(at: 0.2)
        #expect(rt.surfaces.isEmpty)

        _ = rt.frame(at: 0.6)
        rt.wheel(WheelEvent(dx: 0, dy: 40), at: Vec2(10, 10), now: 0.6)
        let sBack = rt.frame(at: 0.6)
        #expect(rt.surfaces.count == 1)
        #expect(near(try centerRGB(sBack), (0, 0, 255)))
        #expect(v.state == .playing)
        #else
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.1)
        rt.wheel(WheelEvent(dx: 0, dy: -40), at: Vec2(10, 10), now: 0.1)
        _ = rt.frame(at: 0.2)
        #expect(rt.surfaces.isEmpty)
        _ = rt.frame(at: 0.6)
        rt.wheel(WheelEvent(dx: 0, dy: 40), at: Vec2(10, 10), now: 0.6)
        _ = rt.frame(at: 0.6)
        #expect(rt.surfaces.count == 1)
        #expect(v.state == .playing)
        #endif
    }

    @Test("a_failed_clip_scrolling_across_the_clip_edge_commits_nothing")
    func aFailedClipScrollingAcrossTheClipEdgeCommitsNothing() {
        MediaPlaybackGate.setEnabled(false)
        let v = Player.file("/nonexistent/clip.mp4")
        let deadline = Date().addingTimeInterval(0.5)
        while !v.state.isFailed && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        #expect(v.state.isFailed)

        let rt = Runtime<Player>(
            state: v,
            viewport: Vec2(32, 18),
            pixelScale: 2.0,
            view: Self.scrolledVideoView
        )
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.1)
        #expect(v.state.isFailed)

        var now = 0.1
        for dy: Float in [-40.0, 40.0, -40.0, 40.0] {
            let shown = rt.surfaces.count
            now += 0.1
            rt.wheel(WheelEvent(dx: 0, dy: dy), at: Vec2(10, 10), now: now)
            _ = rt.frame(at: now)
            #expect(rt.surfaces.count != shown)
            let afterEdgeCommits = rt.viewCommitCount
            _ = rt.frame(at: now + 0.05)
            #expect(rt.viewCommitCount == afterEdgeCommits)
        }
    }

    @Test("requests_carry_headers_without_printing_their_values")
    func requestsCarryHeadersWithoutPrintingTheirValues() {
        let request = Player.request("https://example.com/media/a.m4a")
            .header("Authorization", "Bearer secret-token")
            .header("authorization", "Bearer newer-token")
            .header("X-Board", "1")
        let printed = "\(request) \(String(reflecting: request))"
        #expect(printed.contains("authorization") || printed.contains("Authorization"))
        #expect(!printed.contains("token"))

        let a = request.audio()
        #expect(a.isAudio)
        let playerPrinted = "\(a) \(String(reflecting: a))"
        #expect(!playerPrinted.contains("token"))

        let v = Player.request("https://example.com/media/a.mp4")
            .header("Authorization", "Bearer t")
            .video()
        #expect(!v.isAudio && v.isMuted)
    }

    private final class AuthRangeHTTPServer: @unchecked Sendable {
        private let listenFD: Int32
        private let body: Data
        private let contentType: String
        private let refusedCounter = AtomicCounter()
        private let stopLock = NSLock()
        private var stopped = false
        let baseURL: String

        init(body: Data, contentType: String) throws {
            self.body = body
            self.contentType = contentType
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, Darwin.listen(fd, 16) == 0 else {
                Darwin.close(fd)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }

            var boundAddr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &boundAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.getsockname(fd, $0, &len)
                }
            }
            let port = UInt16(bigEndian: boundAddr.sin_port)
            self.listenFD = fd
            self.baseURL = "http://127.0.0.1:\(port)/media/clip"

            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.acceptLoop()
            }
        }

        var refusedCount: Int { refusedCounter.get() }

        func stop() {
            stopLock.lock()
            let already = stopped
            stopped = true
            stopLock.unlock()
            if !already {
                Darwin.shutdown(listenFD, SHUT_RDWR)
                Darwin.close(listenFD)
            }
        }

        private func isStopped() -> Bool {
            stopLock.lock()
            defer { stopLock.unlock() }
            return stopped
        }

        private func acceptLoop() {
            while !isStopped() {
                var clientAddr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let client = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(listenFD, $0, &addrLen)
                    }
                }
                if client < 0 { break }
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.handleClient(client)
                }
            }
        }

        private func handleClient(_ fd: Int32) {
            defer { Darwin.close(fd) }
            var buffer = Data()
            var tmp = [UInt8](repeating: 0, count: 4096)
            let separator = Data("\r\n\r\n".utf8)

            while !isStopped() {
                while buffer.range(of: separator) == nil {
                    let n = Darwin.recv(fd, &tmp, tmp.count, 0)
                    if n <= 0 { return }
                    buffer.append(tmp, count: n)
                }
                guard let endRange = buffer.range(of: separator) else { return }
                let headData = buffer.subdata(in: 0..<endRange.lowerBound)
                buffer.removeSubrange(0..<endRange.upperBound)

                let headText = String(decoding: headData, as: UTF8.self)
                let lines = headText.components(separatedBy: "\r\n")
                var authorized = false
                var rangeHeader: String? = nil
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                    let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if name == "authorization" {
                        authorized = (val == "Bearer let-me-in")
                    } else if name == "range" {
                        rangeHeader = val
                    }
                }

                if !authorized {
                    refusedCounter.inc()
                    let resp = Data("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n".utf8)
                    if !writeAll(fd, data: resp) { return }
                    continue
                }

                let total = body.count
                var start = 0
                var end = max(0, total - 1)
                if let r = rangeHeader, r.lowercased().hasPrefix("bytes=") {
                    let spec = String(r.dropFirst("bytes=".count))
                    let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                    if parts.count == 2, let a = Int(parts[0]) {
                        let b = Int(parts[1]).map { min($0, total - 1) } ?? (total - 1)
                        start = max(0, min(a, total - 1))
                        end = max(start, b)
                    }
                }
                let sliceLen = end + 1 - start
                let headerStr = "HTTP/1.1 206 Partial Content\r\nContent-Type: \(contentType)\r\nAccept-Ranges: bytes\r\nContent-Range: bytes \(start)-\(end)/\(total)\r\nContent-Length: \(sliceLen)\r\n\r\n"
                if !writeAll(fd, data: Data(headerStr.utf8)) { return }
                if !writeAll(fd, data: body.subdata(in: start..<(end + 1))) { return }
            }
        }

        private func writeAll(_ fd: Int32, data: Data) -> Bool {
            data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return true }
                var sent = 0
                while sent < data.count {
                    let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                    if n <= 0 { return false }
                    sent += n
                }
                return true
            }
        }
    }

    @Test("headless_audio_opens_with_request_headers")
    func headlessAudioOpensWithRequestHeaders() throws {
        MediaPlaybackGate.setEnabled(false)
        let wavData = try Data(contentsOf: Self.fixtureURL("silence.wav"))
        let server = try AuthRangeHTTPServer(body: wavData, contentType: "audio/wav")
        defer { server.stop() }

        let a = Player.request("\(server.baseURL).wav")
            .header("Authorization", "Bearer let-me-in")
            .audio()
        #expect(a.state == .ready)
        let dur = try #require(a.duration)
        #expect(abs(dur - 0.5) < 0.01)
        #expect(server.refusedCount == 0)

        let without = Player.audio("\(server.baseURL)-2.wav")
        #expect(without.state.isFailed)
        #expect(server.refusedCount > 0)
    }

    @Test("headless_audio_time_follows_the_virtual_clock")
    func headlessAudioTimeFollowsTheVirtualClock() {
        MediaPlaybackGate.setEnabled(false)
        struct S {}
        let a = Player.audio(Self.fixtureURL("silence.wav").path)
        let ends = AtomicCounter()
        a.setWaker {
            if a.state == .ended {
                ends.inc()
            }
        }
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(10, 10),
            pixelScale: 2.0,
            view: { _, _ in el().size(10, 10) }
        )
        func near(_ t: Double, _ want: Double) -> Bool {
            abs(t - want) < 1e-6
        }

        a.play()
        _ = rt.frame(at: 0.0)
        _ = rt.frame(at: 0.1)
        #expect(near(a.time, 0.1))
        #expect(a.state == .playing)

        a.pause()
        _ = rt.frame(at: 0.3)
        #expect(near(a.time, 0.1))

        a.setRate(2.0)
        a.play()
        _ = rt.frame(at: 0.35)
        #expect(near(a.time, 0.2))

        a.seek(to: 0.05)
        #expect(near(a.time, 0.05))

        _ = rt.frame(at: 0.45)
        #expect(near(a.time, 0.25))
        #expect(ends.get() == 0)

        _ = rt.frame(at: 0.95)
        #expect(a.state == .ended)
        #expect(near(a.time, 0.5))
        #expect(ends.get() == 1)

        a.setLooping(true)
        a.setRate(1.0)
        a.play()
        _ = rt.frame(at: 1.55)
        #expect(near(a.time, 0.1))
        #expect(a.isPlaying)
    }

    @Test("headless audio and drawn video follow the clock of the runtime driving them")
    func headlessMediaIgnoresFramesOnAnotherThread() {
        let audio = Player.audio(Self.fixtureURL("silence.wav").path)
        let video = Player(source: .file(Self.fixtureURL("rgbw.mp4")))
        let rt = Runtime(state: video, viewport: Vec2(32, 18), view: Self.scrolledVideoView)
        audio.play()
        video.play()
        _ = rt.frame(at: 0)
        _ = rt.frame(at: 0.1)

        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let other = Runtime(state: (), viewport: Vec2(10, 10), view: { _, _ in el() })
            _ = other.frame(at: 5)
            finished.signal()
        }
        finished.wait()

        #expect(abs(audio.time - 0.1) < 1e-6)
        #expect(abs(video.time - 0.1) < 1e-6)
        #expect(abs(VideoHeadless.virtualClock - 0.1) < 1e-6)
        _ = rt.frame(at: 0.2)
        #expect(abs(audio.time - 0.2) < 1e-6)
        #expect(abs(video.time - 0.2) < 1e-6)
    }

    @Test("a_replaced_waker_is_dropped_outside_the_slots_lock")
    func aReplacedWakerIsDroppedOutsideTheSlotsLock() {
        final class FlagBox: @unchecked Sendable {
            private let lock = NSLock()
            var freed: Bool? = nil
            func set(_ v: Bool) { lock.lock(); freed = v; lock.unlock() }
            func get() -> Bool? { lock.lock(); defer { lock.unlock() }; return freed }
        }
        final class Probe: @unchecked Sendable {
            let slot: WakerSlot
            let box: FlagBox
            init(_ slot: WakerSlot, _ box: FlagBox) {
                self.slot = slot
                self.box = box
            }
            deinit {
                box.set(slot.isLockFreeForTest)
            }
        }

        let box = FlagBox()
        let slot = WakerSlot()
        ({
            let first = Probe(slot, box)
            slot.set {
                _ = first
            }
        })()
        slot.set {}
        #expect(box.get() == true)
    }

    @Test("a_new_runtime_starts_the_headless_clock_again")
    func aNewRuntimeStartsTheHeadlessClockAgain() {
        MediaPlaybackGate.setEnabled(false)
        struct S {}
        var old: Runtime<S>? = Runtime<S>(
            state: S(),
            viewport: Vec2(10, 10),
            pixelScale: 2.0,
            view: { _, _ in el().size(10, 10) }
        )
        _ = old?.frame(at: 5.0)
        old = nil

        let a = Player.audio(Self.fixtureURL("silence.wav").path)
        let rt = Runtime<S>(
            state: S(),
            viewport: Vec2(10, 10),
            pixelScale: 2.0,
            view: { _, _ in el().size(10, 10) }
        )
        a.play()
        _ = rt.frame(at: 0.1)
        #expect(abs(a.time - 0.1) < 1e-6)
    }

    @Test("preload_decodes_the_first_frame_before_anything_draws_it")
    func preloadDecodesTheFirstFrameBeforeAnythingDrawsIt() {
        MediaPlaybackGate.setEnabled(false)
        let v = Player(source: .file(Self.fixtureURL("rgbw.mp4")))
        v.clearSurfaceForPreloadTest()
        #expect(v.surface.currentFrame() == nil)

        v.preloadPosterDirectForTest()
        let deadline = Date().addingTimeInterval(10.0)
        while v.surface.currentFrame() == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(v.surface.currentFrame() != nil)

        v.preload()
        let audio = Player.audio(Self.fixtureURL("silence.wav").path)
        audio.preloadPosterDirectForTest()
        Thread.sleep(forTimeInterval: 0.05)
        #expect(audio.surface.currentFrame() == nil)
    }
}
