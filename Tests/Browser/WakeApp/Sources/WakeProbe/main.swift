import Foundation
import Rune

private struct State {
    var phase = 0
    var due: Double?
    var moved = false
}

private final class Inbox: @unchecked Sendable {
    // The WASI reactor and its Swift executor run these turns on one browser thread.
    var waker: Waker?
    var ready = false
}

private let inbox = Inbox()
private let app = App(title: "Browser wakes", size: Vec2(96, 48), state: State()) { state, _ in
    let colors: [Color] = [.rgba8(8, 8, 8), .rgba8(80, 0, 0), .rgba8(0, 90, 0),
                           .rgba8(0, 0, 120), .rgba8(160, 0, 160), .rgba8(0, 90, 110), .rgba8(80, 100, 0),
                           .rgba8(64, 80, 120), .rgba8(120, 80, 0)]
    return row().sizeFull().bg(colors[state.phase]).child(
        el().key("moving").size(8, 8).offset(state.moved ? 60 : 0, 0)
            .offsetMotion(MotionTokens.REFLOW).bg(.rgba8(230, 230, 230)))
}

private let handle = app.handle()
private let probe = app
    .setup { inbox.waker = $0 }
    .poll { state, now, tx in
        if state.phase == 1 && state.due == nil {
            state.due = now + 0.25
            tx.wakeAfter(0.25)
        }
        if let due = state.due, now >= due {
            state.phase = 2
            state.due = nil
            tx.instant()
            return true
        }
        if inbox.ready {
            inbox.ready = false
            state.phase = 4
            tx.instant()
            return true
        }
        return false
    }
    .onKey { state, event, tx in
        switch event.key {
        case .text("t"):
            state.phase = 1
            tx.instant()
            return true
        case .text("f"):
            state.phase = 3
            tx.instant()
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                inbox.ready = true
                inbox.waker?.wake()
            }
            return true
        case .text("h"):
            state.phase = 5
            tx.instant()
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                handle.update { state, tx in state.phase = 6; tx.instant() }
            }
            return true
        case .text("a"):
            state.moved.toggle()
            tx.animated()
            return true
        case .text("i"):
            Task {
                let pool = ImageDecodePool()
                guard let url = URL(string: "/Tests/Browser/ImageApp/remote.webp"),
                      let image = try? await pool.loadURL(url, maxDimension: 2),
                      image.width == 2 else { return }
                handle.update { state, tx in state.phase = 7; tx.instant() }
            }
            return true
        default: return false
        }
    }

#if os(WASI)
private let directCache = ImageCache(wake: {
    handle.update { state, tx in
        state.phase = 8
        tx.instant()
    }
})

/// A JavaScript callback can enter an idle Swift app between input and display callbacks.
@MainActor @_cdecl("rune_probe_late_image")
func loadImageFromJavaScript() {
    _ = directCache.url("/Tests/Browser/ImageApp/remote.webp?from=callback", sizePt: 2, scale: 1)
}
#endif

try RuneApp.run(probe)
