import Foundation
import Rune
import RuneKit

public struct VideoPlayerState: @unchecked Sendable {
    public static let width: Float = 440

    public var clip: Player
    public var hidden: Bool = false

    public init(clip: Player, hidden: Bool = false) {
        self.clip = clip
        self.hidden = hidden
    }
}

public enum VideoSource: Sendable, Equatable {
    case file(String)
    case url(String)
}

@main
public enum RuneVideoPlayerApp {
    public static func defaultVideoPath() -> String {
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RuneVideoPlayer
            .deletingLastPathComponent() // Examples
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Tests/RuneTests/Fixtures/rgbw.mp4")
            .path
        if FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Tests/RuneTests/Fixtures/rgbw.mp4")
            .path
    }

    public static func parseOptions(
        arguments: [String],
        overrideSource: VideoSource? = nil
    ) -> (audio: Bool, source: VideoSource) {
        let (_, extra) = ToolingProcessArgs.parseSplit(arguments)
        var audio = false
        var url: String? = nil
        var path: String? = nil

        var i = 0
        while i < extra.count {
            let arg = extra[i]
            if arg == "--audio" {
                audio = true
            } else if arg == "--url", i + 1 < extra.count {
                url = extra[i + 1]
                i += 1
            } else if arg.hasPrefix("--url=") {
                url = String(arg.dropFirst("--url=".count))
            } else if !arg.hasPrefix("-"), path == nil {
                path = arg
            }
            i += 1
        }

        let resolvedSource: VideoSource
        if let overrideSource {
            resolvedSource = overrideSource
        } else if let url {
            resolvedSource = .url(url)
        } else {
            resolvedSource = .file(path ?? defaultVideoPath())
        }
        return (audio, resolvedSource)
    }

    public static func makePlayer(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        overrideSource: VideoSource? = nil
    ) -> Player {
        let (audio, source) = parseOptions(arguments: arguments, overrideSource: overrideSource)
        if audio {
            let target: String
            switch source {
            case .file(let p): target = p
            case .url(let u): target = u
            }
            return Player.audio(target, playing: false, looping: false, muted: false, volume: 1.0, rate: 1.0)
        }
        switch source {
        case .file(let p):
            return Player.file(p, playing: true, looping: true, muted: true, volume: 1.0, rate: 1.0)
        case .url(let u):
            return Player.url(u, playing: true, looping: true, muted: true, volume: 1.0, rate: 1.0)
        }
    }

    public static func statusLabel(for state: PlayerState) -> String {
        switch state {
        case .loading:
            return "Loading..."
        case .ready:
            return "Paused"
        case .playing:
            return "Playing"
        case .ended:
            return "Ended"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    public static func videoPlayerView(_ s: VideoPlayerState, _ cx: inout Cx<VideoPlayerState>) -> El<VideoPlayerState> {
        let t = Tok.theme(dark: true)
        let media: El<VideoPlayerState>
        if s.clip.isAudio {
            let progress: Float
            if let duration = s.clip.duration, duration > 0 {
                progress = Float(max(0.0, min(1.0, s.clip.time / duration)))
            } else {
                progress = 0
            }
            media = row()
                .key("progress")
                .w(VideoPlayerState.width)
                .h(4)
                .rounded(2)
                .bg(t.controlOff)
                .child(
                    el()
                        .w(VideoPlayerState.width * progress)
                        .h(4)
                        .rounded(2)
                        .bg(Tok.accent(0, dark: true))
                )
        } else {
            let (natW, natH) = s.clip.size ?? (16, 9)
            let viewH = VideoPlayerState.width * Float(natH) / Float(max(1, natW))
            var frame: El<VideoPlayerState> = el()
                .key("video")
                .w(VideoPlayerState.width)
                .h(viewH)
                .rounded(10)
                .clip(true)
                .bg(t.card)
            if !s.hidden {
                let videoLayer: El<VideoPlayerState> = el().video(s.clip, .fit).sizeFull()
                frame = frame.child(videoLayer)
            }
            media = frame
        }

        return col()
            .sizeFull()
            .center()
            .gap(12)
            .bg(t.bg)
            .onClick { state in
                state.clip.toggle()
            }
            .child(media)
            .child(text(statusLabel(for: s.clip.state)).size(13).color(t.textSecondary))
    }

    public static func makeSpec(
        arguments: [String] = Array(CommandLine.arguments.dropFirst()),
        overrideSource: VideoSource? = nil
    ) -> AppSpec<VideoPlayerState> {
        let clip = makePlayer(arguments: arguments, overrideSource: overrideSource)
        return AppSpec<VideoPlayerState>(
            title: "Video player",
            size: Vec2(520, 340),
            dark: true,
            state: VideoPlayerState(clip: clip),
            setup: { waker in
                clip.setWaker { waker.wake() }
            },
            poll: { state, _, tx in
                if state.clip.isAudio && state.clip.isPlaying {
                    tx.wakeAfter(0.033)
                    return true
                }
                return false
            },
            onKey: { state, event, _ in
                switch event.key {
                case .space, .text(" "):
                    state.clip.toggle()
                    return true
                case .text("m"), .text("M"):
                    state.clip.setMuted(!state.clip.isMuted)
                    return true
                case .text("v"), .text("V"):
                    state.clip.setVolume(state.clip.volume > 0 ? 0.0 : 1.0)
                    return true
                case .text("l"), .text("L"):
                    state.clip.setLooping(!state.clip.isLooping)
                    return true
                case .text("0"):
                    state.clip.seek(to: 0.0)
                    return true
                case .text("h"), .text("H"):
                    state.hidden.toggle()
                    return true
                case .arrowLeft:
                    state.clip.seek(to: max(0.0, state.clip.time - 5.0))
                    return true
                case .arrowRight:
                    state.clip.seek(to: state.clip.time + 5.0)
                    return true
                default:
                    return false
                }
            },
            view: videoPlayerView
        )
        .scene("playing") { state in
            state.hidden = false
            state.clip.play()
        }
        .scene("paused") { state in
            state.hidden = false
            state.clip.pause()
        }
        .scene("hidden") { state in
            state.hidden = true
            state.clip.pause()
        }
    }

    @MainActor
    public static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        try RuneApp.run(makeSpec(arguments: args), arguments: args)
    }
}
