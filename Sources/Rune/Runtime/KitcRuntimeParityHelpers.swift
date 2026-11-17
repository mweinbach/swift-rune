import Foundation

extension Runtime {
    /// Presented bottom feather mask in points for the first growth row matching `key`, or `-1.0` when unclipped (`growth_rows.rs:42-44`).
    public func growthRowMask(forKey key: String) -> Float {
        guard let node = flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) else {
            return -1.0
        }
        let gKey = node.el.foldGlideSpec != nil ? "fold:\(node.path)" : "growth:\(node.path)"
        guard !slice2State.joinedRowsWithoutRevealMask.contains(node.nodeId), let entry = growthRows[gKey] else {
            return -1.0
        }
        let t = entry.track
        let overflows = entry.edge.overflow && (t.streaming || t.isPaced)
        guard entry.edge.clip && !overflows else {
            return -1.0
        }
        if t.h < t.target - 0.01 || t.mask > 0.01 || entry.withheld > 0.01 || t.isShuttingFold {
            return max(t.mask, min(entry.withheld, entry.edge.floor))
        }
        return -1.0
    }

    /// Presented height in points for a growth row matching `key`.
    public func growthPresentedHeight(forKey key: String) -> Float? {
        guard let node = flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) else {
            return nil
        }
        let gKey = node.el.foldGlideSpec != nil ? "fold:\(node.path)" : "growth:\(node.path)"
        return growthRows[gKey]?.track.h ?? node.targetRect.height
    }

    /// Unconstrained natural height in points recorded before growth clamping for `key`.
    public func growthNaturalHeight(forKey key: String) -> Float? {
        guard let node = flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) else {
            return nil
        }
        let gKey = node.el.foldGlideSpec != nil ? "fold:\(node.path)" : "growth:\(node.path)"
        return growthRows[gKey]?.naturalHeight ?? node.targetRect.height
    }

    /// Current growth target height (natural minus stream lag) in points for `key`.
    public func growthTargetHeight(forKey key: String) -> Float? {
        guard let node = flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) else {
            return nil
        }
        let gKey = node.el.foldGlideSpec != nil ? "fold:\(node.path)" : "growth:\(node.path)"
        return growthRows[gKey]?.track.target
    }

    /// Height currently withheld from the streaming row target for `key`.
    public func growthWithheld(forKey key: String) -> Float {
        guard let node = flatNodes.first(where: { selectsElementSelector(key, path: $0.path, key: $0.key) }) else {
            return 0
        }
        let gKey = node.el.foldGlideSpec != nil ? "fold:\(node.path)" : "growth:\(node.path)"
        return growthRows[gKey]?.withheld ?? 0
    }
}
