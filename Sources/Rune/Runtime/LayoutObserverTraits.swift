import RuneMotion

/// Authored observer roles stay the same throughout the lifetime of an immutable memo span.
/// Inertness, live pixel sizes and the value returned by an edit lens are resolved each commit.
struct LayoutObserverTraits {
    enum Role: Int {
        case liveSource, hoverTrack, hoverGroup, hoverChange, hoverCurve
        case laidOut, drawn, drawnRect, visible, visibleRows
        case scrollReport, scrollAnchor, bottomViewport
        case focusRequest, focusReturn, focusFollowsSelection, autofocus, selectionChange
        case focusSelected, revealSelected
        case inputPills, groupOpacity, matchedFlight, heldLandingWidth, growthStack, filterContainer
        case shadow, childExit, rideTrailing, timeScale, wordReveal, extraCommitColor
        case pictureAspect, secureOrEditable, kitHoverDelay, scrollViewport, isolatedOrTransition
        case pressColor, pressScale
    }

    private(set) var bits: UInt64 = 0

    private mutating func add(_ role: Role) { bits |= 1 << role.rawValue }
    func contains(_ role: Role) -> Bool { bits & (1 << role.rawValue) != 0 }

    init<State>(_ el: borrowing El<State>) {
        let scrolls = !el.layout.scrollAxes.isEmpty
        if scrolls { add(.scrollViewport) }
        if el.isolatedLayer || el.transition != nil { add(.isolatedOrTransition) }
        el.withAuthoredHandlers { handlers in
            indexHandlers(handlers, scrolls: scrolls)
            if handlers.onHover != nil && el.kitHoverDelaysSpec != nil { add(.kitHoverDelay) }
            if handlers.editLens != nil && (el.pillStyleLookup != nil || el.pillIconLookup != nil || el.pillColorsSpec != nil) {
                add(.inputPills)
            }
        }
        if el.isSecure || el.hasEditLens { add(.secureOrEditable) }
        if el.pixelsPayload != nil {
            add(.liveSource)
            if el.layout.aspectRatio == nil, (el.layout.width == .auto) != (el.layout.height == .auto) {
                add(.pictureAspect)
            }
        } else if el.liveText != nil || !el.liveBindings.isEmpty {
            add(.liveSource)
        }
        if el.isFocusSelected { add(.focusSelected) }
        if el.isRevealSelected { add(.revealSelected) }
        if el.isFocusRequested { add(.focusRequest) }
        if el.isModal || el.focusReturnKey != nil { add(.focusReturn) }
        if el.focusGroup && el.isFocusFollowsSelection { add(.focusFollowsSelection) }
        if el.autofocus { add(.autofocus) }
        if (el.hoverBg?.a ?? 0) > 0 || el.isHoverGroup || el.hoverGroupShare != nil { add(.hoverTrack) }
        if el.isHoverAlone || el.hoverGroupShare != nil { add(.hoverGroup) }
        if el.pressColor != nil || (el.pressBg?.a ?? 0) > 0 { add(.pressColor) }
        if el.pressScaleFactor != nil { add(.pressScale) }
        if el.hoverWithinSpec != nil || el.hoverMotionSpec != nil { add(.hoverCurve) }
        if scrolls && el.layout.scrollAxes.contains(.vertical) {
            if el.scrollAnchorEnabled { add(.scrollAnchor) }
            if el.layout.stickBottom { add(.bottomViewport) }
        }
        if el.groupOpacity != nil { add(.groupOpacity) }
        if el.flightId != nil { add(.matchedFlight) }
        if el.holdLandingWidthEnabled { add(.heldLandingWidth) }
        if el.growthSpec != nil { add(.growthStack) }
        if el.kitFilterKeysValue != nil { add(.filterContainer) }
        if !el.shadows.isEmpty {
            add(.shadow)
            add(.extraCommitColor)
        }
        if el.runtimeExtraCount == 0 {
            if el.textReveal >= 0 { add(.wordReveal) }
        } else {
            if el.hasSelectionChangeHandler { add(.selectionChange) }
            if el.childExitTransition != nil { add(.childExit) }
            if el.isRideTrailing { add(.rideTrailing) }
            if el.elTimeScale != 1 { add(.timeScale) }
            if let fade = el.elRevealWordFade, fade >= 0 { add(.wordReveal) }
            if el.runtimeExtra(RenderExtrasKey.radialGradient) != nil ||
                el.runtimeExtra(RenderExtrasKey.borderGradient) != nil {
                add(.extraCommitColor)
            }
        }
    }

    private mutating func indexHandlers<State>(_ h: borrowing ElementHandlers<State>, scrolls: Bool) {
        if h.onHoverChange != nil { add(.hoverChange) }
        if h.onLayout != nil || h.onScreenLayout != nil { add(.laidOut) }
        if h.onDrawnLayout != nil { add(.drawn) }
        if h.drawnRectUpdate != nil { add(.drawnRect) }
        if h.onVisible != nil { add(.visible) }
        if h.onVisibleRows != nil { add(.visibleRows) }
        if scrolls && (h.onScrollOffset != nil || h.onScroll != nil || h.atBottomReport != nil || h.farFromBottomReport != nil) {
            add(.scrollReport)
        }
    }
}

extension Runtime.LayoutObservers {
    mutating func register(_ traits: LayoutObserverTraits, at i: Int, id: NodeId, inert: Bool) {
        var bits = traits.bits
        while bits != 0 {
            let bit = bits.trailingZeroBitCount
            bits &= bits - 1
            switch LayoutObserverTraits.Role(rawValue: bit)! {
            case .laidOut: laidOut.append(i)
            case .drawn: drawn.append(i)
            case .drawnRect: drawnRect.append(i)
            case .visible: visible.append(i)
            case .visibleRows: visibleRows.append(i)
            case .scrollReport: scrollReports.append(i)
            case .scrollAnchor: scrollAnchors.append(i)
            case .bottomViewport:
                bottomViewports.append(i)
                bottomChildren[i] = []
            case .focusRequest: if !inert { focusRequests.append(i) }
            case .focusSelected: focusSelected.append(i)
            case .revealSelected: revealSelected.append(i)
            case .focusReturn: focusReturns.append(i)
            case .focusFollowsSelection: focusFollowsSelection.append(i)
            case .autofocus: autofocus.append(i)
            case .selectionChange: if !inert { selectionChanges.append(i) }
            case .hoverTrack: hoverTracks.append(i)
            case .pressColor: pressColors.append(i)
            case .pressScale: pressScales.append(i)
            case .hoverGroup: hoverGroups.append(i)
            case .hoverChange: hoverChanges.append(i)
            case .kitHoverDelay: kitHoverDelays.append(i)
            case .hoverCurve: hasHoverCurves = true
            case .inputPills: inputPills.append(i)
            case .liveSource: liveSources.append(i)
            case .groupOpacity: groupOpacity.append(i)
            case .matchedFlight: matchedFlights.append(i)
            case .heldLandingWidth: heldLandingWidths.append(i)
            case .growthStack: growthStacks.append(i)
            case .filterContainer: filterContainers.append(i)
            case .shadow: hasShadows = true
            case .childExit: hasChildExits = true
            case .rideTrailing: rideTrailing.insert(id)
            case .timeScale: hasTimeScales = true
            case .wordReveal: wordReveals.append(i)
            case .extraCommitColor: extraCommitColors.append(i)
            case .pictureAspect, .secureOrEditable, .scrollViewport, .isolatedOrTransition: break
            }
        }
    }
}
