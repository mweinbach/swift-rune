import Foundation
import Rune

@main
struct FloatAppProbe {
    static func main() {
        let floating = ProcessInfo.processInfo.environment["RUNE_TEST_FLOAT_IPC"] != "tiled"
        let app = App<Int>(title: "Rune float-on-open", size: Vec2(250, 140), state: 0) { _, _ in
            el().sizeFull().bg(Color(r: 0, g: 0.75, b: 0.4))
        }.windowOptions(WindowOptions(
            minSize: Vec2(80, 50), maxSize: Vec2(400, 300), hasShadow: false,
            borderless: true, physicalSize: (200, 120)
        )).floatOnOpen(floating)
        let handle = app.handle()
        RuneApp.runOrExit(app.onReady { _ in
            FileHandle.standardOutput.write(Data("presented\n".utf8))
            Thread.detachNewThread {
                _ = readLine()
                handle.quit()
            }
        })
    }
}
