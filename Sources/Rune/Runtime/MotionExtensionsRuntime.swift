import Foundation
import RuneMotion

/// Instance locations belong to exactly one ordinary paint. A later paint can reorder
/// the scene even when its application commit is unchanged.
struct CyclePaint {
    /// Browser display timestamps can straddle a nominal vsync by less than a
    /// millisecond. Only a previously recorded decorative frame may use this slack.
    static let displayTolerance = 0.0005
    struct Slot {
        let node: NodeId
        var element: Int
        let path: String
        let index: Int
        let rect: SIMD4<Float>
        let ink: SIMD4<Float>
        let curve: Cycle
    }

    struct IconSlot {
        let node: NodeId
        let index: Int
        let icon: SVGIcon
        let pixelSize: Int
        let drawnSize: Float?
        let origin: SIMD2<Float>
        let mirrored: Bool
        let aligned: Bool
        let rect: SIMD4<Float>
    }

    private(set) var serial: UInt64 = 0
    private(set) var slots: [Slot] = []
    private(set) var iconSlots: [IconSlot] = []
    private(set) var interval: Double?

    mutating func begin() {
        serial &+= 1
        slots.removeAll(keepingCapacity: true)
        iconSlots.removeAll(keepingCapacity: true)
        interval = nil
    }

    mutating func record(node: NodeId, element: Int, path: String, index: Int, rect: SIMD4<Float>,
                         ink: SIMD4<Float>, curve: Cycle, interval: Double) {
        slots.append(Slot(node: node, element: element, path: path, index: index, rect: rect, ink: ink, curve: curve))
        self.interval = min(self.interval ?? interval, interval)
    }

    mutating func recordIcon(node: NodeId, index: Int, icon: SVGIcon, pixelSize: Int, drawnSize: Float?,
                             origin: SIMD2<Float>, mirrored: Bool, aligned: Bool, rect: SIMD4<Float>) {
        iconSlots.append(IconSlot(
            node: node, index: index, icon: icon, pixelSize: pixelSize, drawnSize: drawnSize,
            origin: origin, mirrored: mirrored, aligned: aligned, rect: rect
        ))
    }

    mutating func restoreTreeOrder(_ treeIndex: [Int]) {
        for i in slots.indices { slots[i].element = treeIndex[slots[i].element] }
    }
}

extension El {
    var isPlainCycleDecoration: Bool {
        isA11yHidden && children.isEmpty && !hasAuthoredHandlers && !isHit && !focusable &&
            !autofocus && !focusGroup && a11yHelp == nil && opacity == 1 &&
            borderWidth == 0 && shadows.isEmpty && blur == 0 && backdropBlur == 0 &&
            !isolatedLayer && rotate == 0 && plainText == nil && richSpans == nil &&
            shapes.isEmpty && iconPayload == nil && pixelsPayload == nil && surfacePayload == nil &&
            imagePayload == nil && terminalGridPayload == nil && gradient == nil &&
            liveText == nil && liveBindings.isEmpty && hoverBg == nil && pressBg == nil &&
            pressColor == nil && pressScaleFactor == nil && focusFillColor == nil &&
            groupOpacity == nil && runtimeExtras.isEmpty
    }
}

