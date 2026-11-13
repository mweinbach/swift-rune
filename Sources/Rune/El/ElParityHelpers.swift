import Foundation
import RuneMotion

// MARK: - El.preserveFocusOnPress (`crates/rune/src/el/focus.rs:143`)

public extension El {
    /// A press on this element or its unfocusable descendants leaves the currently focused
    /// field focused instead of blurring it (`El::preserve_focus_on_press`).
    func preserveFocusOnPress(_ enabled: Bool = true) -> Self {
        var copy = self
        copy.runtimeExtras[Self.preserveFocusOnPressExtraKey] = enabled
        return copy
    }
}

internal extension El {
    static var preserveFocusOnPressExtraKey: String { "rune.preserveFocusOnPress" }
    static var clipToContentExtraKey: String { "rune.clipToContent" }

    var preservesFocusOnPress: Bool {
        (runtimeExtras[Self.preserveFocusOnPressExtraKey] as? Bool) ?? false
    }

    var isClipToContent: Bool {
        (runtimeExtras[Self.clipToContentExtraKey] as? Bool) ?? false
    }

    mutating func applyParityClip(_ apply: (inout El<State>) -> Void) {
        if isClipToContent && !children.isEmpty {
            apply(&children[0])
        } else {
            apply(&self)
        }
    }
}

internal extension Runtime {
    /// Whether any ancestor (through focus boundaries) preserves focus when pressed
    /// (`preservesFocusOnPress` or `keepsTextSelection`, mirroring `Runtime::press_keeps_focus`).
    func preservesFocusOnPressInChain(_ node: FlatNode?) -> Bool {
        var cur = node
        while let n = cur {
            if n.el.preservesFocusOnPress || n.el.preservesTextSelection {
                return true
            }
            cur = n.parentIndex.map { flatNodes[$0] }
        }
        return false
    }

    /// Whether `node` lies inside a `TextInput` / `editLens` / `.textInput` subtree (`in_textbox`).
    func isInsideEditLensSubtree(_ node: FlatNode?) -> Bool {
        var cur = node?.parentIndex.map { flatNodes[$0] }
        while let n = cur {
            if n.el.handlers.editLens != nil || n.el.role == .textInput {
                return true
            }
            cur = n.parentIndex.map { flatNodes[$0] }
        }
        return false
    }
}

// MARK: - El.wrapScrollArea & LayoutStyle.takeBoxPlacement (`el/layout.rs:723`, `taffy setters.rs:333`)

public extension LayoutStyle {
    /// Transfers outer box placement properties (`width`, `height`, `min*`, `max*`, `flex*`,
    /// `margin`, `alignSelf`, `aspectRatio`, `isAbsolute`, pins, `gridItem`, `displayNone`) to a
    /// wrapper column and resets this style to fill that wrapper (`flex: 1 1 auto`, `min: 0`).
    mutating func takeBoxPlacement() -> LayoutStyle {
        var outer = LayoutStyle(direction: .column)
        outer.displayNone = displayNone
        outer.flexGrow = flexGrow
        outer.flexShrink = flexShrink
        outer.flexBasis = flexBasis
        outer.isAbsolute = isAbsolute
        outer.pinLeft = pinLeft
        outer.pinTop = pinTop
        outer.pinRight = pinRight
        outer.pinBottom = pinBottom
        outer.width = width
        outer.height = height
        outer.minWidth = minWidth
        outer.minHeight = minHeight
        outer.maxWidth = maxWidth
        outer.maxHeight = maxHeight
        outer.margin = margin
        outer.alignSelf = alignSelf
        outer.aspectRatio = aspectRatio
        outer.gridItem = gridItem
        outer.clipOverflow = clipOverflow || !scrollAxes.isEmpty

        if displayNone {
            displayNone = false
        }
        isAbsolute = false
        pinLeft = nil
        pinTop = nil
        pinRight = nil
        pinBottom = nil
        width = .auto
        height = .auto
        minWidth = .points(0)
        minHeight = .points(0)
        maxWidth = .auto
        maxHeight = .auto
        margin = .all(0)
        flexGrow = 1.0
        flexShrink = 1.0
        flexBasis = .auto
        alignSelf = nil
        aspectRatio = nil
        gridItem = nil
        return outer
    }
}

