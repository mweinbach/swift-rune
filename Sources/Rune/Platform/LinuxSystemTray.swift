#if os(Linux)
import CRuneDesktopServices
import Foundation

final class LinuxSystemTray {
    private let handle: OpaquePointer
    private var currentSpec: TraySpec

    private final class Observer {
        let send: @Sendable (TrayEvent) -> Void
        init(_ send: @escaping @Sendable (TrayEvent) -> Void) { self.send = send }
    }

    init(_ spec: TraySpec, onEvent: @escaping @Sendable (TrayEvent) -> Void) throws {
        let model = try Self.model(spec)
        let observer = Unmanaged.passRetained(Observer(onEvent)).toOpaque()
        var message = [CChar](repeating: 0, count: 512)
        guard let handle = rune_linux_tray_open(model, observer, { context, item, token in
            guard let context else { return }
            let event: TrayEvent = item.map { .menu(String(cString: $0)) }
                ?? .activate(token: token.map { String(cString: $0) })
            Unmanaged<Observer>.fromOpaque(context).takeUnretainedValue().send(event)
        }, { context in
            if let context { Unmanaged<Observer>.fromOpaque(context).release() }
        }, &message, message.count) else {
            let reason = message.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            throw TrayError.backend(reason)
        }
        self.handle = handle
        self.currentSpec = spec
    }

    deinit { rune_linux_tray_close(handle) }

    func update(_ spec: TraySpec) throws {
        if spec.tooltip != currentSpec.tooltip {
            var previous = currentSpec
            previous.tooltip = spec.tooltip
            if spec == previous {
                guard !spec.tooltip.utf8.contains(0) else {
                    throw TrayError.backend("A tray string contains a NUL character")
                }
                rune_linux_tray_set_tooltip(handle, spec.tooltip)
                currentSpec = spec
                return
            }
        }
        let keepPixels = currentSpec.icon == spec.icon
        rune_linux_tray_update(handle, try Self.model(spec, keepPixels: keepPixels), keepPixels ? 1 : 0)
        currentSpec = spec
    }

    private static func model(_ spec: TraySpec, keepPixels: Bool = false) throws -> OpaquePointer {
        let icon = try spec.icon?.validated()
        // NUL cannot occur in a D-Bus STRING. Reject it before crossing the C string boundary.
        func valid(_ text: String) -> Bool { !text.utf8.contains(0) }
        guard valid(spec.id), valid(spec.title), valid(spec.tooltip), valid(spec.iconName),
              spec.menu.allSatisfy({ item in
                  if case let .action(id, label, _) = item { return valid(id) && valid(label) }
                  return true
              }) else { throw TrayError.backend("A tray string contains a NUL character") }

        let model: OpaquePointer?
        if let icon, !keepPixels {
            model = icon.rgba.withUnsafeBytes {
                rune_linux_tray_spec(spec.id, spec.title, spec.tooltip, spec.iconName,
                                     $0.bindMemory(to: UInt8.self).baseAddress, icon.width, icon.height)
            }
        } else {
            model = rune_linux_tray_spec(spec.id, spec.title, spec.tooltip, spec.iconName, nil, 0, 0)
        }
        guard let model else { throw TrayError.backend("Could not create the StatusNotifierItem") }
        for item in spec.menu {
            switch item {
            case .separator: rune_linux_tray_item(model, nil, nil, 0)
            case let .action(id, label, enabled): rune_linux_tray_item(model, id, label, enabled ? 1 : 0)
            }
        }
        return model
    }
}
#endif
