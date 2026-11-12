import Foundation

/// One module's contribution to a distributed registry list.
///
/// Mirrors `rune_register::Part<T>` in `crates/rune-register`.
public struct RegistryPart<Item: Sendable>: Sendable {
    /// Module or file identifier used to order parts deterministically.
    public let module: String
    /// Items contributed by this module in declaration order.
    public let items: [Item]

    public init(module: String, items: [Item]) {
        self.module = module
        self.items = items
    }
}

/// Thread-safe distributed item registry allowing decentralized modules to register
/// items (scenes, stories, knob groups, etc.) without editing a central list.
///
/// Mirrors `rune_register::slice!` + `rune_register::register!` + `rune_register::collect`.
public final class DistributedRegistry<Item: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RegistryPart<Item>] = []

    public init() {}

    /// Registers a part of items under `module` (defaults to `#fileID`).
    public func register(module: String = #fileID, _ items: [Item]) {
        let part = RegistryPart(module: module, items: items)
        lock.lock()
        storage.append(part)
        lock.unlock()
    }

    /// Variadic convenience for registering items under `module`.
    public func register(module: String = #fileID, _ items: Item...) {
        register(module: module, items)
    }

    /// Returns a snapshot of all registered parts.
    public func parts() -> [RegistryPart<Item>] {
        lock.lock()
        let copy = storage
        lock.unlock()
        return copy
    }

    /// Collects all registered items sorted by `module`, preserving each part's item order.
    public func collect() -> [Item] {
        RuneRegister.collect(parts())
    }

    /// Removes all registered parts from this registry.
    public func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}

/// Collection and merge utilities matching `crates/rune-register`.
public enum RuneRegister {
    /// Collects every part's items: parts ordered by `module`, each part's items in its own order.
    public static func collect<Item: Sendable>(_ parts: [RegistryPart<Item>]) -> [Item] {
        let sorted = parts.sorted { $0.module < $1.module }
        return sorted.flatMap(\.items)
    }

    /// Folds `more` into `own` by `name`: an item matching an existing entry in `own` (excluding
    /// `own`'s last footer item) joins it via `join`; any other item is appended before `own`'s
    /// last item (the list's footer).
    public static func merge<Item>(
        _ own: [Item],
        with more: [Item],
        name: (Item) -> String,
        join: (inout Item, Item) -> Void
    ) -> [Item] {
        let last = own.last
        var out = own.isEmpty ? [] : Array(own.dropLast())
        for item in more {
            let itemName = name(item)
            if let idx = out.firstIndex(where: { name($0) == itemName }) {
                join(&out[idx], item)
            } else {
                out.append(item)
            }
        }
        if let last {
            out.append(last)
        }
        return out
    }
}
