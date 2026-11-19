import Foundation
import Rune
import RuneKit
import RuneMotion

// MARK: - Live Hardware Telemetry (Windows RTX Spark + Cross-Platform Fallback)

public struct HostTelemetry: Sendable, Equatable {
    public var hostName: String
    public var platformLabel: String
    public var archLabel: String
    public var cpuCores: Int
    public var memoryGB: Int
    public var gpuName: String
    public var gpuDriver: String
    public var vramUsedMiB: Int
    public var vramTotalMiB: Int
    public var gpuTempC: Int
    public var gpuUtilPct: Int
    public var backendLabel: String

    public static func detect() -> HostTelemetry {
        let info = ProcessInfo.processInfo
        let host = info.hostName.replacingOccurrences(of: ".local", with: "")
        let cores = info.processorCount
        let memGB = max(1, Int((Double(info.physicalMemory) / (1024.0 * 1024.0 * 1024.0)).rounded()))

        #if arch(arm64)
        let arch = "ARM64"
        #elseif arch(x86_64)
        let arch = "x64"
        #else
        let arch = "Native"
        #endif

        #if os(Windows)
        let platform = "Windows 11 (\(arch))"
        let backend = "Win32 · OpenGL · DirectWrite"
        let nvidia = queryNvidiaSMI()
        return HostTelemetry(
            hostName: host.isEmpty ? "MSI-RTX-BOX" : host,
            platformLabel: platform,
            archLabel: arch,
            cpuCores: cores,
            memoryGB: memGB,
            gpuName: nvidia?.name ?? "NVIDIA RTX GPU",
            gpuDriver: nvidia?.driver ?? "WDDM",
            vramUsedMiB: nvidia?.usedMiB ?? 1_480,
            vramTotalMiB: nvidia?.totalMiB ?? 64_000,
            gpuTempC: nvidia?.tempC ?? 38,
            gpuUtilPct: nvidia?.utilPct ?? 12,
            backendLabel: backend
        )
        #elseif os(macOS)
        return HostTelemetry(
            hostName: host.isEmpty ? "macOS" : host,
            platformLabel: "macOS (\(arch))",
            archLabel: arch,
            cpuCores: cores,
            memoryGB: memGB,
            gpuName: "Apple Silicon Metal GPU",
            gpuDriver: "Metal 3",
            vramUsedMiB: 2_048,
            vramTotalMiB: memGB * 1024,
            gpuTempC: 41,
            gpuUtilPct: 14,
            backendLabel: "AppKit · Metal · CoreText"
        )
        #else
        return HostTelemetry(
            hostName: host.isEmpty ? "Linux" : host,
            platformLabel: "Linux (\(arch))",
            archLabel: arch,
            cpuCores: cores,
            memoryGB: memGB,
            gpuName: "OpenGL GPU",
            gpuDriver: "Mesa / NVIDIA",
            vramUsedMiB: 1_024,
            vramTotalMiB: 16_384,
            gpuTempC: 40,
            gpuUtilPct: 10,
            backendLabel: "Wayland/X11 · OpenGL"
        )
        #endif
    }

    #if os(Windows)
    private struct NvidiaSnapshot {
        var name: String
        var driver: String
        var totalMiB: Int
        var usedMiB: Int
        var tempC: Int
        var utilPct: Int
    }

    private static func queryNvidiaSMI() -> NvidiaSnapshot? {
        let candidates = [
            "C:\\Windows\\System32\\nvidia-smi.exe",
            "C:\\Program Files\\NVIDIA Corporation\\NVSMI\\nvidia-smi.exe",
        ]
        guard let exe = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return nil
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = [
            "--query-gpu=name,driver_version,memory.total,memory.used,temperature.gpu,utilization.gpu",
            "--format=csv,noheader,nounits",
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0,
                  let line = String(data: data, encoding: .utf8)?
                      .split(whereSeparator: \.isNewline)
                      .first else { return nil }
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count >= 6 else { return nil }
            return NvidiaSnapshot(
                name: parts[0],
                driver: parts[1],
                totalMiB: Int(Double(parts[2]) ?? 64_000),
                usedMiB: Int(Double(parts[3]) ?? 1_200),
                tempC: Int(Double(parts[4]) ?? 39),
                utilPct: Int(Double(parts[5]) ?? 8)
            )
        } catch {
            return nil
        }
    }
    #endif
}

// MARK: - Icons

