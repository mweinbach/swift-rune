import Foundation

/// Per-node exiting-subtree bitmask cached for a single `(commitGeneration, flatNodes.count)` frame
/// (`runtime/paint/exit_mask.rs`).
public enum ExitMaskState: Sendable {
    case forgotten(exiting: [Bool])
    case fresh(exiting: [Bool], commit: UInt64)

    public mutating func forget() {
        let buffer: [Bool]
        switch self {
        case .forgotten(let exiting), .fresh(let exiting, _):
            buffer = exiting
        }
        self = .forgotten(exiting: buffer)
    }

    public func get(index: Int, count: Int, commit: UInt64) -> Bool? {
        switch self {
        case .fresh(let exiting, let c) where c == commit && exiting.count == count && index >= 0 && index < exiting.count:
            return exiting[index]
        case .forgotten, .fresh:
            return nil
        }
    }

    fileprivate mutating func takeBuffer() -> [Bool] {
        let buffer: [Bool]
        switch self {
        case .forgotten(let exiting), .fresh(let exiting, _):
            buffer = exiting
        }
        self = .forgotten(exiting: [])
        return buffer
    }
}

private final class ExitMaskSideTable: @unchecked Sendable {
    static let shared = ExitMaskSideTable()
    private let lock = NSLock()
    private var states: [ObjectIdentifier: ExitMaskState] = [:]

    func state(for id: ObjectIdentifier) -> ExitMaskState {
        lock.lock()
        defer { lock.unlock() }
        return states[id] ?? .forgotten(exiting: [])
    }

    func setState(_ state: ExitMaskState, for id: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        states[id] = state
    }
}

extension Runtime {
    private func isNodeExiting(_ id: NodeId) -> Bool {
        if case .exiting = scene.phase(id) {
            return true
        }
        return false
    }

    /// Populates the per-node exiting-subtree bitmask for an explicit render node slice (`paint/exit_mask.rs`).
    @discardableResult
    internal func beginExitMask(nodes: [FlatNode]) -> Int {
        let key = ObjectIdentifier(self)
        var state = ExitMaskSideTable.shared.state(for: key)
        var exiting = state.takeBuffer()
        exiting.removeAll(keepingCapacity: true)
        exiting.reserveCapacity(nodes.count)

        // Map mounted vs exiting snapshot node indices separately so recycled indices never alias.
        var mountedByIndex: [Int: Int] = [:]
        var exitingSnapByIndex: [Int: Int] = [:]
        var nodeSelfExiting: [Bool] = []
        var nodeIsSnap: [Bool] = []
        nodeSelfExiting.reserveCapacity(nodes.count)
        nodeIsSnap.reserveCapacity(nodes.count)
        for (pos, n) in nodes.enumerated() {
            let selfExit = isNodeExiting(n.nodeId)
            let isSnap = selfExit || (exitingSnapshots[n.nodeId] != nil && nodeById[n.nodeId] == nil)
            nodeSelfExiting.append(selfExit)
            nodeIsSnap.append(isSnap)
            if isSnap {
                exitingSnapByIndex[n.index] = pos
            } else {
                mountedByIndex[n.index] = pos
            }
        }

        for i in 0..<nodes.count {
            var curPos: Int? = i
            var anyExiting = false
            var hops = 0
            while let pos = curPos, hops <= nodes.count {
                if nodeSelfExiting[pos] {
                    anyExiting = true
                    break
                }
                let node = nodes[pos]
                guard let parentIdx = node.parentIndex else { break }
                if nodeIsSnap[pos] {
                    curPos = exitingSnapByIndex[parentIdx] ?? mountedByIndex[parentIdx]
                } else {
                    curPos = mountedByIndex[parentIdx]
                }
                hops += 1
            }
            exiting.append(anyExiting)
        }
        ExitMaskSideTable.shared.setState(.fresh(exiting: exiting, commit: commitGeneration()), for: key)
        return nodes.count
    }

    /// Populates the per-node exiting-subtree bitmask for mounted `flatNodes` plus active exiting snapshots.
    @discardableResult
    public func beginExitMask() -> Int {
        var nodes = flatNodes
        let mountedIds = Set(flatNodes.map(\.nodeId))
        let exitingSnaps = exitingSnapshots.values
            .filter { !mountedIds.contains($0.nodeId) && isNodeExiting($0.nodeId) }
            .sorted { $0.index < $1.index }
        nodes.append(contentsOf: exitingSnaps)
        return beginExitMask(nodes: nodes)
    }

    /// Invalidates the exiting-subtree bitmask after paint/reporting so later phase changes cannot read stale flags.
    public func endExitMask() {
        let key = ObjectIdentifier(self)
        var state = ExitMaskSideTable.shared.state(for: key)
        state.forget()
        ExitMaskSideTable.shared.setState(state, for: key)
    }

    /// Returns whether node `index` or any of its ancestors is currently exiting.
    public func subtreeExiting(_ index: Int) -> Bool {
        let state = ExitMaskSideTable.shared.state(for: ObjectIdentifier(self))
        if case .fresh(let exiting, let commit) = state,
           commit == commitGeneration(),
           index >= 0,
           index < exiting.count {
            return exiting[index]
        }
        guard index >= 0, index < flatNodes.count else { return false }
        var cur: Int? = index
        while let i = cur, i >= 0, i < flatNodes.count {
            if isNodeExiting(flatNodes[i].nodeId) {
                return true
            }
            cur = flatNodes[i].parentIndex
        }
        return false
    }
}
