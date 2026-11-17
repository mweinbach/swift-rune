import RuneMotion

extension Runtime {
    /// Surviving children can move to different horizontal positions when their parent
    /// rewraps. Anchor to a subtree that was drawn in the previous frame.
    func previouslyDrawnLandingSubtrees(_ oldNodes: [FlatNode]) -> Set<NodeId> {
        var drawn = Set<NodeId>()
        for node in oldNodes where kitHooks.unseenPresence.frameById[node.nodeId]?.visible == true {
            drawn.insert(node.nodeId)
        }
        for node in oldNodes.reversed() where drawn.contains(node.nodeId) {
            if let parent = node.parentIndex {
                drawn.insert(oldNodes[parent].nodeId)
            }
        }
        return drawn
    }
}
