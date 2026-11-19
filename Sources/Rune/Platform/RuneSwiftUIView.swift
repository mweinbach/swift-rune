#if canImport(SwiftUI) && (os(macOS) || (canImport(UIKit) && !os(watchOS)))
import SwiftUI

/// Embeds a Rune UI hierarchy as a native SwiftUI `View` on macOS, iOS, iPadOS, tvOS, and visionOS.
///
/// The underlying `Runtime<State>` is created once when the SwiftUI view mounts and preserved
/// across SwiftUI body re-evaluations so springs, scroll offsets, focus, and IME state stay intact.
/// Pass `onUpdate` to synchronize external SwiftUI state into the Rune runtime when SwiftUI updates.
public struct RuneView<State>: View {
    private enum Source {
        case spec(AppSpec<State>)
        case app(App<State>)
    }

    private let source: Source
    private let onUpdate: (@MainActor (Runtime<State>) -> Void)?

    public init(
        _ spec: AppSpec<State>,
        onUpdate: (@MainActor (Runtime<State>) -> Void)? = nil
    ) {
        self.source = .spec(spec)
        self.onUpdate = onUpdate
    }

    public init(
        _ app: App<State>,
        onUpdate: (@MainActor (Runtime<State>) -> Void)? = nil
    ) {
        self.source = .app(app)
        self.onUpdate = onUpdate
    }

    public init(
        title: String = "Rune",
        size: Vec2 = Vec2(400, 300),
        state: State,
        view: @escaping (State, inout Cx<State>) -> El<State>,
        onUpdate: (@MainActor (Runtime<State>) -> Void)? = nil
    ) {
        self.source = .spec(AppSpec(title: title, size: size, state: state, view: view))
        self.onUpdate = onUpdate
    }

    public var body: some View {
        #if os(macOS)
        RuneMacRepresentable(source: source, onUpdate: onUpdate)
        #else
        RuneUIKitRepresentable(source: source, onUpdate: onUpdate)
        #endif
    }

    #if os(macOS)
    private struct RuneMacRepresentable: NSViewRepresentable {
        let source: Source
        let onUpdate: (@MainActor (Runtime<State>) -> Void)?

        final class Coordinator {
            var runeView: RuneMacView<State>?
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView {
            do {
                let view: RuneMacView<State>
                switch source {
                case .spec(let spec): view = try MacOSApp.makeView(spec)
                case .app(let app): view = try MacOSApp.makeView(app)
                }
                context.coordinator.runeView = view
                return view
            } catch {
                RuneStandardIO.error("RuneView failed to initialize Metal host: \(error)\n")
                return NSView(frame: .zero)
            }
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            guard let runeView = context.coordinator.runeView ?? (nsView as? RuneMacView<State>) else { return }
            if let onUpdate {
                onUpdate(runeView.runtime)
                runeView.requestRender()
            }
        }
    }
    #else
    private struct RuneUIKitRepresentable: UIViewControllerRepresentable {
        let source: Source
        let onUpdate: (@MainActor (Runtime<State>) -> Void)?

        final class Coordinator {
            var controller: RuneIOSViewController<State>?
        }

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeUIViewController(context: Context) -> UIViewController {
            do {
                let controller: RuneIOSViewController<State>
                switch source {
                case .spec(let spec): controller = try IOSApp.makeViewController(spec)
                case .app(let app): controller = try IOSApp.makeViewController(app)
                }
                context.coordinator.controller = controller
                return controller
            } catch {
                RuneStandardIO.error("RuneView failed to initialize UIKit host: \(error)\n")
                return UIViewController()
            }
        }

        func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
            guard let controller = context.coordinator.controller ?? (uiViewController as? RuneIOSViewController<State>) else { return }
            if let onUpdate {
                onUpdate(controller.runeView.runtime)
                controller.runeView.renderTick()
            }
        }
    }
    #endif
}
#endif