extension Runtime {
    func paintCycleTick(frame: inout RenderFrame, serial: UInt64, commit: Int, at now: Double) -> Bool {
        let clear = clearColor.simd4(srgb: srgbBlend)
        let hasIcons = !cyclePaint.iconSlots.isEmpty
        guard cyclePaint.serial == serial, viewCommitCount == commit, srgbBlend == frame.srgbBlend,
              frame.clearColor == SIMD4(clear.x * clear.w, clear.y * clear.w, clear.z * clear.w, clear.w),
              let due = activePaintedLoopWake, due - now <= CyclePaint.displayTolerance, now.isFinite,
              liveVisible, !reducedMotion, cxSettings.viewTimeScale > 0,
              !hasOtherPaintDeadline, !isTracing, traceChannels == nil, rewindRecorder == nil,
              !RasterCheck.enabled, restsExceptLoop(), (pollWakeDeadline() ?? .infinity) > now,
              !timerWake.isAsked, !polledChange, !virtualFill.resuming(at: now),
              (nextWakeDeadline(after: currentTime, includePaint: true, includeLoops: false) ?? .infinity) > now else {
            return false
        }
        if hasIcons {
            guard loopRuntime.tracks.isEmpty, cyclePaint.slots.isEmpty,
                  cyclePaint.iconSlots.allSatisfy({ slot in
                      frame.instances.indices.contains(slot.index)
                          && frame.instances[slot.index].rect == slot.rect
                          && frame.instances[slot.index].params.y == KIND_GLYPH
                          && textSystem.iconAnimSlotsReady(
                              slot.icon,
                              pixelSize: slot.pixelSize,
                              drawnSize: slot.drawnSize,
                              mirrored: slot.mirrored,
                              scopeID: slot.node.rawValue
                          )
                  }) else {
                return false
            }
            currentTime = now
            let scaledNow = cxSettings.scaledTime(at: now)
            var nextWake: Double? = nil
            var anyLive = false
            var anyChanged = false
            let pageW = Float(textSystem.glyphAtlas.pagePixelSize.x)
            let pageH = Float(textSystem.glyphAtlas.pagePixelSize.y)
            for slot in cyclePaint.iconSlots {
                let mountT = textSystem.iconAnimIsFinite(slot.icon)
                    ? iconMountTime(node: slot.node, icon: slot.icon, fallback: scaledNow)
                    : 0.0
                guard let anim = textSystem.animatedIconQuadInPlace(
                    slot.icon,
                    pixelSize: slot.pixelSize,
                    drawnSize: slot.drawnSize,
                    origin: slot.origin,
                    mirrored: slot.mirrored,
                    at: scaledNow,
                    mountTime: mountT,
                    scopeID: slot.node.rawValue
                ) else {
                    continue
                }
                switch anim.state {
                case .moving:
                    anyLive = true
                    let w = scaledNow + 1.0 / 30.0
                    nextWake = nextWake.map { min($0, w) } ?? w
                case .waitingUntil(let wakeAt):
                    anyLive = true
                    nextWake = nextWake.map { min($0, wakeAt) } ?? wakeAt
                case .finished:
                    break
                }
                var normUV = anim.entry.uv
                if !slot.aligned {
                    let pxF = Float(max(1, anim.entry.pixelSize.x))
                    let pyF = Float(max(1, anim.entry.pixelSize.y))
                    let du = (normUV.z - normUV.x) / pxF
                    let dv = (normUV.w - normUV.y) / pyF
                    normUV += SIMD4(-du, -dv, du, dv)
                }
                let u0 = normUV.x * pageW
                let v0 = normUV.y * pageH
                let uw = max(1.0, (normUV.z - normUV.x) * pageW)
                let vh = max(1.0, (normUV.w - normUV.y) * pageH)
                let scaled = !slot.aligned || abs(uw - slot.rect.z) > 0.5 || abs(vh - slot.rect.w) > 0.5
                let nextUV = SIMD4<Float>(u0, v0, scaled ? uw : 0, scaled ? vh : 0)
                let nextPage = Float(anim.entry.page)
                if anim.changed || frame.instances[slot.index].uv != nextUV || frame.instances[slot.index].params.z != nextPage {
                    frame.instances[slot.index].uv = nextUV
                    frame.instances[slot.index].params.z = nextPage
                    anyChanged = true
                }
            }
            animatedIconsShown = anyLive
            if let wakeAt = nextWake {
                let wallWake = now + max(0.0, wakeAt - scaledNow) / Double(cxSettings.viewTimeScale)
                activePaintedLoopWake = wallWake
            } else {
                activePaintedLoopWake = nil
            }
            if anyChanged {
                let glyphAtlas = textSystem.glyphAtlas.framePages()
                frame.glyphs = glyphAtlas.bases[0]
                frame.glyphPages = glyphAtlas.bases.count > 1 ? glyphAtlas.bases : []
                frame.glyphGeneration = glyphAtlas.generation
                frame.glyphPageRevisions = glyphAtlas.revisions
                frame.rawGlyphPageRevisions = glyphAtlas.rawRevisions
                frame.glyphPagePatches = glyphAtlas.patches
                frame.rawGlyphPagePatches = glyphAtlas.rawPatches
            }
            return true
        }
        guard let dt = cyclePaint.interval, cyclePaint.slots.count == loopRuntime.tracks.count,
              cyclePaint.slots.allSatisfy({ slot in
                  frame.instances.indices.contains(slot.index) && frame.instances[slot.index].rect == slot.rect &&
                      frame.instances[slot.index].params.y == KIND_RECT && reportedPath(at: slot.element) == slot.path
              }) else { return false }
        currentTime = now
        for slot in cyclePaint.slots {
            let opacity = slot.curve.sample(at: now)
            let a = slot.ink.w * opacity
            frame.instances[slot.index].fill = SIMD4(slot.ink.x * a, slot.ink.y * a, slot.ink.z * a, a)
            frame.instances[slot.index].params.w = opacity
            updateReportedOpacity(opacity, at: slot.element)
            hitGeometryByPath[slot.path]?.opacity = opacity
            kitHooks.unseenPresence.updateCycleOpacity(slot.node, opacity: opacity)
        }
        invalidateNativeMotionElements()
        activePaintedLoopWake = now + dt
        return true
    }
}

/// Runtime hooks bridging `El.childExit`, `El.rideTrailing`, and `LoopClock` / `El.loopOpacity` /
/// `El.loopRotation` / `El.loopSlide` / `El.cycle` / `Stagger.cascade` into `Runtime`
/// (`Sources/Rune/El/ChildExit.swift`, `RideTrailing.swift`, `MotionLoopExtensions.swift`,
/// `Sources/Rune/Runtime/LoopClock.swift`).
internal extension Runtime {
    /// Called by both painters for the loop's visible home geometry, including a slide
    /// whose current pose has moved outside the clip.
    func schedulePaintedLoop(_ track: LoopTrack, id: NodeId) {
        let nodeTime = scene.store.nodeTime(id)
        let scale = Double(scene.store.nodeTimeScale(id)) * Double(cxSettings.viewTimeScale)
        func wake(after delay: Double) {
            let due = currentTime + delay
            activePaintedLoopWake = min(activePaintedLoopWake ?? due, due)
        }
        if track.isActive(at: nodeTime) {
            if let interval = track.frameInterval() {
                wake(after: interval)
            } else if scale > 0 {
                activePaintedLoopsAnimating = true
            }
        }
        if scale > 0, let start = track.pendingStart(at: nodeTime) {
            wake(after: max(0, start - nodeTime) / scale)
        }
    }

