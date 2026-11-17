import RuneMotion

/// Effects and growth projections used by a minority of flattened nodes. An empty array is
/// shared across all ordinary nodes, and the single stored value has native copy-on-write.
internal struct FlatNodeCold {
    var growthRowProjectionY: Float = 0
    var growthContentShiftY: Float = 0
    var virtualWindowSnapOriginY: Float = 0
    var anchorAttachNorm: Vec2?
    var activeClipFades: [EdgeFadeSpec] = []
    var ownScrollFade: EdgeFadeSpec?
    var ownClipFade: EdgeFadeSpec?
    var elided: TextElision?

    var isEmpty: Bool {
        growthRowProjectionY == 0 && growthContentShiftY == 0 && virtualWindowSnapOriginY == 0 &&
            anchorAttachNorm == nil && activeClipFades.isEmpty && ownScrollFade == nil &&
            ownClipFade == nil && elided == nil
    }
}

/// Structural identities for one sibling group. Geometry, inherited styling, handlers and
/// animation specs are evaluated for the current pass even when these paths are reused.
internal struct FlatChildPaths {
    struct Address {
        let path: String
        let key: String?
        let id: NodeId
    }
    var addresses: [Address] = []
    var duplicates: [(index: Int, warning: String)] = []
    var firstChildSlot = 0

    init() {}

    init<State>(_ children: [El<State>], count: Int, parent: String) {
        guard count > 0 else { return }
        addresses.reserveCapacity(count)
        var seen: [String: Int] = [:]
        for i in 0..<count {
            let raw = children[i].storageKeyId
            var key = raw
            if let raw {
                let previous = seen[raw, default: 0]
                seen[raw] = previous + 1
                if previous != 0 {
                    let renamed = "\(raw)#dup\(previous)"
                    duplicates.append((i, "Duplicate sibling key '\(raw)' renamed to '\(renamed)' under \(parent)"))
                    key = renamed
                }
            }
            let path = key.map { "\(parent)/@\($0)" } ?? "\(parent)/\(i)"
            let id = children[i].layoutAnim?.travel == .screen ? key.map { NodeId.hash("screen:@" + $0) } : nil
            addresses.append(Address(path: path, key: key, id: id ?? NodeId.hash(path)))
        }
    }
}

/// The root path and memo owner establish all descendant structural keys. Slots are filled
/// iteratively during the real tree walk, including arbitrarily deep memo trees.
internal final class FlatMemoPaths<State> {
    let owner: MemoLayoutChildren<State>
    var span: MemoFlatSpan<State>?
    var allowsSpan = true
    var replayedNodes = 0
    private var slots: [FlatChildPaths?] = [nil]

    init(_ owner: MemoLayoutChildren<State>) { self.owner = owner }

    func children(at slot: Int, source: [El<State>], parent: String) -> FlatChildPaths {
        if let cached = slots[slot] { return cached }
        var paths = FlatChildPaths(source, count: source.count, parent: parent)
        paths.firstChildSlot = slots.count
        slots.append(contentsOf: repeatElement(nil, count: source.count))
        slots[slot] = paths
        return paths
    }
}
