import Foundation
import RuneMotion

/// Snapshot of a single committed node used by `Runtime.checkLiveOnly(_:)`
/// (`crates/rune/src/runtime/motion/live_check.rs`).
internal struct LiveOnlyNodePrint {
    var path: String
    var targetRect: MotionRect
    var fill: Color?
    var borderColor: Color
    var borderWidth: Float
    var opacity: Float
    var corners: Corners
    var text: String?
    var isLiveText: Bool = false
    var isRedacted: Bool = false
    var textColor: Color?
}

/// First structural or visual property difference observed between two commits.
internal struct LiveOnlyDifference: Equatable {
    var path: String
    var what: String
    var values: (String, String)?

    static func == (lhs: LiveOnlyDifference, rhs: LiveOnlyDifference) -> Bool {
        lhs.path == rhs.path && lhs.what == rhs.what && lhs.values?.0 == rhs.values?.0 && lhs.values?.1 == rhs.values?.1
    }
}

/// Full tree snapshot captured before a debug `Tx.liveOnly` check commit.
internal struct LiveOnlyViewPrint {
    var nodes: [LiveOnlyNodePrint]

    func firstDifference(against after: LiveOnlyViewPrint) -> LiveOnlyDifference? {
        let a = nodes
        let b = after.nodes
        func has(_ list: [LiveOnlyNodePrint], path: String) -> Bool {
            list.contains { $0.path == path }
        }
        var i = 0
        var j = 0
        while i < a.count && j < b.count {
            let x = a[i]
            let y = b[j]
            if x.path == y.path {
                if let diff = x.difference(against: y) {
                    return diff
                }
                i += 1
                j += 1
            } else if !has(b, path: x.path) {
                return LiveOnlyDifference(path: x.path, what: "removed element", values: nil)
            } else if !has(a, path: y.path) {
                return LiveOnlyDifference(path: y.path, what: "added element", values: nil)
            } else {
                return LiveOnlyDifference(path: x.path, what: "order", values: nil)
            }
        }
        if i < a.count {
            return LiveOnlyDifference(path: a[i].path, what: "removed element", values: nil)
        }
        if j < b.count {
            return LiveOnlyDifference(path: b[j].path, what: "added element", values: nil)
        }
        return nil
    }
}

private extension LiveOnlyNodePrint {
    static func bitsEqual(_ lhs: [Float], _ rhs: [Float]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for idx in lhs.indices where lhs[idx].bitPattern != rhs[idx].bitPattern {
            return false
        }
        return true
    }

    static func colorBits(_ c: Color?) -> [Float] {
        guard let c else { return [] }
        return [c.r, c.g, c.b, c.a]
    }

    static func formatColor(_ c: Color?) -> String {
        guard let c else { return "(live)" }
        let byte = { (x: Float) -> Int in
            let enc = MotionColor.srgbEncode(max(0.0, min(1.0, x)))
            return Int((max(0.0, min(1.0, enc)) * 255.0).rounded())
        }
        let alphaByte = Int((max(0.0, min(1.0, c.a)) * 255.0).rounded())
        return String(format: "#%02x%02x%02x%02x", byte(c.r), byte(c.g), byte(c.b), alphaByte)
    }

    static func formatPoints(_ xs: [Float]) -> String {
        "[" + xs.map { String(format: "%.1f", $0) }.joined(separator: ", ") + "]"
    }

    static func snippet(_ s: String?, isLive: Bool, isRedacted: Bool) -> String {
        guard let s else { return "no text" }
        if isRedacted { return "[redacted]" }
        if isLive { return "(live)" }
        let maxChars = 40
        if s.count > maxChars {
            return String(reflecting: String(s.prefix(maxChars)) + "…")
        }
        return String(reflecting: s)
    }