    /// Captures exiting direct-child `ChildExit` overrides before `flatNodes` is replaced by a commit.
    func collectChildExitOverrides(
        prevNodes: [FlatNode],
        newPass: MeasurePassResult,
        cut: Bool
    ) -> [(childId: NodeId, parentEl: El<State>)] {
        guard !cut else { return [] }
        var out: [(childId: NodeId, parentEl: El<State>)] = []
        for prevNode in prevNodes {
            guard newPass.indexById[prevNode.nodeId] == nil else { continue }
            guard let prevParentIdx = prevNode.parentIndex, prevParentIdx < prevNodes.count else { continue }
            let parentId = prevNodes[prevParentIdx].nodeId
            guard let liveParent = newPass.node(parentId),
                  !liveParent.el.hasInstantChanges,
                  liveParent.el.childExitTransition != nil else {
                continue
            }
            out.append((prevNode.nodeId, liveParent.el))
        }
        return out
    }

    /// Applies queued `ChildExit` transition overrides right before `scene.commit` removes omitted nodes.
    func applyChildExitHooks(
        _ overrides: [(childId: NodeId, parentEl: El<State>)],
        matchedStarts: [NodeId: MatchedFlightStart],
        to scene: inout Scene
    ) {
        guard !overrides.isEmpty else { return }
        let matchedRemoved = Set(matchedStarts.values.compactMap(\.fromId))
        for (childId, parentEl) in overrides where !matchedRemoved.contains(childId) {
            ChildExitHook.apply(parentEl: parentEl, childId: childId, to: &scene)
        }
    }

    /// Syncs `el.looping` specs after `scene.commit` using `LoopClock`'s per-node animation lead time.
    /// `cut` (`settleAll`) only finishes finite sequences; periodic loops preserve phase across commits and settles.
    func syncMotionLoops(specs: [(id: NodeId, spec: LoopSpec)], at _: Double, cut: Bool) {
        loopRuntime.sync(
            specs: specs,
            startFor: { elSliceRenderState.loopCatchUp.loopStart(id: $0, scene: scene) },
            sceneContains: { scene.contains($0) },
            reducedMotion: reducedMotion,
            cut: cut
        )
    }

    /// Catches running periodic loop tracks up to wall-clock time when animation frames stall or sleep (`loop_clock.rs`).
    func syncMotionLoopClock(to appNow: Double, animNow: Double) {
        elSliceRenderState.loopCatchUp.catchLoopsUp(
            hostNow: appNow,
            animNow: animNow,
            timeScale: cxSettings.viewTimeScale,
            scene: scene,
            tracks: &loopRuntime.tracks
        )
    }

    /// Samples a node's active loop track (periodic/sequence tracks use `at`; `Cycle` uses unscaled
    /// wall-clock `wallNow` so it retains its cadence even when animation time is paused).
    func sampleLoopPresentation(id: NodeId, nodeSize: Vec2, at now: Double, wallNow: Double) -> LoopSampleResult? {
        loopRuntime.sample(id: id, nodeSize: nodeSize, at: now, wall: wallNow, reducedMotion: reducedMotion)
    }
    func sampleLoopPresentation(id: NodeId, nodeSize: Vec2, wallNow: Double) -> LoopSampleResult? {
        guard !loopRuntime.tracks.isEmpty else { return nil }
        return loopRuntime.sample(
            id: id,
            nodeSize: nodeSize,
            at: scene.store.nodeTime(id),
            wall: wallNow,
            reducedMotion: reducedMotion
        )
    }

    /// True when any non-sleeping loop needs frame advances (`isAnimating`).
    func hasActiveMotionLoops(at appNow: Double) -> Bool {
        _ = appNow
        if reducedMotion || !liveVisible {
            return false
        }
        return activePaintedLoopsAnimating
    }

    /// Earliest wall-clock deadline needed by any active painted `Cycle` frame interval OR delayed `LoopTrack`.
    func nextLoopWakeDeadline(after now: Double) -> Double? {
        if reducedMotion || !liveVisible {
            return nil
        }
        // The painted loop wake (`loop_wake`) is set by the last build; one at or before `now` is
        // already due and is renewed by the next paint, so it is not a future deadline. Returning it
        // would let `frameSplitImpl`'s catch-up loop spin at `now` without advancing (upstream
        // `timer_step` always steps forward).
        guard let wake = activePaintedLoopWake, wake > now else { return nil }
        return wake
    }
}
