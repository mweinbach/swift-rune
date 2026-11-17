import RuneMotion

extension Runtime {
    /// The presented paint of each mounted or departing element, in draw order.
    public func paints() -> [MotionGateRecording.PaintKey: MotionGatePaint] {
        typealias Key = MotionGateRecording.PaintKey
        var nodes: [Key: FlatNode] = [:]
        for node in flatNodes { nodes[Key(path: node.path, exiting: false)] = node }
        for node in exitingSnapshots.values { nodes[Key(path: node.path, exiting: true)] = node }

        var paints: [Key: MotionGatePaint] = [:]
        // A lifted child may paint after siblings. Its inherited values still come from its layout parent.
        var ancestry: [(layerOpacity: Float, intent: UInt16, instant: Bool, group: Float)] = []
        let groupHovered = makeGroupHoverPredicate()
        for node in flatNodes {
            let parent = node.parentIndex.flatMap { ancestry.indices.contains($0) ? ancestry[$0] : nil }
            let el = node.el
            let isGroup = el.isHoverGroup || el.hoverBg != nil || el.hoverGroupShare != nil
            let group = isGroup
                ? liveStore.get(Self.hoverTrackId(node.nodeId), Self.hoverProp) ?? (groupHovered(node) ? 1 : 0)
                : parent?.group ?? 0
            ancestry.append((
                (parent?.layerOpacity ?? 1) * el.elLayerOpacity,
                (parent?.intent ?? 0) | (el.runtimeExtras[MotionGateExtraKey.motionIntent] as? UInt16 ?? 0),
                (parent?.instant ?? false) || el.hasInstantChanges || el.runtimeExtras[MotionGateExtraKey.instantChanges] as? Bool == true,
                group
            ))
        }
        for (rank, e) in elements().enumerated() {
            let key = Key(path: e.path, exiting: e.exiting)
            guard let node = nodes[key], paints[key] == nil else { continue }
            let el = node.el
            let id = node.nodeId
            let parent = node.parentIndex.flatMap { ancestry.indices.contains($0) ? ancestry[$0] : nil }
            let alpha = el.elPaintAlpha * el.elLayerOpacity * (parent?.layerOpacity ?? 1)
            func live(_ target: BoundLiveProperty.Target) -> Color? {
                guard el.liveBindings.contains(where: { $0.target == target }) else { return nil }
                return presentedLiveColor(NodeId.hash("live:\(node.path):\(target)"))
            }
            func color(_ prop: Prop<MotionColor>, _ fallback: Color) -> Color {
                guard let value = scene.store.get(id, prop) else { return fallback }
                return value == fallback.motionColor ? fallback : Color(value)
            }

            var paint = MotionGatePaint()
            paint.colors[MotionGatePaint.cFill] = e.fill.scaleAlpha(alpha)
            let border = el.runtimeExtras[RenderExtrasKey.borderGradient] as? RenderBorderGradientSpec
            let width = border?.width ?? el.borderWidth
            if width > 0 {
                paint.colors[MotionGatePaint.cBorder] = (live(.borderColor) ?? color(Props.BORDER, border?.top ?? el.borderColor)).scaleAlpha(alpha)
            }
            paint.pointer = SIMD2(e.hover, e.press)
            let paintsInk = el.plainText != nil || el.richSpans != nil || el.advanceInRun != nil
                || el.handlers.editLens != nil || el.iconPayload != nil
            if paintsInk {
                let fallback = e.textColor ?? cxSettings.viewDefaults.textForeground
                var ink = live(.textColor) ?? color(Props.TEXT_COLOR, fallback)
                if let groupInk = el.groupColor, let group = parent?.group, group > 0 {
                    ink = ink.mix(with: groupInk, t: group)
                    paint.pointer.x = max(paint.pointer.x, group)
                }
                paint.colors[MotionGatePaint.cText] = ink.scaleAlpha(alpha)
            }
            paint.sizes[MotionGatePaint.sRadius] = e.radius
            paint.sizes[MotionGatePaint.sBorder] = width
            paint.sizes[MotionGatePaint.sBlur] = e.blur
            paint.sizes[MotionGatePaint.sBackdrop] = el.backdropBlur
            if let (index, sh) = resolvedShadows(for: id, authored: el.shadows).enumerated().first(where: { !$0.element.inset }) {
                let tracked = index < shadowColorProps.count ? color(shadowColorProps[index], sh.color) : sh.color
                paint.colors[MotionGatePaint.cShadow] = ((index == 0 ? live(.shadowColor) : nil) ?? tracked).scaleAlpha(alpha)
                paint.sizes[MotionGatePaint.sShadow] = sh.blur + abs(sh.spread) + max(abs(sh.x), abs(sh.y))
            }
            let stops: (Color, Color)?
            if let g = el.runtimeExtras[RenderExtrasKey.radialGradient] as? RenderRadialGradientSpec,
               let first = g.stops.first, let last = g.stops.last {
                let end = g.stops.count - 1
                stops = (color(radialStopProps[0], first.color), end < radialStopProps.count ? color(radialStopProps[end], last.color) : last.color)
            } else if let g = el.runtimeExtras[RenderExtrasKey.linearGradient] as? RenderLinearGradientSpec,
                      let first = g.stops.first, let last = g.stops.last {
                stops = (first.color, last.color)
            } else {
                switch el.gradient {
                case let .linear(top, bottom, _), let .radial(top, bottom): stops = (top, bottom)
                case nil: stops = nil
                }
            }
            if let (top, bottom) = stops {
                paint.colors[MotionGatePaint.cGradient] = (live(.gradientTop) ?? top).scaleAlpha(alpha)
                paint.gradientEnd = (live(.gradientBottom) ?? bottom).scaleAlpha(alpha)
            }
            if let outline = el.elOutline, outline.width > 0 {
                paint.colors[MotionGatePaint.cOutline] = outline.color
            } else if el.focusRingWidth > 0 {
                paint.colors[MotionGatePaint.cOutline] = el.focusRingColor ?? .transparent
            }
            paint.effect = (el.runtimeExtras[RenderExtrasKey.effectSpec] as? RenderEffectSpec)?.data
            paint.image = el.pixelsPayload.map { ($0.id, $0.generation) }
            paint.rank = UInt32(rank)
            paint.intent = (parent?.intent ?? 0) | (el.runtimeExtras[MotionGateExtraKey.motionIntent] as? UInt16 ?? 0)
            paint.instant = (parent?.instant ?? false) || el.hasInstantChanges || el.runtimeExtras[MotionGateExtraKey.instantChanges] as? Bool == true
            paint.atOnce = MotionGatePaintUtils.atOnceBits(
                motion: el.runtimeExtras[MotionGateExtraKey.ownMotionNone] as? Bool ?? false,
                blur: el.blurMotionOverride.map { $0.animation.curve == .instant }
            )
            paints[key] = paint
        }
        return paints
    }
}