    func difference(against now: LiveOnlyNodePrint) -> LiveOnlyDifference? {
        let aRect = [targetRect.x, targetRect.y, targetRect.width, targetRect.height]
        let bRect = [now.targetRect.x, now.targetRect.y, now.targetRect.width, now.targetRect.height]
        if !Self.bitsEqual(aRect, bRect) {
            return LiveOnlyDifference(
                path: path,
                what: "layout rect",
                values: (Self.formatPoints(aRect), Self.formatPoints(bRect))
            )
        }
        if !Self.bitsEqual(Self.colorBits(fill), Self.colorBits(now.fill)) {
            return LiveOnlyDifference(
                path: path,
                what: "fill",
                values: (Self.formatColor(fill), Self.formatColor(now.fill))
            )
        }
        let aBorder = Self.colorBits(borderColor) + [borderWidth]
        let bBorder = Self.colorBits(now.borderColor) + [now.borderWidth]
        if !Self.bitsEqual(aBorder, bBorder) {
            return LiveOnlyDifference(
                path: path,
                what: "border",
                values: (
                    "\(Self.formatColor(borderColor)) \(String(format: "%.1f", borderWidth))pt",
                    "\(Self.formatColor(now.borderColor)) \(String(format: "%.1f", now.borderWidth))pt"
                )
            )
        }
        if opacity.bitPattern != now.opacity.bitPattern {
            return LiveOnlyDifference(
                path: path,
                what: "opacity",
                values: (String(format: "%.3f", opacity), String(format: "%.3f", now.opacity))
            )
        }
        let aRad = [corners.topLeft, corners.topRight, corners.bottomRight, corners.bottomLeft]
        let bRad = [now.corners.topLeft, now.corners.topRight, now.corners.bottomRight, now.corners.bottomLeft]
        if !Self.bitsEqual(aRad, bRad) {
            return LiveOnlyDifference(
                path: path,
                what: "radius",
                values: (Self.formatPoints(aRad), Self.formatPoints(bRad))
            )
        }
        let contentDiffers = (text == nil) != (now.text == nil)
            || (!isLiveText && !now.isLiveText && text != now.text)
            || (isLiveText != now.isLiveText)
        if contentDiffers {
            return LiveOnlyDifference(
                path: path,
                what: "text",
                values: (
                    Self.snippet(text, isLive: isLiveText, isRedacted: isRedacted),
                    Self.snippet(now.text, isLive: now.isLiveText, isRedacted: now.isRedacted)
                )
            )
        }
        if !Self.bitsEqual(Self.colorBits(textColor), Self.colorBits(now.textColor)) {
            return LiveOnlyDifference(
                path: path,
                what: "text color",
                values: (Self.formatColor(textColor), Self.formatColor(now.textColor))
            )
        }
        return nil
    }
}

/// Debug check interval after the last commit (`LIVE_ONLY_CHECK = 0.25s`).
private let liveOnlyCheckInterval: Double = 0.25

extension Runtime {

    /// Enables or disables the debug stale-view check for `Tx.liveOnly` handlers (`Runtime::check_live_only`).
    public func checkLiveOnly(_ on: Bool) {
        #if DEBUG
        liveOnlyCheckEnabled = on
        #endif
    }

    internal func captureLiveOnlyViewPrint() -> LiveOnlyViewPrint {
        let entries = flatNodes.compactMap { node -> LiveOnlyNodePrint? in
            if case .exiting = scene.phase(node.nodeId) { return nil }
            let el = node.el
            let hasLiveFill = el.liveBindings.contains { $0.target == .fill }
            let isLiveText = el.liveText != nil
            let isRedacted = el.isSecure && !el.isRevealed
            let textVal: String?
            if isLiveText {
                textVal = "(live)"
            } else if let spans = el.richSpans, !spans.isEmpty {
                textVal = spans.map(\.text).joined()
            } else {
                textVal = el.plainText
            }
            return LiveOnlyNodePrint(
                path: node.path,
                targetRect: node.targetRect,
                fill: hasLiveFill ? nil : el.background,
                borderColor: el.borderColor,
                borderWidth: el.borderWidth,
                opacity: el.opacity,
                corners: el.corners,
                text: textVal,
                isLiveText: isLiveText,
                isRedacted: isRedacted,
                textColor: isLiveText ? nil : el.textColor
            )
        }
        return LiveOnlyViewPrint(nodes: entries)
    }

    internal func viewPrint() -> LiveOnlyViewPrint {
        captureLiveOnlyViewPrint()
    }

    /// Handles a `Tx.liveOnly()` skip in debug builds: returns `true` when debug builds force
    /// a check commit (`0.25s` after the last commit) and `false` when the view build is skipped.
    internal func recordLiveOnlySkip(handler: String, at now: Double) -> Bool {
        #if DEBUG
        if liveOnlyCheckEnabled && (now - lastLiveCommitClock >= liveOnlyCheckInterval) {
            if pendingLiveOnlyCheck == nil && !needsCommit && !hasPendingActions && !suppressLiveOnlyCheckUntilCommit {
                pendingLiveOnlyCheck = (handler, captureLiveOnlyViewPrint())
            }
            liveChecks &+= 1
            return true
        }
        #endif
        liveOnlyEvents += 1
        return false
    }

    internal func compareLiveOnlyCheck(_ check: (handler: String, before: LiveOnlyViewPrint)?) {
        #if DEBUG
        guard let check else { return }
        let after = captureLiveOnlyViewPrint()
        guard let d = check.before.firstDifference(against: after) else { return }
        let head = "rune: \(check.handler) called Tx::liveOnly, but the view built something else after it: \(d.what) of \"\(d.path)\""
        if liveOnlyWarnings.contains(where: { $0.hasPrefix(head) }) {
            return
        }
        let valuesStr = d.values.map { " went from \($0.0) to \($0.1)" } ?? ""
        let warning = "\(head)\(valuesStr). The handler may have changed state the view reads, which stays stale until another event commits. Set only Live values in a live-only handler; for a time-dependent view, disable this heuristic with checkLiveOnly(false)."
        liveOnlyWarnings.append(warning)
        #endif
    }
}
