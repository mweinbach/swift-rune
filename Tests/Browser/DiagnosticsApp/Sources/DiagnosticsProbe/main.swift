import Foundation
import Rune
import RuneKnobs
import RuneMac
import RunePerf

#if os(WASI)
private final class TextProbeCompositor: Compositor {
    nonisolated(unsafe) static weak var windowText: TextSystem?

    func render(frame: CompositorFrame<Int>) {
        Self.windowText = frame.runtime.textSystem
        frame.drawUI()
    }
}

@_cdecl("rune_probe_strut")
func strutGlyphY(_ size: Float, _ nonce: Int32) -> Float {
    guard let system = TextProbeCompositor.windowText else { return .nan }
    let style = TextStyle(size: size, lineHeight: 30, direction: .ltr)
    let before = system.glyphAtlas.cachedEntryCount
    let shaped = system.shape(text: "Wprobe\(nonce)", style: style, maxWidth: nil, pixelScale: 1,
                              emitGlyphs: true, bypassCache: true)
    guard system.glyphAtlas.cachedEntryCount == before else { return .nan }
    return shaped.glyphs.first?.rect.y ?? .nan
}

@_cdecl("rune_probe_knob_sequence")
func knobSequence() {
    let value = Knob.float("value", min: 0, max: 1, default: 0)
    let group = KnobGroup("knobs", knobs: [value])
    var knobs = Knobs()
    let samples = (0..<4).map { _ in
        knobs.random(group)
        return Int(knobs.get(value) * Float(1 << 24))
    }
    print("knobs " + samples.map(String.init).joined(separator: ","))
}

@_cdecl("rune_probe_frame_ms")
func frameMilliseconds() -> Double {
    _ = takeFramePhases()
    measureFramePhase(.paint) {}
    return takeFramePhases()[FramePhase.paint.rawValue]
}

private struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func check(_ condition: Bool, _ label: String) throws {
    if !condition { throw ProbeFailure(label) }
}

private func requireFilePrefsError(_ operation: () throws -> Void) throws {
    do { try operation() }
    catch PrefsError.io(let message) {
        try check(message == "prefs files are unsupported on web", message)
        return
    }
    throw ProbeFailure("expected file preferences error")
}

private func checkDiagnostics() throws {
    let memory = Prefs.open(appId: "browser", environment: [:])
    try memory.set("zoom", value: 3)
    try check(!memory.isPersistent && memory.get("zoom", as: Int.self) == 3, "memory preferences")
    try memory.remove("zoom")
    try check(!memory.contains("zoom"), "remove memory preference")

    let url = URL(fileURLWithPath: "/prefs.json")
    let prefs = Prefs.at(url)
    try requireFilePrefsError { try prefs.set("zoom", value: 3) }
    try check(prefs.isPersistent && prefs.get("zoom", as: Int.self) == 3, "retain failed write in memory")
    try requireFilePrefsError { try prefs.remove("zoom") }
    try check(!prefs.contains("zoom"), "retain failed removal in memory")
    try prefs.remove("zoom")

    try check(ProcessInfo.processInfo.environment[RelaunchController.afterEnvVar] == "42", "injected previous PID")
    try check(ProcessInfo.processInfo.environment["RUNE_HEADLESS_WAIT"] == "10", "injected attach delay")
    var args = ToolingArgs()
    args.listScenes = true
    _ = try HeadlessRunner.run(App(title: "probe", size: Vec2(4, 4), state: 0) { _, _ in el() }, args: args)
    RelaunchController.waitForPrevious()
    RelaunchController.spawn(arguments: [])
    RuneMac.setBusy(true)
    try check(!AppLifecycleHelpers.isBusy(), "browser busy marker")
    let knobURL = URL(fileURLWithPath: "/presets/sample.json")
    let knob = Knob.float("width", min: 0, max: 1, default: 0)
    var knobs = Knobs()
    knobs.set(knob, 0.75)
    try knobs.save(to: knobURL)
    var loaded = Knobs()
    try loaded.load(from: knobURL)
    try check(loaded.get(knob) == 0.75, "WASI preset round trip")

    let body = try InteractionExporter.encodeOTLPBody(serviceName: "browser-probe", spans: [])
    try check(body.contains("service.name") && body.contains("browser-probe") && !body.contains("process.pid"), "OTLP resources")
    try check(ProcessSampler.snapshot() == nil, "process snapshot")
    Procwatch.watch(.dev("browser"))
    try check(Procwatch.latest() == nil, "process watcher")
    for (app, expected) in [("browser", PerfRecorderError.localFilesUnsupported), (String(repeating: "x", count: 129), .identityTooLong)] {
        do { _ = try PerfFileRecorder.start(config: PerfConfig(directory: url, app: app)) }
        catch let error as PerfRecorderError {
            try check(error == expected, "unexpected recorder error: \(error)")
            continue
        }
        throw ProbeFailure("expected recorder to reject \(app)")
    }
    let jobs: [(String, MotionGateGate.Job)] = [("first", { MotionGateRecording() }), ("second", { MotionGateRecording() })]
    let cells = MotionGateGate.run(jobs)
    try check(cells.map(\.name) == ["first", "second"] && cells.allSatisfy(\.skipped), "sequential motion gate")
    do { _ = try MotionGateGate.gateRows(jobs, rows: [], environment: ["MOTION_GATE_SHEET": "first|0"]) }
    catch let report as MotionGateReport {
        try check(report.failing == 2 && report.text.contains("SKIP first"), "sheet-free motion gate")
        return
    }
    throw ProbeFailure("expected skipped motion cells")
}

@_cdecl("rune_probe_diagnostics")
func runDiagnostics() {
    do { try checkDiagnostics(); print("diagnostics passed") }
    catch { print("diagnostics failed: \(error)") }
}
#endif

let diagnostics = App(title: "Browser diagnostics", size: Vec2(96, 48), state: 0) { _, _ in
    el().sizeFull().bg(.rgba8(10, 80, 142))
}
#if os(WASI)
try RuneApp.run(diagnostics.compositor(TextProbeCompositor()))
#else
try RuneApp.run(diagnostics)
#endif