private enum StudioIcons {
    static let spark = SVGIcon(
        viewBox: 16,
        paths: ["M9 1.5L3.5 9H8L7 14.5L12.5 7H8L9 1.5Z"],
        strokeWidth: 1.25,
        body: #"<path d="M9 1.5L3.5 9H8L7 14.5L12.5 7H8L9 1.5Z" stroke="currentColor" stroke-width="1.25" stroke-linejoin="round" fill="none"/>"#
    )
    static let dashboard = SVGIcon(
        viewBox: 16,
        paths: ["M2.5 2.5H7V7.5H2.5ZM9 2.5H13.5V5.5H9ZM9 7.5H13.5V13.5H9ZM2.5 9.5H7V13.5H2.5Z"],
        strokeWidth: 1.2,
        body: #"<rect x="2.5" y="2.5" width="4.5" height="5" rx="1" stroke="currentColor" stroke-width="1.2" fill="none"/><rect x="9" y="2.5" width="4.5" height="3" rx="1" stroke="currentColor" stroke-width="1.2" fill="none"/><rect x="9" y="7.5" width="4.5" height="6" rx="1" stroke="currentColor" stroke-width="1.2" fill="none"/><rect x="2.5" y="9.5" width="4.5" height="4" rx="1" stroke="currentColor" stroke-width="1.2" fill="none"/>"#
    )
    static let diff = SVGIcon(
        viewBox: 16,
        paths: ["M4 3.5V12.5M12 3.5V12.5M4 6.5H12M4 9.5H12"],
        strokeWidth: 1.2,
        body: #"<rect x="2.5" y="2.5" width="11" height="11" rx="1.8" stroke="currentColor" stroke-width="1.2" fill="none"/><path d="M8 2.5V13.5M4.5 6.5H6.5M5.5 5.5V7.5M9.5 6.5H11.5M9.5 9.5H11.5" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>"#
    )
    static let docs = SVGIcon(
        viewBox: 16,
        paths: ["M3.5 2.5H10L12.5 5V13.5H3.5Z"],
        strokeWidth: 1.2,
        body: #"<path d="M3.5 2.5H9.5L12.5 5.5V13.5H3.5V2.5Z" stroke="currentColor" stroke-width="1.2" stroke-linejoin="round" fill="none"/><path d="M5.5 8H10.5M5.5 10.5H9" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>"#
    )
    static let controls = SVGIcon(
        viewBox: 16,
        paths: ["M3 5H13M3 11H13"],
        strokeWidth: 1.2,
        body: #"<path d="M3 5H13M3 11H13" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/><circle cx="6" cy="5" r="1.7" fill="currentColor"/><circle cx="10.5" cy="11" r="1.7" fill="currentColor"/>"#
    )
    static let sun = SVGIcon(
        viewBox: 16,
        paths: ["M8 2V3.4M8 12.6V14M2 8H3.4M12.6 8H14"],
        strokeWidth: 1.25,
        body: #"<circle cx="8" cy="8" r="2.8" stroke="currentColor" stroke-width="1.25" fill="none"/><path d="M8 2V3.3M8 12.7V14M2 8H3.3M12.7 8H14M3.75 3.75L4.7 4.7M11.3 11.3L12.25 12.25M12.25 3.75L11.3 4.7M4.7 11.3L3.75 12.25" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/>"#
    )
    static let moon = SVGIcon(
        viewBox: 16,
        paths: ["M12.5 9.8A4.8 4.8 0 0 1 6.2 3.5A5.2 5.2 0 1 0 12.5 9.8Z"],
        strokeWidth: 1.25,
        body: #"<path d="M12.5 9.8A4.8 4.8 0 0 1 6.2 3.5A5.2 5.2 0 1 0 12.5 9.8Z" stroke="currentColor" stroke-width="1.25" stroke-linejoin="round" fill="none"/>"#
    )
}

// MARK: - App State

public enum StudioTab: String, CaseIterable, Sendable, Hashable, CustomStringConvertible {
    case dashboard
    case diff
    case markdown
    case controls

    public var description: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Overview"
        case .diff: "Shader Diff"
        case .markdown: "Workbench"
        case .controls: "Controls"
        }
    }

    var subtitle: String {
        switch self {
        case .dashboard: "Live hardware & frame telemetry"
        case .diff: "Win32 OpenGL & Swift review"
        case .markdown: "Markdown, Swift code & Mermaid"
        case .controls: "Native RuneKit component lab"
        }
    }

    var icon: SVGIcon {
        switch self {
        case .dashboard: StudioIcons.dashboard
        case .diff: StudioIcons.diff
        case .markdown: StudioIcons.docs
        case .controls: StudioIcons.controls
        }
    }
}

public enum PowerMode: String, CaseIterable, Sendable, Hashable, CustomStringConvertible {
    case quiet
    case balanced
    case boost

    public var description: String { rawValue }

    var label: String {
        switch self {
        case .quiet: "Quiet"
        case .balanced: "Balanced"
        case .boost: "RTX Boost"
        }
    }

    var targetHz: Int {
        switch self {
        case .quiet: 60
        case .balanced: 120
        case .boost: 240
        }
    }

    var frameSamplesMs: [Float] {
        switch self {
        case .quiet: [5.4, 5.1, 4.9, 5.6, 5.0, 4.8, 5.2, 5.1, 4.9, 5.0, 4.8, 5.1]
        case .balanced: [2.8, 2.4, 2.5, 2.9, 2.3, 2.2, 2.6, 2.4, 2.1, 2.3, 2.2, 2.4]
        case .boost: [1.3, 1.1, 1.2, 1.4, 1.0, 1.1, 1.2, 0.9, 1.1, 1.0, 1.2, 1.0]
        }
    }
}

public enum AccentPreset: String, CaseIterable, Sendable, Hashable, CustomStringConvertible {
    case emerald
    case cobalt
    case amber
    case rose

    public var description: String { rawValue }

    var label: String {
        switch self {
        case .emerald: "Spark"
        case .cobalt: "Cobalt"
        case .amber: "Amber"
        case .rose: "Rose"
        }
    }

    func color(dark: Bool) -> Color {
        switch self {
        case .emerald: dark ? Color.oklch(0.76, 0.17, 152) : Color.oklch(0.54, 0.16, 152)
        case .cobalt:  dark ? Color.oklch(0.72, 0.16, 255) : Color.oklch(0.52, 0.17, 255)
        case .amber:   dark ? Color.oklch(0.79, 0.15, 75)  : Color.oklch(0.60, 0.15, 70)
        case .rose:    dark ? Color.oklch(0.73, 0.17, 12)  : Color.oklch(0.55, 0.18, 12)
        }
    }
}

