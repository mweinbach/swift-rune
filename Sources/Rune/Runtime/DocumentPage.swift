import Foundation

/// The browser scrolls a canvas through a document. Its texture starts at `top` and
/// covers `band` points. Only `view` points are on screen at any one time.
internal struct RuntimeDocumentPage {
    var scroll: Float = 0
    var top: Float = 0
    var band: Float = 0
    var view: Float
    let originalFitHeight: Bool
}

extension Runtime {
    /// Uses natural root height for layout while keeping the render target the size of the canvas.
    public func pageMode(_ enabled: Bool = true) {
        guard enabled != isPageMode else { return }
        if enabled {
            documentPage = RuntimeDocumentPage(view: viewport.y, originalFitHeight: fitHeight)
            fitHeight = true
        } else if let page = documentPage {
            fitHeight = page.originalFitHeight
            documentPage = nil
        }
        needsCommit = true
        commitWhyPending |= CommitWhy.relayout
        updateScrollPositions(at: currentTime)
    }

    public var isPageMode: Bool { documentPage != nil }

    /// Natural root height in document points after the most recent layout.
    public var pageHeight: Float { max(0, flatNodes.first?.localSize.y ?? viewport.y) }
    public var pageOffset: Float { documentPage?.top ?? 0 }
    public var pageScrollY: Float { documentPage?.scroll ?? 0 }

    /// The visible window inside the canvas, in points relative to its top.
    public var pageWindow: (start: Float, height: Float) {
        guard let page = documentPage else { return (0, viewport.y) }
        return (page.scroll - page.top, page.view > 0 ? page.view : viewport.y)
    }

    @discardableResult
    public func setPageBand(_ band: Float, view: Float) -> Bool {
        guard var page = documentPage else { return false }
        let band = band.isFinite ? max(0, band) : 0
        let view = view.isFinite ? max(0, view) : 0
        guard page.band != band || page.view != view else { return false }
        page.band = band
        page.view = view
        return applyPagePosition(page, at: currentTime)
    }

    /// Receives the host's scroll position. Returns true only when a new band needs painting.
    @discardableResult
    public func setPageScroll(_ y: Float, at now: Double? = nil) -> Bool {
        guard var page = documentPage else { return false }
        let snapped = y.isFinite ? snapPage(y) : 0
        guard page.scroll != snapped else { return false }
        page.scroll = snapped
        return applyPagePosition(page, at: now ?? currentTime)
    }

    private func applyPagePosition(_ position: RuntimeDocumentPage, at now: Double) -> Bool {
        var page = position
        let margin: Float = 64
        if page.band <= page.view + 2 * margin {
            page.top = page.scroll
        } else if page.scroll < page.top + margin || page.scroll + page.view > page.top + page.band - margin {
            let centered = page.scroll - (page.band - page.view) * 0.5
            page.top = snapPage(min(max(0, centered), max(0, pageHeight - page.band)))
        }
        documentPage = page
        guard page.top != position.top else { return false }
        scrollMovedSinceLastFrame = true
        updateScrollPositions(at: now)
        return true
    }

    private func snapPage(_ y: Float) -> Float {
        let scale = max(pixelScale, 0.001)
        return (y * scale).rounded() / scale
    }

    /// Follows a native horizontal DOM scroller while preserving vertical scroll and its glide.
    @discardableResult
    public func setPageScrollX(_ path: String, x: Float) -> Bool {
        guard isPageMode, x.isFinite, let index = nodeByPath[path],
              flatNodes[index].el.layout.scrollAxes.contains(.horizontal),
              let extent = scrollMaxExtents[path] else { return false }
        let clamped = min(max(0, x), max(0, extent.x))
        guard abs((scrollOffsets[path]?.x ?? 0) - clamped) >= 0.01 else { return false }
        let moved = applyScrollOffsetRequest(path: path, x: clamped, y: nil, glide: nil, cut: true,
            animNow: cxSettings.scaledTime(at: currentTime), holdHover: false)
        if moved {
            scrollMovedSinceLastFrame = true
            updateScrollPositions(at: currentTime)
        }
        return moved
    }
}
