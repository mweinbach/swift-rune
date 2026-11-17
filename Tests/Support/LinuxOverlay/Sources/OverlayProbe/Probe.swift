import Foundation
import Rune

private func report(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

private final class ProbePass: Compositor {
    private let label: String
    private var reported = false
    init(_ label: String) { self.label = label }
    func render(frame: CompositorFrame<Int>) {
        frame.drawUI()
        if !reported, frame.openGL != nil {
            reported = true
            report("\(label) OpenGL \(frame.pixelSize.width)x\(frame.pixelSize.height)")
        }
    }
}

private final class Controls: @unchecked Sendable {
    // Accessed on the host thread, including each AppHandle.update callback.
    var overlay: OverlayHandle<Int>?

    func create(prewarm: Bool = false) {
        let options = OverlayOptions(
            placement: .edge(.top, margin: 36),
            input: .regions, prewarm: prewarm, releaseGpuWhenHidden: !prewarm, interactive: true
        )
        overlay = OverlaySpec<Int>(
            name: "Rune overlay probe", size: Vec2(180, 100),
            options: options, makeState: { 0 }
        ) { clicks, _ in
            let hit: El<Int> = el().size(64, 36)
                .bg(clicks.isMultiple(of: 2) ? Color(r: 0, g: 1, b: 0) : Color(r: 1, g: 0, b: 1))
                .hit().role(.button).label("Overlay toggle")
                .dragOut { _ in DragItem().text("Rune overlay drag") }
                .onDragOutEnd { _, outcome, _ in report("drag-answered \(outcome == .cancelled)") }
                .onClick { count, tx in
                    count += 1
                    if count == 1 {
                        tx.popupMenu(PopupMenu().item("open", "Open"), at: .point(90, 50)) { (_: inout Int, picked, _) in
                            report("popup-answered \(picked == nil)")
                        }
                    }
                    report("overlay-click \(count)")
                }
            return col().sizeFull().center().child(hit)
        }.configured(options).compositor(ProbePass(prewarm ? "hidden-pass" : "shown-pass")).onCreated { created in
            report("created \(String(describing: created.windowNumber))")
        }.makeHandle()
        if !prewarm { overlay?.show() }
    }

    func command(_ command: String) {
        switch command {
        case "create": create()
        case "prewarm": create(prewarm: true)
        case "hide": overlay?.hide()
        case "show": overlay?.show()
        case "none": overlay?.setInput(.none)
        case "all": overlay?.setInput(.all)
        case "regions": overlay?.setInput(.regions)
        case "bottom": overlay?.place(edge: .bottom, margin: 28)
        case "release": overlay = nil
        case "status":
            if let overlay {
                report("status \(overlay.availability.rawValue) \(overlay.surfaceDescription ?? "-") \(overlay.failure ?? "-")")
                let surface = overlay.surfaceStats
                report("frame \(surface.pixelWidth) \(surface.pixelHeight) \(surface.frameCount)")
            }
        default: break
        }
        report("command \(command)")
    }
}

@main
enum OverlayProbe {
    static func main() {
        let controls = Controls()
        var app = App<Int>(
            title: "Rune overlay underlay", size: Vec2(800, 600), state: 0
        ) { _, _ in
            el().sizeFull().bg(Color(r: 0, g: 0, b: 1))
                .onClick { count, _ in
                    count += 1
                    report("underlay-click \(count)")
                }
        }.windowOptions(WindowOptions(
            hasShadow: false, borderless: true, position: (0, 0), physicalSize: (800, 600)
        ))
        let handle = app.handle()
        app = app.setup { _ in
            Thread.detachNewThread {
                while let command = readLine(), command != "quit" {
                    handle.update { _, _ in controls.command(command) }
                }
                handle.quit()
            }
        }
        RuneApp.runOrExit(app)
    }
}