private let sampleOldSwift = """
import Foundation
import Rune

/// Presents a single Rune frame onto the Windows swap chain.
public final class Win32FramePresenter {
    private var srgbBlend: Bool = true
    private var pendingDraws: Int = 0

    public func present(width: Int, height: Int) -> Bool {
        guard width > 0 && height > 0 else { return false }
        pendingDraws += 1
        return true
    }

    public func setSRGBBlend(_ enabled: Bool) {
        srgbBlend = enabled
    }
}
"""

private let sampleNewSwift = """
import Foundation
import Rune

/// Presents a single Rune frame onto the Windows DirectComposition / OpenGL surface.
public final class Win32FramePresenter {
    private var srgbBlend: Bool = true
    private var pendingDraws: Int = 0
    private var slotGeneration: UInt64 = 0

    public func present(width: Int, height: Int, dpi: UInt32) -> Bool {
        guard width > 0 && height > 0 else { return false }
        let scale = Win32DpiScale.scaleFactor(forDPI: dpi)
        pendingDraws += 1
        return scale >= 0.5
    }

    public func setSRGBBlend(_ enabled: Bool) {
        guard srgbBlend != enabled else { return }
        srgbBlend = enabled
        slotGeneration &+= 1
    }
}
"""

private let sampleOldGLSL = """
float boxDistance(vec2 p, vec2 extent, vec4 radii) {
    float r = min(abs(radii.x), min(extent.x, extent.y));
    vec2 q = abs(p) - extent + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
"""

private let sampleNewGLSL = """
float boxDistance(vec2 p, vec2 extent, vec4 radii) {
    float signedRadius = cornerRadius(p, radii);
    float r = min(abs(signedRadius), min(extent.x, extent.y));
    if (signedRadius < 0.0) {
        return sd_continuous(p, extent, r);
    }
    vec2 q = abs(p) - extent + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
"""

private let sampleMarkdownDoc = #"""
# Spark Studio on Windows ARM64

Native **Swift 6.4** desktop UI powered by **Rune** + **RuneKit** — zero Electron, zero WebView, direct Win32 + GPU rendering.

```mermaid
flowchart LR
    A["SparkStudio"] --> B["RuneKit"]
    B --> C["Rune Core"]
    C --> D["Win32 · GL"]
    D --> E["RTX Spark N1X"]
```

## Architecture Highlights

- **Per-line syntax highlighting** via `El.byLine()` for smooth streaming code views
- **Spring physics & shared-element pills** driven by `RuneMotion`
- **Custom DWM titlebar** honoring native Windows caption buttons & DPI scaling

```swift
let app = App(title: "Spark Studio", size: Vec2(1240, 780), state: StudioState()) { state, cx in
    studioView(state, &cx)
}
.titlebar(Titlebar(height: 44))
try app.run()
```

