import Foundation

/// Presents each queued menu once and pairs answers with the window and menu that opened it.
@MainActor
final class WebPopupSession<State> {
    private let host: WebAppHost<State>
    private var serial: UInt64 = 0
    private var showing: String?

    init(_ host: WebAppHost<State>) { self.host = host }

    func take() -> Data? {
        let runtime = host.runtime
        if showing != nil && runtime.popupIsOpen { return nil }
        let needsHide = showing != nil
        showing = nil
        while let next = runtime.takePopup() {
            guard case .success(let show) = next else { continue }
            let x: Float, y: Float, width: Float
            switch show.anchor {
            case .point(let px, let py): (x, y, width) = (px, py, 0)
            case .rect(let rect):
                let positioned = show.menu.entries.contains {
                    guard case .item(let item) = $0 else { return false }
                    return item.id == show.menu.selectedId
                }
                (x, y, width) = (rect.left, positioned ? rect.top : rect.bottom, rect.width)
            }
            serial &+= 1
            let token = String(serial)
            let payload: [String: Any] = ["menu": show.menu.toJSONObject(), "token": token,
                "x": x, "y": y, "minWidth": width, "dark": runtime.systemDark]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
                try? runtime.resolvePopup(nil)
                continue
            }
            showing = token
            return data
        }
        return needsHide ? Data("{}".utf8) : nil
    }

    func answer(_ id: String?, token: String?) -> Bool {
        guard let token, showing == token, host.runtime.popupIsOpen else { return false }
        showing = nil
        do { try host.runtime.resolvePopup(id) }
        catch { try? host.runtime.resolvePopup(nil) }
        host.syncField(activate: true)
        return true
    }

    func secondaryClaim() -> Data? {
        let runtime = host.runtime
        var claim = ["kind": runtime.secondaryClaim()]
        if runtime.selectionState.coordinator.phase.selection != nil,
           let text = runtime.copySelectionText(), !text.isEmpty {
            claim["selection"] = text
        }
        let point = runtime.pointerPosition
        var index = runtime.hitTest(at: point, predicate: { _ in true })?.node.index
        while let i = index {
            let node = runtime.flatNodes[i]
            if node.el.isSecure || node.el.handlers.editLens != nil { break }
            if let link = runtime.linkIndex(atPath: node.path, at: point),
               node.el.textLinks.indices.contains(link) {
                claim["href"] = node.el.textLinks[link].id
                break
            }
            if let url = node.el.linkURL {
                claim["href"] = url
                break
            }
            if claim["text"] == nil { claim["text"] = node.el.plainText }
            index = node.parentIndex
        }
        return try? JSONEncoder().encode(claim)
    }
}
