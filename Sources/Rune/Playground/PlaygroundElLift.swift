import Foundation
import RuneMotion

extension El {
    /// Converts `El<State>` (with handlers over `State`) into `El<Parent>` whose handlers
    /// safely read and mutate the child state provided by `(get, set)` while `isValid()` holds.
    internal func liftHandlers<Parent>(
        isValid: @escaping () -> Bool,
        get: @escaping () -> State?,
        set: @escaping (State) -> Void
    ) -> El<Parent> {
        var out = El<Parent>(direction: layout.direction)
        out.keyId = keyId
        out.role = role
        out.layout = layout

        // Hot properties
        out.plainText = plainText
        out.textStyle = textStyle
        out.textColor = textColor
        out.shapes = shapes
        out.background = background
        out.borderColor = borderColor
        out.borderWidth = borderWidth
        out.corners = corners
        out.shadows = shadows
        out.opacity = opacity
        out.scale = scale
        out.rotate = rotate
        out.origin = origin
        out.offset = offset
        out.blur = blur
        out.backdropBlur = backdropBlur
        out.zIndex = zIndex
        out.isolatedLayer = isolatedLayer
        out.focusable = focusable
        out.focusOptOut = focusOptOut
        out.autofocus = autofocus
        out.focusGroup = focusGroup
        out.isModal = isModal
        out.isInert = isInert
        out.isHit = isHit
        out.isSecure = isSecure
        out.isRevealed = isRevealed

        // Cold properties (copied only when non-default to avoid unnecessary allocations)
        if let richSpans { out.richSpans = richSpans }
        if !textLinks.isEmpty { out.textLinks = textLinks }
        if let liveText { out.liveText = liveText }
        if let placeholder { out.placeholder = placeholder }
        if let placeholderColor { out.placeholderColor = placeholderColor }
        if let caretColor { out.caretColor = caretColor }
        if let selectionColor { out.selectionColor = selectionColor }
        if let iconPayload { out.iconPayload = iconPayload }
        if let imagePayload { out.imagePayload = imagePayload }
        if let surfacePayload { out.surfacePayload = surfacePayload }
        if surfacePlace != .centered { out.surfacePlace = surfacePlace }
        if let gradient { out.gradient = gradient }
        if let borderSides { out.borderSides = borderSides }
        if let dashedBorder { out.dashedBorder = dashedBorder }
        if !pixelSnapEnabled { out.pixelSnapEnabled = pixelSnapEnabled }
        if let clipRadius { out.clipRadius = clipRadius }
        if let clipCorners { out.clipCorners = clipCorners }
        if let clipFade { out.clipFade = clipFade }
        if scrollEdgeFadeWidth != 0 { out.scrollEdgeFadeWidth = scrollEdgeFadeWidth }
        if scrollFadeStyle != .smooth { out.scrollFadeStyle = scrollFadeStyle }
        if scrollMarginPts != 0 { out.scrollMarginPts = scrollMarginPts }
        if scrollAnchorEnabled { out.scrollAnchorEnabled = true }
        if let stickyConfig { out.stickyConfig = stickyConfig }
        if let growthSpec { out.growthSpec = growthSpec }
        if isStreaming { out.isStreaming = true }
        if isArrivesWhole { out.isArrivesWhole = true }
        if let explicitDir { out.explicitDir = explicitDir }
        if isUnmirrored { out.isUnmirrored = true }
        if mirrorInRtl { out.mirrorInRtl = true }
        if textDirByParagraph { out.textDirByParagraph = true }
        if let foldGlideSpec { out.foldGlideSpec = foldGlideSpec }
        if let virtualEstimate { out.virtualEstimate = virtualEstimate }
        if let src = virtualRowsSource {
            out.virtualRowsSource = VirtualRowSource<Parent>(
                count: src.count,
                key: { _, index in
                    guard isValid(), let child = get() else { return "vrow-\(index)" }
                    return src.key(child, index)
                },
                build: { _, index in
                    guard isValid(), let child = get() else { return El<Parent>() }
                    return src.build(child, index).liftHandlers(isValid: isValid, get: get, set: set)
                }
            )
        }
        if let virtualRowsVersionHash { out.virtualRowsVersionHash = virtualRowsVersionHash }
        if isFocusSelected { out.isFocusSelected = true }
        if isRevealSelected { out.isRevealSelected = true }
        if let hoverBg { out.hoverBg = hoverBg }
        if let pressBg { out.pressBg = pressBg }
        if let pressScaleFactor { out.pressScaleFactor = pressScaleFactor }
        if isHoverGroup { out.isHoverGroup = true }
        if let hoverGroupShare { out.hoverGroupShare = hoverGroupShare }
        if isHoverAlone { out.isHoverAlone = true }
        if let groupOpacity { out.groupOpacity = groupOpacity }
        if let groupColor { out.groupColor = groupColor }
        if let focusRingColor { out.focusRingColor = focusRingColor }
        if focusRingWidth != 2.0 { out.focusRingWidth = focusRingWidth }
        if focusRingOffset != 2.0 { out.focusRingOffset = focusRingOffset }
        if let focusReturnKey { out.focusReturnKey = focusReturnKey }
        if modalClickOutside { out.modalClickOutside = true }
        if let tabIndex { out.tabIndex = tabIndex }
        if isDefaultButton { out.isDefaultButton = true }
        if noFocusRing { out.noFocusRing = true }
        if isFocusRequested { out.isFocusRequested = true }
        if let focusHighlightColor { out.focusHighlightColor = focusHighlightColor }
        if let focusWithinRing { out.focusWithinRing = focusWithinRing }
        if focusWithinFlat { out.focusWithinFlat = true }
        if isFocusFollowsSelection { out.isFocusFollowsSelection = true }

        if let a11yLabel { out.a11yLabel = a11yLabel }
        if let a11yHelp { out.a11yHelp = a11yHelp }
        if isHelpWhenTruncated { out.isHelpWhenTruncated = true }
        if let helpSide { out.helpSide = helpSide }
        if let a11ySelected { out.a11ySelected = a11ySelected }
        if let a11yExpanded { out.a11yExpanded = a11yExpanded }
        if let a11yLevel { out.a11yLevel = a11yLevel }
        if itemSelected { out.itemSelected = true }
        if let a11yDescription { out.a11yDescription = a11yDescription }
        if let a11yValue { out.a11yValue = a11yValue }
        if let a11yRange { out.a11yRange = a11yRange }
        if let a11yChecked { out.a11yChecked = a11yChecked }
        if a11yDisabled { out.a11yDisabled = true }
        if isA11yHidden { out.isA11yHidden = true }
        if let a11yActiveDescendant { out.a11yActiveDescendant = a11yActiveDescendant }
        if let a11yLabelledBy { out.a11yLabelledBy = a11yLabelledBy }
        if let a11yDescribedBy { out.a11yDescribedBy = a11yDescribedBy }
        if a11yBusy { out.a11yBusy = true }
        if a11yInvalid { out.a11yInvalid = true }
        if a11yReadOnly { out.a11yReadOnly = true }
        if let a11ySorted { out.a11ySorted = a11ySorted }
        if let a11yLive { out.a11yLive = a11yLive }
        if let a11yPosInSet { out.a11yPosInSet = a11yPosInSet }
        if let a11yShortcutHint { out.a11yShortcutHint = a11yShortcutHint }
        if let a11yHref { out.a11yHref = a11yHref }

        if let anchor { out.anchor = anchor }
        if let layoutAnim { out.layoutAnim = layoutAnim }
        if let styleSpring { out.styleSpring = styleSpring }
        if let transition { out.transition = transition }
        if enterDelay != 0 { out.enterDelay = enterDelay }
        if hasInstantChanges { out.hasInstantChanges = true }
        if hasAnimatedChanges { out.hasAnimatedChanges = true }
        if let loopingSpec { out.loopingSpec = loopingSpec }
        if let flightId { out.flightId = flightId }
        if isMatchedCrop { out.isMatchedCrop = true }
        if let flightSpring { out.flightSpring = flightSpring }
        if let terminalGridPayload { out.terminalGridPayload = terminalGridPayload }
        if let focusFillColor { out.focusFillColor = focusFillColor }
        if pressFocusesBelow { out.pressFocusesBelow = true }
        if noWindowDrag { out.noWindowDrag = true }
        if isImeCursor { out.isImeCursor = true }
        if let traceNameValue { out.traceNameValue = traceNameValue }
        if let traceNamespaceValue { out.traceNamespaceValue = traceNamespaceValue }
        if isSpellcheck { out.isSpellcheck = true }
        if !liveBindings.isEmpty { out.liveBindings = liveBindings }

        if !runtimeExtras.isEmpty {
            var extras = runtimeExtras
            if let mapped = El<State>.liftSelectionChangeBox(
                to: Parent.self,
                from: extras[El<State>.onSelectionChangeExtraKey],
                isValid: isValid,
                get: get,
                set: set
            ) {
                extras[El<Parent>.onSelectionChangeExtraKey] = mapped
            }
            out.runtimeExtras = extras
        }

        // Lift ElementHandlers<State> -> ElementHandlers<Parent>
        let h = handlers
        var lifted = ElementHandlers<Parent>()
        var hasHandler = false

        func wrap(_ fn: ((inout State, inout Tx) -> Void)?) -> ((inout Parent, inout Tx) -> Void)? {
            guard let fn else { return nil }
            hasHandler = true
            return { _, tx in
                guard isValid(), var child = get() else { return }
                fn(&child, &tx)
                set(child)
            }
        }

        func wrap1<Arg>(_ fn: ((inout State, Arg, inout Tx) -> Void)?) -> ((inout Parent, Arg, inout Tx) -> Void)? {
            guard let fn else { return nil }
            hasHandler = true
            return { _, arg, tx in
                guard isValid(), var child = get() else { return }
                fn(&child, arg, &tx)
                set(child)
            }
        }

        func wrap2<Arg1, Arg2>(_ fn: ((inout State, Arg1, Arg2, inout Tx) -> Void)?) -> ((inout Parent, Arg1, Arg2, inout Tx) -> Void)? {
            guard let fn else { return nil }
            hasHandler = true
            return { _, arg1, arg2, tx in
                guard isValid(), var child = get() else { return }
                fn(&child, arg1, arg2, &tx)
                set(child)
            }
        }

        func wrapBool1<Arg>(_ fn: ((inout State, Arg, inout Tx) -> Bool)?) -> ((inout Parent, Arg, inout Tx) -> Bool)? {
            guard let fn else { return nil }
            hasHandler = true
            return { _, arg, tx in
                guard isValid(), var child = get() else { return false }
                let handled = fn(&child, arg, &tx)
                set(child)
                return handled
            }
        }

        lifted.onClick = wrap(h.onClick)
        lifted.onClickPress = wrap1(h.onClickPress)
        lifted.onDoubleClick = wrap(h.onDoubleClick)
        lifted.onSecondaryClick = wrap1(h.onSecondaryClick)
        lifted.onPointerDown = wrap1(h.onPointerDown)
        lifted.onPointerUp = wrap1(h.onPointerUp)
        lifted.onPointerMove = wrap1(h.onPointerMove)
        lifted.onHover = wrap1(h.onHover)
        lifted.onHoverChange = wrap1(h.onHoverChange)
        lifted.hoverDelay = h.hoverDelay
        lifted.onDrag = wrap1(h.onDrag)
        lifted.onDragEnd = wrap1(h.onDragEnd)
        if let drop = h.drop {
            hasHandler = true
            lifted.drop = DropSpec<Parent>(
                accepts: drop.accepts,
                onDropFiles: wrap1(drop.onDropFiles),
                onDropHover: wrap1(drop.onDropHover),
                onDropMove: wrap1(drop.onDropMove),
                onDropRejected: wrap1(drop.onDropRejected),
                onDropRejectedHover: wrap1(drop.onDropRejectedHover)
            )
        }
        if let dragOut = h.dragOut {
            hasHandler = true
            lifted.dragOut = { _ in
                guard isValid(), let child = get() else { return nil }
                return dragOut(child)
            }
        }
        if let thresh = h.dragThreshold {
            hasHandler = true
            lifted.dragThreshold = thresh
        }
        lifted.onDragStart = wrap(h.onDragStart)
        lifted.onDragOutEnd = wrap1(h.onDragOutEnd)
        lifted.onKey = wrapBool1(h.onKey)
        lifted.onPhysicalInput = wrapBool1(h.onPhysicalInput)
        lifted.onWheel = wrapBool1(h.onWheel)
        if let lens = h.editLens {
            hasHandler = true
            lifted.editLens = (
                get: { _ in
                    guard isValid(), let child = get() else { return TextEdit() }
                    return lens.get(child)
                },
                set: { _, updated in
                    guard isValid(), var child = get() else { return }
                    lens.set(&child, updated)
                    set(child)
                }
            )
        }
        lifted.onInputKey = wrapBool1(h.onInputKey)
        lifted.onInputChange = wrapBool1(h.onInputChange)
        lifted.onTextChange = wrap1(h.onTextChange)
        lifted.onTextSubmit = wrap1(h.onTextSubmit)
        lifted.onLink = wrap1(h.onLink)
        lifted.onLinkSecondary = wrap2(h.onLinkSecondary)
        lifted.onBackgroundPress = wrap1(h.onBackgroundPress)
        lifted.onScreenLayout = wrap1(h.onScreenLayout)
        lifted.onSpellcheck = wrap1(h.onSpellcheck)
        lifted.onSpellcheckLanguages = wrap1(h.onSpellcheckLanguages)
        lifted.modalDismiss = wrap(h.modalDismiss)
        if let onAtBottom = h.onAtBottom {
            hasHandler = true
            lifted.onAtBottom = { _, atBottom in
                guard isValid(), var child = get() else { return }
                onAtBottom(&child, atBottom)
                set(child)
            }
        }
        if let far = h.onFarFromBottom {
            hasHandler = true
            lifted.onFarFromBottom = (min: far.min, frameKey: far.frameKey, handler: { _, isFar in
                guard isValid(), var child = get() else { return }
                far.handler(&child, isFar)
                set(child)
            })
        }
        if let onScrollOffset = h.onScrollOffset {
            hasHandler = true
            lifted.onScrollOffset = onScrollOffset
        }
        if let onScroll = h.onScroll {
            hasHandler = true
            lifted.onScroll = { _, pos, tx in
                guard isValid(), var child = get() else { return }
                onScroll(&child, pos, &tx)
                set(child)
            }
        }
        if let onVisibleRows = h.onVisibleRows {
            hasHandler = true
            lifted.onVisibleRows = { _, range in
                guard isValid(), var child = get() else { return false }
                let dirty = onVisibleRows(&child, range)
                set(child)
                return dirty
            }
        }

        if hasHandler {
            out.handlers = lifted
        }

        if !children.isEmpty {
            out.children = children.map { $0.liftHandlers(isValid: isValid, get: get, set: set) }
        }
        return out
    }
}
