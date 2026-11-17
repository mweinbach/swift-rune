import Foundation

/// The browser owns the object URLs. Send each resident PNG once and release it on eviction.
struct WebCursorProjection {
    private struct Entry {
        var image: CursorImage
        var id: Int
    }

    private struct Update: Encodable {
        var css: String?
        var id: Int?
        var png: Data?
        var evict: Int?
        var error: String?
    }

    private var previous: Cursor?
    private var images: [Entry] = []
    private var nextID = 0

    mutating func update(_ cursor: Cursor) -> Data? {
        guard cursor != previous else { return nil }
        previous = cursor
        var value = Update()
        switch cursor {
        case .default: value.css = "default"
        case .pointer: value.css = "pointer"
        case .text: value.css = "text"
        case .grab: value.css = "grab"
        case .grabbing: value.css = "grabbing"
        case .notAllowed: value.css = "not-allowed"
        case .move: value.css = "move"
        case .resizeColumn: value.css = "col-resize"
        case .resizeRow: value.css = "row-resize"
        case .crosshair: value.css = "crosshair"
        case .cell: value.css = "cell"
        case .zoomIn: value.css = "zoom-in"
        case .zoomOut: value.css = "zoom-out"
        case .hidden: value.css = "none"
        case .image(let image):
            if let index = images.firstIndex(where: { $0.image == image }) {
                let entry = images.remove(at: index)
                images.append(entry)
                value.id = entry.id
            } else {
                if images.count == 32 { value.evict = images.removeFirst().id }
                nextID += 1
                images.append(Entry(image: image, id: nextID))
                value.id = nextID
                do {
                    value.css = try image.cssCursor(url: "{url}")
                    value.png = Data(image.bytes)
                } catch {
                    value.css = "default"
                    value.error = "Rune cursor image (\(image.bytes.count) bytes) shows the arrow: \(error)"
                }
            }
        }
        return try? JSONEncoder().encode(value)
    }
}
