#if canImport(AVFoundation) && canImport(CoreGraphics)
import AVFoundation
import CoreGraphics
#endif
import Foundation
import Rune

/// Port of `examples/video-player`: movie & audio player with keyboard transport controls and 4-frame RGBW fallback.
enum PlayerStatus: Equatable {
    case loading
    case playing
    case ready
    case ended
    case failed(String)

    var label: String {
        switch self {
        case .loading: return "Loading"
        case .playing: return "Playing, tap to pause"
        case .ready: return "Paused, tap to play"
        case .ended: return "Ended, tap to replay"
        case .failed(let msg): return msg
        }
    }
}

struct VideoPlayerState {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg"]
    static let width: Float = 480.0

    var sourcePath: String? = nil
    var isAudio: Bool = false
    var status: PlayerStatus = .playing
    var muted: Bool = true
    var volume: Float = 1.0
    var looping: Bool = true
    var hidden: Bool = false
    var time: Double = 0.0
    var duration: Double = 2.0
    var naturalSize: (Int, Int) = (480, 270)
    var currentFrame: RGBA8Atlas? = nil

    static func initial() -> VideoPlayerState {
        let extra = CommandLine.arguments.dropFirst().first { arg in
            !arg.hasPrefix("--") && arg != CommandLine.arguments.first
        }
        var state = VideoPlayerState()
        if let path = extra, FileManager.default.fileExists(atPath: path) {
            state.sourcePath = path
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            state.isAudio = audioExtensions.contains(ext)
            if state.isAudio {
                state.status = .ready
                state.muted = false
            } else {
                state.loadVideoFrame(at: 0.0)
            }
        } else {
            state.currentFrame = makeRGBWFrame(at: 0.0)
        }
        return state
    }

    static func makeRGBWFrame(at time: Double) -> RGBA8Atlas {
        let w = 480
        let h = 270
        let idx = Int((time * 2.0).rounded(.down)) % 4
        let palette: [(UInt8, UInt8, UInt8)] = [
            (220, 48, 48),   // Red
            (48, 200, 96),   // Green
            (56, 128, 240),  // Blue
            (236, 236, 240), // White
        ]
        let color = palette[max(0, idx)]
        var texels = [UInt8](repeating: 255, count: w * h * 4)
        for p in 0..<(w * h) {
            let off = p * 4
            texels[off] = color.0
            texels[off + 1] = color.1
            texels[off + 2] = color.2
            texels[off + 3] = 255
        }
        return RGBA8Atlas(width: w, height: h, texels: texels)
    }

    mutating func loadVideoFrame(at t: Double) {
        guard let path = sourcePath, !isAudio else {
            currentFrame = Self.makeRGBWFrame(at: t)
            return
        }
        #if canImport(AVFoundation) && canImport(CoreGraphics)
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 480, height: 480)
        let cmTime = CMTime(seconds: max(0, t), preferredTimescale: 600)
        if let cgImage = try? gen.copyCGImage(at: cmTime, actualTime: nil) {
            let w = cgImage.width
            let h = cgImage.height
            naturalSize = (w, h)
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let cs = CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(
                data: &bytes,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
                currentFrame = RGBA8Atlas(width: w, height: h, texels: bytes)
                return
            }
        }
        #else
        _ = path
        #endif
        currentFrame = Self.makeRGBWFrame(at: t)
    }

    mutating func togglePlay() {
        if status == .playing {
            status = .ready
        } else {
            if status == .ended { time = 0.0 }
            status = .playing
        }
    }

    mutating func seek(to newTime: Double) {
        let clamped = max(0.0, min(newTime, duration))
        time = clamped
        if !isAudio {
            loadVideoFrame(at: clamped)
        }
    }
}

func videoPlayerView(_ s: VideoPlayerState, _ cx: inout Cx<VideoPlayerState>) -> El<VideoPlayerState> {
    let t = Tok.theme(dark: true)
    let media: El<VideoPlayerState>
    if s.isAudio {
        let progress = s.duration > 0 ? Float((s.time / s.duration).clamped(to: 0...1)) : 0
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
        let w = Float(s.naturalSize.0)
        let h = Float(s.naturalSize.1)
        let viewH = VideoPlayerState.width * h / max(1, w)
        var frame: El<VideoPlayerState> = el()
            .key("video")
            .w(VideoPlayerState.width)
            .h(viewH)
            .rounded(10)
            .clip(true)
            .bg(t.card)
        if !s.hidden, let atlas = s.currentFrame {
            frame = frame.child(image(atlas).size(VideoPlayerState.width, viewH))
        }
        media = frame
    }

    return col()
        .sizeFull()
        .center()
        .gap(12)
        .bg(t.bg)
        .onClick { state in state.togglePlay() }
        .child(media)
        .child(text(s.status.label).size(13).color(t.textSecondary))
}

let spec = AppSpec<VideoPlayerState>(
    title: "Video player",
    size: Vec2(520, 340),
    dark: true,
    state: VideoPlayerState.initial(),
    onKey: { state, event, _ in
        switch event.key {
        case .space:
            state.togglePlay()
            return true
        case .text("m"), .text("M"):
            state.muted.toggle()
            return true
        case .text("v"), .text("V"):
            state.volume = state.volume > 0 ? 0 : 1
            return true
        case .text("l"), .text("L"):
            state.looping.toggle()
            return true
        case .text("0"):
            state.seek(to: 0.0)
            return true
        case .text("h"), .text("H"):
            state.hidden.toggle()
            return true
        case .arrowLeft:
            state.seek(to: state.time - 5.0)
            return true
        case .arrowRight:
            state.seek(to: state.time + 5.0)
            return true
        default:
            return false
        }
    },
    view: videoPlayerView
)
.scene("playing") {
    $0.isAudio = false
    $0.hidden = false
    $0.status = .playing
    $0.seek(to: 0.6)
}
.scene("paused") {
    $0.isAudio = false
    $0.hidden = false
    $0.status = .ready
    $0.seek(to: 1.1)
}
.scene("audio") {
    $0.isAudio = true
    $0.status = .playing
    $0.time = 0.85
    $0.duration = 2.0
}
.scene("hidden") {
    $0.isAudio = false
    $0.hidden = true
    $0.status = .ready
}
.scene("ended") {
    $0.isAudio = false
    $0.hidden = false
    $0.status = .ended
    $0.seek(to: 1.6)
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

try RuneApp.run(spec)
