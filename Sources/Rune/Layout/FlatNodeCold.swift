import Foundation
import RuneMotion

/// Cold attributes of a laid-out `Runtime.FlatNode`, boxed so `FlatNode` stays
/// compact in the contiguous flat node array (`types.rs::NodeCold`, `size_tests.rs`).
internal final class FlatNodeCold<State> {
    var el: El<State>
    var unscrolledRect: MotionRect
    var zoomedTargetRect: MotionRect
    var staticRect: [Float]
    var contentSize: Vec2
    var clipRect: MotionRect
    var scrollShift: Vec2
    var localSize: Vec2
    var zOrder: Int
    var inheritedScale: Float
    var anchorAttachNorm: Vec2?
    var activeClipFades: [EdgeFadeSpec]
    var ownScrollFade: EdgeFadeSpec?
    var ownClipFade: EdgeFadeSpec?
    var enclosingScrollIndex: Int?
    var enclosingVScrollIndex: Int?
    var enclosingHScrollIndex: Int?
    var flow: Flow
    var mirroredInRtl: Bool
    var elided: TextElision?

    init(
        el: El<State>,
        unscrolledRect: MotionRect,
        zoomedTargetRect: MotionRect,
        staticRect: [Float],
        contentSize: Vec2,
        clipRect: MotionRect,
        scrollShift: Vec2,
        localSize: Vec2,
        zOrder: Int,
        inheritedScale: Float,
        anchorAttachNorm: Vec2?,
        activeClipFades: [EdgeFadeSpec],
        ownScrollFade: EdgeFadeSpec?,
        ownClipFade: EdgeFadeSpec?,
        enclosingScrollIndex: Int?,
        enclosingVScrollIndex: Int?,
        enclosingHScrollIndex: Int?,
        flow: Flow = .ltr,
        mirroredInRtl: Bool = false,
        elided: TextElision? = nil
    ) {
        self.el = el
        self.unscrolledRect = unscrolledRect
        self.zoomedTargetRect = zoomedTargetRect
        self.staticRect = staticRect
        self.contentSize = contentSize
        self.clipRect = clipRect
        self.scrollShift = scrollShift
        self.localSize = localSize
        self.zOrder = zOrder
        self.inheritedScale = inheritedScale
        self.anchorAttachNorm = anchorAttachNorm
        self.activeClipFades = activeClipFades
        self.ownScrollFade = ownScrollFade
        self.ownClipFade = ownClipFade
        self.enclosingScrollIndex = enclosingScrollIndex
        self.enclosingVScrollIndex = enclosingVScrollIndex
        self.enclosingHScrollIndex = enclosingHScrollIndex
        self.flow = flow
        self.mirroredInRtl = mirroredInRtl
        self.elided = elided
    }

    func copy() -> FlatNodeCold<State> {
        FlatNodeCold(
            el: el,
            unscrolledRect: unscrolledRect,
            zoomedTargetRect: zoomedTargetRect,
            staticRect: staticRect,
            contentSize: contentSize,
            clipRect: clipRect,
            scrollShift: scrollShift,
            localSize: localSize,
            zOrder: zOrder,
            inheritedScale: inheritedScale,
            anchorAttachNorm: anchorAttachNorm,
            activeClipFades: activeClipFades,
            ownScrollFade: ownScrollFade,
            ownClipFade: ownClipFade,
            enclosingScrollIndex: enclosingScrollIndex,
            enclosingVScrollIndex: enclosingVScrollIndex,
            enclosingHScrollIndex: enclosingHScrollIndex,
            flow: flow,
            mirroredInRtl: mirroredInRtl,
            elided: elided
        )
    }
}