public extension El {
    /// Wraps this scroll viewport in a sibling-ready scroll area container, moving box placement,
    /// `aspectFit`, `anchor` (`above`), and `transition` to `outer` and setting `clipToContent`
    /// (`crates/rune/src/el/layout.rs:723`).
    func wrapScrollArea(
        file: String = #fileID,
        line: UInt = #line,
        column: UInt = #column
    ) -> (area: String, key: String, outer: El<State>, viewport: El<State>) {
        var inner = self
        let resolvedKey: String
        if let existing = inner.keyId {
            resolvedKey = existing
        } else {
            var hasher = Hasher()
            hasher.combine(file)
            hasher.combine(line)
            hasher.combine(column)
            let h = UInt64(bitPattern: Int64(hasher.finalize()))
            let folded = UInt32(truncatingIfNeeded: h ^ (h >> 32))
            let generated = String(format: "scroll-%08x", folded)
            inner.keyId = generated
            resolvedKey = generated
        }
        let area = "\(resolvedKey)-scroll-area"
        var outer = El<State>(direction: .column).key(area)
        outer.layout = inner.layout.takeBoxPlacement()
        if let fit = inner.layout.aspectFit {
            outer.layout.aspectFit = fit
            inner.layout.aspectFit = nil
        }
        if let anchor = inner.anchor {
            outer.anchor = anchor
            inner.anchor = nil
        }
        if let tr = inner.transition {
            outer.transition = tr
            inner.transition = nil
        }
        outer.runtimeExtras[Self.clipToContentExtraKey] = true
        return (area, resolvedKey, outer, inner)
    }
}

// MARK: - El.animateLayout Row Propagation & Growth Mount Suppression (`el/motion.rs:168`, `commit/flatten.rs:436`, `commit/apply.rs:364`)

/// Whether a flattened node sits in a snapping growth row, an animated horizontal row, or free
/// layout (`crates/rune/src/runtime/types.rs:6`).
public enum ParityRowLayout: Sendable, Equatable {
    case free
    case snaps
    case horizontal
}

public enum ParityLayoutAnimation {
    /// Computes `(selfRowLayout, childRowLayout)` when descending into `el` during tree flattening
    /// (`crates/rune/src/runtime/commit/flatten.rs:436-441, 570-573`).
    public static func resolveRowLayout(
        parentInRow: ParityRowLayout,
        hasAbove: Bool,
        hasAnimateLayout: Bool,
        isStackContainer: Bool
    ) -> (selfInRow: ParityRowLayout, childInRow: ParityRowLayout) {
        let selfInRow: ParityRowLayout
        if hasAbove && (hasAnimateLayout || parentInRow == .horizontal) {
            selfInRow = .free
        } else if hasAnimateLayout && parentInRow == .snaps {
            selfInRow = .horizontal
        } else {
            selfInRow = parentInRow
        }

        let childInRow: ParityRowLayout
        switch selfInRow {
        case .free where isStackContainer:
            childInRow = hasAnimateLayout ? .horizontal : .snaps
        default:
            childInRow = selfInRow
        }
        return (selfInRow, childInRow)
    }

    /// Resolves the `LayoutAnim` for a node inside `inRow`, snapping vertical placement inside
    /// `.horizontal` rows (`LayoutAnim(x: spring, y: .instant)`) and snapping `.snaps` rows
    /// (`crates/rune/src/runtime/commit/apply.rs:434-462`).
    public static func resolveNodeLayoutAnim(
        inRow: ParityRowLayout,
        explicitLayoutAnim: LayoutAnim?,
        nodeSpring: Spring,
        parentHasGrowth: Bool,
        isInstant: Bool,
        isSameSceneFrame: Bool,
        commitLands: Bool
    ) -> LayoutAnim {
        if isInstant || commitLands || isSameSceneFrame {
            return .instant
        }
        let base = explicitLayoutAnim ?? LayoutAnim(spring: nodeSpring)
        let stackRow = parentHasGrowth || (inRow == .horizontal)
        if stackRow {
            return LayoutAnim(x: base.x, y: .instant)
        }
        if inRow == .snaps {
            return .instant
        }
        return base
    }

    /// True when a newly mounted child inside a growth or animated horizontal row rides its row
    /// immediately at `opacity = 1.0` instead of playing an enter fade (`apply.rs:402-407`).
    public static func shouldMountAtInitialOpacity(
        inRow: ParityRowLayout,
        parentHasGrowth: Bool,
        parentNewlyMounted: Bool,
        hasExplicitInsertion: Bool,
        reducedMotion: Bool
    ) -> Bool {
        let rowLike = (inRow == .snaps) || parentHasGrowth
        let ridesRow = rowLike || (inRow == .horizontal && parentNewlyMounted)
        return ridesRow && !hasExplicitInsertion && !reducedMotion
    }
}
