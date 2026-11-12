import Foundation

/// A cache bounded by bytes, not entries (`rune_kit::budget::Budget`).
/// Entries used in the last two commit generations are retained; past the byte limit,
/// the least recently used older entries are evicted down to 3/4 of the limit.
public final class BudgetCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private struct Slot {
        var value: Value
        var bytes: Int
        var used: UInt64
        var commit: UInt64
    }

    private let lock = NSLock()
    private var map: [Key: Slot] = [:]
    private var currentBytes: Int = 0
    private let limit: Int
    private var clock: UInt64 = 0
    private var generation: UInt64 = 0

    public init(limitBytes: Int) {
        self.limit = max(0, limitBytes)
    }

    /// Advances the commit generation counter (call once per frame/commit).
    public func advanceCommit() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
    }

    /// Current commit generation.
    public var commitGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    /// Estimated bytes currently held in the cache.
    public var bytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return currentBytes
    }

    /// Number of entries currently held in the cache.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return map.count
    }

    /// Looks up `key`, updating its LRU timestamp and commit generation.
    public func get(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard var slot = map[key] else { return nil }
        clock &+= 1
        slot.used = clock
        slot.commit = generation
        map[key] = slot
        return slot.value
    }

    /// Looks up `key` without counting it as used.
    public func peek(_ key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return map[key]?.value
    }

    /// Drops `key`, returning whether it was present.
    @discardableResult
    public func remove(_ key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let old = map.removeValue(forKey: key) else { return false }
        currentBytes = max(0, currentBytes - old.bytes)
        return true
    }

    /// Whether `key` was used in the current commit generation.
    public func usedNow(_ key: Key) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation > 0, let slot = map[key] else { return false }
        return slot.commit == generation
    }

    /// Inserts or replaces `key` with `value` and estimated byte cost `bytes`.
    public func insert(_ key: Key, value: Value, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        let cost = max(0, bytes)
        clock &+= 1
        let slot = Slot(value: value, bytes: cost, used: clock, commit: generation)
        if let old = map.updateValue(slot, forKey: key) {
            currentBytes = max(0, currentBytes - old.bytes)
        }
        currentBytes += cost
        if currentBytes > limit {
            evictLocked()
        }
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        map.removeAll()
        currentBytes = 0
    }

    private func evictLocked() {
        let now = generation
        func isKept(_ slot: Slot) -> Bool {
            now > 0 && slot.commit + 1 >= now
        }

        let oldSlots = map.values
            .filter { !isKept($0) }
            .map { ($0.used, $0.bytes) }
            .sorted { $0.0 < $1.0 }

        let target = (limit / 4) * 3
        var bytes = currentBytes
        var lastEvictedStamp: UInt64?

        for (used, b) in oldSlots {
            if bytes <= target { break }
            bytes = max(0, bytes - b)
            lastEvictedStamp = used
        }

        guard let cutoff = lastEvictedStamp else { return }
        map = map.filter { _, slot in
            isKept(slot) || slot.used > cutoff
        }
        currentBytes = bytes
    }
}
