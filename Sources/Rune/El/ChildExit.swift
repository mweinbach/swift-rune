import Foundation
import RuneMotion

/// Overrides the exit transition used when direct children are removed while this container stays
/// mounted (`crates/rune/src/el/child_exit.rs`).
public extension El {
    /// Sets the exit transition applied to direct children when removed in a later commit, unless
    /// the commit is instant (`tx.settle()`), the node isn't exiting, or the parent itself unmounts.
    ///
    /// - Hook for `Runtime.commitTree`: before removing an exiting child `oldId` whose parent stays
    ///   mounted with `parentEl`, call `ChildExitHook.apply(parentEl: parentEl, childId: oldId, to: &scene)`.
    func childExit(_ transition: Transition) -> Self {
        var copy = self
        copy.runtimeExtras[Self.childExitExtraKey] = transition
        return copy
    }
}

internal extension El {
    static var childExitExtraKey: String { "rune.childExit" }

    var childExitTransition: Transition? {
        runtimeExtras[Self.childExitExtraKey] as? Transition
    }
}

internal enum ChildExitHook {
    /// Applies the parent's `childExit` transition override to an exiting direct child before
    /// `scene.remove(childId)` (`commit/apply.rs:755-757`).
    static func apply<State>(parentEl: El<State>?, childId: NodeId, to scene: inout Scene) {
        if let t = parentEl?.childExitTransition {
            scene.setTransition(childId, t)
        }
    }
}