| Subsystem | Backend | Status | Target Latency |
|:--|:--|:--|--:|
| Layout Engine | RuneTaffy (64B Style / 96B Cache) | Active | 0.18 ms |
| Text Shaping | DirectWrite + Subpixel Atlas | Active | 0.34 ms |
| GPU Compositor | OpenGL 4.6 · Float16 Layers | Active | 0.72 ms |
| Accessibility | Windows UI Automation (`TextPattern2`) | Active | 0.09 ms |
"""#

public struct StudioState: Sendable {
    public var host: HostTelemetry
    public var tab: StudioTab = .dashboard
    public var darkOverride: Bool? = true
    public var accent: AccentPreset = .emerald
    public var powerMode: PowerMode = .boost
    public var search: TextEdit = TextEdit("")
    public var scratchpad: TextEdit = TextEdit(
        "Running natively in Swift 6.4 on Windows ARM64 with Rune.\nTry switching tabs, dragging sliders, toggling Light/Dark, or editing live Markdown!",
        multiline: true
    )
    public var markdownInput: TextEdit = TextEdit(sampleMarkdownDoc, multiline: true)
    public var diff: DiffState
    public var vsyncEnabled: Bool = true
    public var directCompEnabled: Bool = true
    public var reducedMotionPreview: Bool = false
    public var showGridOverlay: Bool = true
    public var checkA11y: Bool = true
    public var checkShaders: Bool = true
    public var checkSubpixel: Bool = true
    public var renderScale: Float = 1.0
    public var blurStrength: Float = 0.65
    public var radioBackend: String = "opengl"
    public var actionCount: Int = 0
    public var statusBanner: String? = "Connected to native Win32 + GPU pipeline"

    public init(host: HostTelemetry = HostTelemetry.detect()) {
        self.host = host
        let files: [FileDiff] = [
            FileDiff.fromTexts(path: "Sources/Rune/Win32FramePresenter.swift", old: sampleOldSwift, new: sampleNewSwift),
            FileDiff.fromTexts(path: "Sources/Rune/Resources/GL/surface.frag", old: sampleOldGLSL, new: sampleNewGLSL),
        ]
        let ann = DiffAnnotation(
            id: "spark-review-1",
            file: 0,
            side: .new,
            line: 19,
            body: "Incrementing slotGeneration avoids waiting on stale DXGI/WGL swap-chain frames after toggling sRGB blend."
        )
        self.diff = DiffState(files: files, mode: .split, annotations: [ann])
    }
}

// MARK: - Reusable Building Blocks

private func makeStudioKit(dark: Bool, accent: Color) -> Kit {
    var k = Kit.neutral(dark: dark)
    k.c.bgAccent = accent
    k.c.textAccent = accent
    k.c.borderFocus = accent.alpha(0.75)
    return k
}

private func metricCard(
    _ k: Kit,
    key: String,
    label: String,
    value: String,
    detail: String,
    accent: Color
) -> El<StudioState> {
    let body: El<StudioState> = col()
        .wFull()
        .gap(6)
        .child(
            row().wFull().itemsCenter().justifyBetween()
                .child(text(label).font(k.ty.small).color(k.c.textMuted))
                .child(el().size(8, 8).rounded(4).bg(accent))
        )
        .child(text(value).font(TextStyle(size: 24, weight: 650, lineHeight: 28)).color(k.c.textBase))
        .child(text(detail).font(k.ty.small).color(k.c.textFaint).ellipsis())

    return k.card(key: key, body)
        .grow(1)
        .minW(0)
}

private func telemetryBarChart(_ s: StudioState, _ k: Kit, accent: Color) -> El<StudioState> {
    let samples = s.powerMode.frameSamplesMs
    let maxMs: Float = 6.5
    var bars: El<StudioState> = row().wFull().h(78).gap(8).itemsEnd()
    for (idx, ms) in samples.enumerated() {
        let frac = max(0.14, min(1.0, ms / maxMs))
        let h = frac * 60.0
        let barCol = idx == samples.count - 1 ? accent : accent.alpha(0.45 + 0.35 * frac)
        bars = bars.child(
            col().grow(1).itemsCenter().gap(4)
                .child(
                    el()
                        .key("frame-bar-\(idx)")
                        .wFull()
                        .h(h)
                        .rounded(5)
                        .bg(barCol)
                        .animateLayout(LayoutAnim(spring: Spring.snappy))
                )
                .child(text(String(format: "%.1f", ms)).font(TextStyle(size: 10, weight: 500, lineHeight: 12)).color(k.c.textFaint))
        )
    }

    let avg = samples.reduce(0, +) / Float(max(1, samples.count))
    let header: El<StudioState> = row().wFull().itemsCenter().justifyBetween()
        .child(
            col().gap(2)
                .child(text("Frame Render Time (ms)").font(k.ty.uiMedium).color(k.c.textBase))
                .child(text("12-frame rolling window · \(s.powerMode.label) profile · avg \(String(format: "%.2f", avg)) ms").font(k.ty.small).color(k.c.textMuted))
        )
        .child(k.badge("\(s.powerMode.targetHz) Hz Target", tone: .success))

    return k.card(
        key: "frame-chart-card",
        col().wFull().gap(10).child(header).child(bars)
    )
}

// MARK: - Workspace Views

private func dashboardView(_ s: StudioState, _ k: Kit, accent: Color) -> El<StudioState> {
    let vramUsedGB = Double(s.host.vramUsedMiB) / 1024.0
    let vramTotalGB = max(1.0, Double(s.host.vramTotalMiB) / 1024.0)
    let vramFrac = Float(max(0.03, min(1.0, vramUsedGB / vramTotalGB)))

    let heroTitle: El<StudioState> = row().gap(8).itemsCenter()
        .child(icon(StudioIcons.spark, size: 18).color(accent))
        .child(text(s.host.gpuName).font(TextStyle(size: 20, weight: 680, lineHeight: 24)).color(k.c.textBase))
        .child(k.badge(s.host.platformLabel, tone: .info))

    let powerSeg: El<StudioState> = k.segmentedControl(
        key: "power-mode",
        options: PowerMode.allCases.map { ($0, $0.label) },
        selected: s.powerMode
    ) { st, mode in
        st.powerMode = mode
        st.statusBanner = "Switched GPU workload profile to \(mode.label) (\(mode.targetHz) Hz)"
    }.w(280)

    let vramSection: El<StudioState> = col().wFull().gap(6)
        .child(
            row().wFull().justifyBetween().itemsCenter()
                .child(text("Unified VRAM Allocation").font(k.ty.small).color(k.c.textMuted))
                .child(text(String(format: "%.1f / %.0f GB (%.1f%%)", vramUsedGB, vramTotalGB, Double(vramFrac * 100))).font(k.ty.small).color(k.c.textBase))
        )
        .child(
            row().wFull().h(8).rounded(4).bg(k.c.surfaceWeak).clip()
                .child(el().key("vram-bar").wFrac(vramFrac).hFull().rounded(4).bg(accent))
        )

    let hero: El<StudioState> = col()
        .key("hero-banner")
        .wFull()
        .p(16)
        .gap(10)
        .rounded(-14)
        .bg(k.c.layer02)
        .border(1, accent.alpha(0.35))
        .child(
            row().wFull().itemsCenter().justifyBetween().gap(12)
                .child(
                    col().gap(4)
                        .child(heroTitle)
                        .child(text("\(s.host.hostName) · \(s.host.cpuCores) logical cores · \(s.host.memoryGB) GB unified RAM · Driver \(s.host.gpuDriver)").font(k.ty.ui).color(k.c.textMuted))
                )
                .child(powerSeg)
        )
        .child(vramSection)

    let metrics: El<StudioState> = row().wFull().gap(12)
        .child(metricCard(k, key: "m-fps", label: "Target Cadence", value: "\(s.powerMode.targetHz) FPS", detail: s.host.backendLabel, accent: accent))
        .child(metricCard(k, key: "m-temp", label: "GPU Thermals", value: "\(s.host.gpuTempC)°C", detail: "Utilization \(s.host.gpuUtilPct)% · Driver \(s.host.gpuDriver)", accent: k.c.success.icon))
        .child(metricCard(k, key: "m-vram", label: "Total VRAM", value: String(format: "%.0f GB", vramTotalGB), detail: "\(s.host.vramTotalMiB) MiB addressable", accent: k.c.info.icon))
        .child(metricCard(k, key: "m-tests", label: "Rune Parity", value: "100%", detail: "Synced to anomalyco/rune@f54cbcfa", accent: k.c.warning.icon))

    let pipelineItems: [(String, String, BadgeTone)] = [
        ("Win32 Host & DWM Titlebar", "Custom chrome + DPI-aware input", .success),
        ("OpenGL 4.6 Float16 Layers", "Continuous corners + PlusLighter clamp", .success),
        ("DirectWrite Text Engine", "Per-line code shaping + subpixel atlas", .info),
        ("UI Automation Tree", "TextPattern2 + explicit semantic roles", .neutral),
    ]
    var pipeList: El<StudioState> = col().wFull().gap(6)
    for (idx, item) in pipelineItems.enumerated() {
        pipeList = pipeList.child(
            row()
                .key("pipe-\(idx)")
                .wFull()
                .px(10)
                .py(7)
                .rounded(8)
                .bg(k.c.surfaceWeak)
                .itemsCenter()
                .justifyBetween()
                .gap(10)
                .child(
                    col().gap(1)
                        .child(text(item.0).font(k.ty.uiMedium).color(k.c.textBase))
                        .child(text(item.1).font(k.ty.small).color(k.c.textMuted))
                )
                .child(k.badge("Ready", tone: item.2))
        )
    }

    let pipelineCard: El<StudioState> = k.card(
        key: "pipeline-card",
        col().wFull().gap(8)
            .child(text("Native Windows Backend Stack").font(k.ty.uiMedium).color(k.c.textBase))
            .child(pipeList)
    ).grow(1).minW(0)

    let notesCard: El<StudioState> = k.card(
        key: "notes-card",
        col().wFull().gap(8)
            .child(
                row().wFull().itemsCenter().justifyBetween()
                    .child(text("Live Scratchpad (Win32 IME + Clipboard)").font(k.ty.uiMedium).color(k.c.textBase))
                    .child(
                        row().gap(6)
                            .child(k.button(key: "note-sample", "Stamp", variant: .ghost, size: .sm) { st, _ in
                                st.actionCount += 1
                                st.scratchpad = TextEdit(
                                    st.scratchpad.text + "\n[Run #\(st.actionCount)] \(st.host.gpuName) · \(st.powerMode.label)",
                                    multiline: true
                                )
                                st.statusBanner = "Appended hardware stamp #\(st.actionCount)"
                            })
                            .child(k.button(key: "note-clear", "Clear", variant: .ghost, size: .sm) { st, _ in
                                st.scratchpad = TextEdit("", multiline: true)
                                st.statusBanner = "Cleared scratchpad"
                            })
                    )
            )
            .child(
                Rune.textInput(key: "scratchpad-edit", \StudioState.scratchpad)
                    .wFull()
                    .h(168)
                    .p(10)
                    .rounded(8)
                    .bg(k.c.surfaceWeak)
                    .border(1, k.c.borderBase)
                    .font(TextStyle(size: 13, weight: 400, lineHeight: 20))
                    .color(k.c.textBase)
                    .caret(accent, selection: accent.alpha(0.28))
                    .placeholder("Type directly into Rune's Win32 text engine…", color: k.c.textFaint)
            )
    ).grow(1).minW(0)

    let content: El<StudioState> = col()
        .wFull()
        .p(16)
        .gap(12)
        .child(hero)
        .child(metrics)
        .child(telemetryBarChart(s, k, accent: accent))
        .child(row().wFull().gap(12).itemsStart().child(pipelineCard).child(notesCard))

    return col()
        .key("dash-scroll")
        .wFull()
        .grow(1)
        .minH(0)
        .scrollY()
        .child(content)
        .scrollBar(k)
}

private func diffWorkspaceView(_ s: StudioState, _ cx: Cx<StudioState>, _ k: Kit) -> El<StudioState> {
    let modes: El<StudioState> = k.segmentedControl(
        key: "diff-mode-seg",
        options: [("unified", "Unified"), ("split", "Split")],
        selected: s.diff.mode == .split ? "split" : "unified"
    ) { st, mode in
        st.diff.setMode(mode == "split" ? .split : .unified)
        st.statusBanner = "Diff viewer switched to \(mode == "split" ? "Split" : "Unified") mode"
    }.w(180)

    let header: El<StudioState> = row()
        .wFull()
        .px(20)
        .py(12)
        .itemsCenter()
        .justifyBetween()
        .borderSides(bottom: 1, color: k.c.borderMuted)
        .child(
            col().gap(2)
                .child(text("Win32 Swap-Chain & Continuous-Corner Shader Patch").font(k.ty.uiMedium).color(k.c.textBase))
                .child(text("2 files changed · Swift + GLSL syntax highlighting · inline review thread").font(k.ty.small).color(k.c.textMuted))
        )
        .child(modes)

    let diffEl: El<StudioState> = k.diffView(key: "studio-diff", state: s, cx: cx, at: \StudioState.diff) { dv in
        dv.annotation { _, ann in
            col()
                .wFull()
                .p(12)
                .gap(6)
                .rounded(8)
                .bg(k.c.layer02)
                .border(1, k.c.borderBase)
                .child(
                    row().gap(8).itemsCenter()
                        .child(k.badge("Review Note", tone: .info))
                        .child(text("line \(ann.line)").font(k.ty.small).color(k.c.textFaint))
                )
                .child(text(ann.body).font(k.ty.ui).color(k.c.textBase).wrapText())
        }
    }
    .wFull()
    .grow(1)
    .minH(0)

    return col().wFull().grow(1).minH(0).child(header).child(diffEl)
}

private func markdownWorkspaceView(_ s: StudioState, _ k: Kit, accent: Color) -> El<StudioState> {
    let editorPane: El<StudioState> = col()
        .w(390)
        .hFull()
        .p(16)
        .gap(10)
        .borderSides(right: 1, color: k.c.borderMuted)
        .child(
            row().wFull().itemsCenter().justifyBetween()
                .child(text("Markdown Source").font(k.ty.uiMedium).color(k.c.textBase))
                .child(k.button(key: "md-reset", "Reset", variant: .ghost, size: .sm) { st, _ in
                    st.markdownInput = TextEdit(sampleMarkdownDoc, multiline: true)
                })
        )
        .child(
            Rune.textInput(key: "md-source", \StudioState.markdownInput)
                .wFull()
                .grow(1)
                .minH(0)
                .p(12)
                .rounded(10)
                .bg(k.c.surfaceWeak)
                .border(1, k.c.borderBase)
                .mono()
                .font(TextStyle(size: 12.5, weight: 400, lineHeight: 19))
                .color(k.c.textBase)
                .caret(accent, selection: accent.alpha(0.28))
        )

    let previewPane: El<StudioState> = col()
        .key("md-preview-scroll")
        .grow(1)
        .minW(0)
        .hFull()
        .scrollY()
        .child(
            col().wFull().p(24).gap(12)
                .child(k.markdown(s.markdownInput.text, key: "studio-md"))
        )
        .scrollBar(k)

    return row().wFull().grow(1).minH(0).child(editorPane).child(previewPane)
}

private func controlsWorkspaceView(_ s: StudioState, _ k: Kit, accent: Color) -> El<StudioState> {
    let switchesCard: El<StudioState> = k.card(
        key: "ctl-switches",
        col().wFull().gap(14)
            .child(text("Display & Compositor Toggles").font(k.ty.uiMedium).color(k.c.textBase))
            .child(
                row().wFull().itemsCenter().justifyBetween()
                    .child(col().gap(2)
                        .child(text("Adaptive VSync Pacing").font(k.ty.ui).color(k.c.textBase))
                        .child(text("Synchronize frame submission to display refresh").font(k.ty.small).color(k.c.textMuted)))
                    .child(k.switchControl(key: "sw-vsync", isOn: s.vsyncEnabled, label: "Adaptive VSync") { st, _ in
                        st.vsyncEnabled.toggle()
                    })
            )
            .child(k.divider())
            .child(
                row().wFull().itemsCenter().justifyBetween()
                    .child(col().gap(2)
                        .child(text("DirectComposition Surface").font(k.ty.ui).color(k.c.textBase))
                        .child(text("Zero-copy swap chain with rounded corner compositing").font(k.ty.small).color(k.c.textMuted)))
                    .child(k.switchControl(key: "sw-dcomp", isOn: s.directCompEnabled, label: "DirectComposition") { st, _ in
                        st.directCompEnabled.toggle()
                    })
            )
            .child(k.divider())
            .child(
                row().wFull().itemsCenter().justifyBetween()
                    .child(col().gap(2)
                        .child(text("Reduced Motion Preview").font(k.ty.ui).color(k.c.textBase))
                        .child(text("Snap springs immediately when accessibility prefers reduced motion").font(k.ty.small).color(k.c.textMuted)))
                    .child(k.switchControl(key: "sw-rm", isOn: s.reducedMotionPreview, label: "Reduced Motion") { st, _ in
                        st.reducedMotionPreview.toggle()
                    })
            )
    ).grow(1).minW(0)

    let slidersCard: El<StudioState> = k.card(
        key: "ctl-sliders",
        col().wFull().gap(14)
            .child(text("Live Theme & Rendering Controls").font(k.ty.uiMedium).color(k.c.textBase))
            .child(
                col().wFull().gap(6)
                    .child(row().wFull().justifyBetween()
                        .child(text("UI Zoom Factor").font(k.ty.small).color(k.c.textMuted))
                        .child(text(String(format: "%.2fx", s.renderScale)).font(k.ty.small).color(k.c.textBase)))
                    .child(k.slider(key: "sl-scale", value: s.renderScale, range: 0.85...1.35) { st, v in
                        st.renderScale = v
                    })
            )
            .child(
                col().wFull().gap(6)
                    .child(row().wFull().justifyBetween()
                        .child(text("Backdrop Frost Intensity").font(k.ty.small).color(k.c.textMuted))
                        .child(text("\(Int((s.blurStrength * 100).rounded()))%").font(k.ty.small).color(k.c.textBase)))
                    .child(k.slider(key: "sl-blur", value: s.blurStrength, range: 0.0...1.0) { st, v in
                        st.blurStrength = v
                    })
            )
            .child(
                col().wFull().gap(6)
                    .child(text("Accent Palette").font(k.ty.small).color(k.c.textMuted))
                    .child(
                        k.segmentedControl(
                            key: "accent-seg",
                            options: AccentPreset.allCases.map { ($0, $0.label) },
                            selected: s.accent
                        ) { st, preset in
                            st.accent = preset
                        }
                    )
            )
    ).grow(1).minW(0)

    let checksCard: El<StudioState> = k.card(
        key: "ctl-checks",
        col().wFull().gap(12)
            .child(text("Verification Flags & Backend").font(k.ty.uiMedium).color(k.c.textBase))
            .child(k.checkbox(key: "cb-a11y", checked: s.checkA11y, label: "Publish Windows UI Automation Tree") { st, _ in st.checkA11y.toggle() })
            .child(k.checkbox(key: "cb-shaders", checked: s.checkShaders, label: "Continuous-corner SDF & PlusLighter clamp") { st, _ in st.checkShaders.toggle() })
            .child(k.checkbox(key: "cb-subpx", checked: s.checkSubpixel, label: "DirectWrite subpixel glyph rasterization") { st, _ in st.checkSubpixel.toggle() })
            .child(k.divider())
            .child(
                k.radioGroup(
                    key: "rg-backend",
                    options: [
                        (id: "opengl", label: "OpenGL 4.6 Core (RTX Spark)"),
                        (id: "cpu", label: "CPU Boot First-Frame Fallback"),
                    ],
                    selected: s.radioBackend
                ) { st, chosen in
                    st.radioBackend = chosen
                }
            )
    ).grow(1).minW(0)

    let buttonRow: El<StudioState> = row().gap(8).itemsCenter()
        .child(k.button(key: "act-primary", "Primary", variant: .primary, size: .sm) { st, _ in
            st.actionCount += 1
            st.statusBanner = "Primary button clicked (\(st.actionCount))"
        })
        .child(k.button(key: "act-accent", "Benchmark", variant: .accent, size: .sm) { st, _ in
            st.actionCount += 1
            st.powerMode = .boost
            st.statusBanner = "RTX Boost benchmark pulse #\(st.actionCount)"
        })
        .child(k.button(key: "act-neutral", "Neutral", variant: .neutral, size: .sm) { st, _ in
            st.actionCount += 1
        })
        .child(k.button(key: "act-ghost", "Ghost", variant: .ghost, size: .sm) { st, _ in
            st.actionCount += 1
        })
        .child(k.button(key: "act-danger", "Reset", variant: .danger, size: .sm) { st, _ in
            st.actionCount = 0
            st.renderScale = 1.0
            st.blurStrength = 0.65
            st.statusBanner = "Controls reset to defaults"
        })

    let badgeRow: El<StudioState> = row().gap(8).itemsCenter()
        .child(k.badge("Neutral", tone: .neutral))
        .child(k.badge("Info", tone: .info))
        .child(k.badge("Success", tone: .success))
        .child(k.badge("Warning", tone: .warning))
        .child(k.badge("Danger", tone: .danger))

    let liveStrip: El<StudioState> = row()
        .wFull()
        .p(12)
        .rounded(8)
        .bg(accent.alpha(0.12))
        .border(1, accent.alpha(0.35))
        .itemsCenter()
        .justifyBetween()
        .child(text("Interactive clicks recorded this session: \(s.actionCount)").font(k.ty.uiMedium).color(k.c.textBase))
        .child(k.badge("Live State", tone: .success))

    let actionsCard: El<StudioState> = k.card(
        key: "ctl-actions",
        col().wFull().gap(12)
            .child(text("Buttons, Badges & Interactive Elevation").font(k.ty.uiMedium).color(k.c.textBase))
            .child(buttonRow)
            .child(badgeRow)
            .child(liveStrip)
    ).grow(1).minW(0)

    let topRow: El<StudioState> = row().wFull().gap(16).itemsStart().child(switchesCard).child(slidersCard)
    let bottomRow: El<StudioState> = row().wFull().gap(16).itemsStart().child(checksCard).child(actionsCard)
    let controlsBody: El<StudioState> = col().wFull().p(20).gap(16).child(topRow).child(bottomRow)

    return col()
        .key("controls-scroll")
        .wFull()
        .grow(1)
        .minH(0)
        .scrollY()
        .child(controlsBody)
        .scrollBar(k)
}

// MARK: - Root Shell View

public func studioView(_ s: StudioState, _ cx: inout Cx<StudioState>) -> El<StudioState> {
    let dark = s.darkOverride ?? cx.getSystemDark()
    let accent = s.accent.color(dark: dark)
    let k = makeStudioKit(dark: dark, accent: accent)

    cx.captionColor(dark ? .white : .black)
    cx.titlebarHeight(44.0)
    let insets = cx.chromeInsets()

    // Titlebar with Windows/macOS caption insets preserved cleanly
    let titlebar: El<StudioState> = row()
        .key("studio-titlebar")
        .wFull()
        .h(44)
        .pl(max(14, insets.leading + 10))
        .pr(max(14, insets.trailing + 10))
        .gap(12)
        .itemsCenter()
        .bg(k.c.layer01)
        .borderSides(bottom: 1, color: k.c.borderMuted)
        .windowDrag()
        .child(
            row().gap(8).itemsCenter()
                .child(
                    row().size(22, 22).rounded(6).center().bg(accent)
                        .child(icon(StudioIcons.spark, size: 13).color(.white))
                )
                .child(text("Spark Studio").font(k.ty.uiMedium).color(k.c.textBase))
                .child(k.badge("Swift 6.4 · Rune", tone: .neutral))
        )
        .child(el().grow(1))
        .child(
            k.textInputField(
                key: "quick-filter",
                \StudioState.search,
                placeholder: "Filter workspace…",
                leadingIcon: KitIcons.search
            )
            .w(240)
            .noWindowDrag()
        )
        .child(
            k.button(
                key: "theme-toggle",
                dark ? "Light" : "Dark",
                variant: .ghost,
                size: .sm,
                leadingIcon: dark ? StudioIcons.sun : StudioIcons.moon
            ) { st, _ in
                st.darkOverride = !dark
            }
            .noWindowDrag()
        )

    // Sidebar Navigation
    let query = s.search.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    var navList: El<StudioState> = col().wFull().gap(4)
    for tab in StudioTab.allCases {
        if !query.isEmpty,
           !tab.title.lowercased().contains(query),
           !tab.subtitle.lowercased().contains(query) {
            continue
        }
        let isSelected = (s.tab == tab)
        navList = navList.child(
            row()
                .key("nav-\(tab.rawValue)")
                .wFull()
                .px(10)
                .py(9)
                .gap(10)
                .itemsCenter()
                .rounded(8)
                .bg(isSelected ? accent.alpha(dark ? 0.18 : 0.14) : Color.transparent)
                .hover(isSelected ? accent.alpha(dark ? 0.22 : 0.18) : k.c.surfaceHover)
                .border(1, isSelected ? accent.alpha(0.35) : Color.transparent)
                .role(.tab)
                .label(tab.title)
                .onClick { st, _ in
                    st.tab = tab
                }
                .child(icon(tab.icon, size: 16).color(isSelected ? accent : k.c.iconMuted))
                .child(
                    col().gap(1).grow(1).minW(0)
                        .child(text(tab.title).font(isSelected ? k.ty.uiMedium : k.ty.ui).color(k.c.textBase))
                        .child(text(tab.subtitle).font(TextStyle(size: 11, weight: 400, lineHeight: 14)).color(k.c.textFaint).ellipsis())
                )
        )
    }

    var accentDots: El<StudioState> = row().gap(8).itemsCenter()
    for preset in AccentPreset.allCases {
        let active = (s.accent == preset)
        let swatch = preset.color(dark: dark)
        accentDots = accentDots.child(
            el()
                .key("swatch-\(preset.rawValue)")
                .size(18, 18)
                .rounded(9)
                .bg(swatch)
                .border(active ? 2.5 : 1.0, active ? k.c.textBase : swatch.alpha(0.4))
                .role(.button)
                .label(preset.label)
                .onClick { st, _ in
                    st.accent = preset
                }
        )
    }

    let sidebar: El<StudioState> = col()
        .key("studio-sidebar")
        .w(236)
        .hFull()
        .p(12)
        .gap(14)
        .bg(k.c.layer01)
        .borderSides(right: 1, color: k.c.borderMuted)
        .child(text("WORKSPACES").font(TextStyle(size: 10.5, weight: 650, lineHeight: 14)).color(k.c.textFaint).px(8))
        .child(navList)
        .child(el().grow(1))
        .child(
            col().wFull().p(12).gap(10).rounded(10).bg(k.c.surfaceWeak).border(1, k.c.borderMuted)
                .child(text("Accent").font(k.ty.small).color(k.c.textMuted))
                .child(accentDots)
                .child(k.divider())
                .child(text(s.host.hostName).font(k.ty.small).color(k.c.textBase))
                .child(text(s.host.gpuName).font(TextStyle(size: 11, weight: 400, lineHeight: 14)).color(k.c.textFaint).ellipsis())
        )

    let activeBody: El<StudioState>
    switch s.tab {
    case .dashboard: activeBody = dashboardView(s, k, accent: accent)
    case .diff: activeBody = diffWorkspaceView(s, cx, k)
    case .markdown: activeBody = markdownWorkspaceView(s, k, accent: accent)
    case .controls: activeBody = controlsWorkspaceView(s, k, accent: accent)
    }

    let statusBar: El<StudioState> = row()
        .key("studio-statusbar")
        .wFull()
        .h(28)
        .px(14)
        .itemsCenter()
        .justifyBetween()
        .bg(k.c.layer01)
        .borderSides(top: 1, color: k.c.borderMuted)
        .child(
            row().gap(8).itemsCenter()
                .child(el().size(7, 7).rounded(3.5).bg(k.c.success.icon))
                .child(text(s.statusBanner ?? "Ready").font(TextStyle(size: 11, weight: 450, lineHeight: 14)).color(k.c.textMuted))
        )
        .child(
            text("\(s.host.backendLabel) · \(s.host.platformLabel) · Ctrl+1–4 switch tabs")
                .font(TextStyle(size: 11, weight: 450, lineHeight: 14))
                .color(k.c.textFaint)
        )

    return col()
        .key("spark-studio-root")
        .wFull()
        .hFull()
        .bg(k.c.bgBase)
        .child(titlebar)
        .child(row().wFull().grow(1).minH(0).child(sidebar).child(activeBody))
        .child(statusBar)
}

// MARK: - App Builder & Entry Point

public func makeSparkStudioApp() -> App<StudioState> {
    App(
        title: "Spark Studio",
        size: Vec2(1280, 820),
        minSize: Vec2(860, 560),
        state: StudioState(),
        view: studioView
    )
    .titlebar(Titlebar(height: 44))
    .onKey { state, ev, _ in
        if ev.mods.ctrl || ev.mods.logo {
            switch ev.key {
            case .text("1"): state.tab = .dashboard; return true
            case .text("2"): state.tab = .diff; return true
            case .text("3"): state.tab = .markdown; return true
            case .text("4"): state.tab = .controls; return true
            default: break
            }
        }
        return false
    }
    .scene("dashboard") { state, _ in
        state.tab = .dashboard
        state.darkOverride = true
        state.powerMode = .boost
    }
    .scene("diff") { state, _ in
        state.tab = .diff
        state.darkOverride = true
        state.diff.setMode(.split)
    }
    .scene("markdown") { state, _ in
        state.tab = .markdown
        state.darkOverride = true
    }
    .scene("controls") { state, _ in
        state.tab = .controls
        state.darkOverride = true
        state.accent = .cobalt
    }
    .scene("light") { state, _ in
        state.tab = .dashboard
        state.darkOverride = false
        state.accent = .cobalt
        state.powerMode = .balanced
    }
}

@main
enum SparkStudioMain {
    static func main() throws {
        try makeSparkStudioApp().run()
    }
}
