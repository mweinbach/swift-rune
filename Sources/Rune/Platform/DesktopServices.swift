#if os(Windows) || os(Linux)
import CRuneDesktopServices
import Foundation
#if os(Linux)
import CRuneLinux
#endif

enum DesktopServices {
    #if os(Linux)
    private final class HostWork {
        let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    // Enter the UI thread before taking Clipboard's mutation lock. A timer
    // expiring a secret and a simultaneous UI paste must never wait on each other.
    static func onLinuxHost<T>(_ body: () -> T) -> T {
        withoutActuallyEscaping(body) { body in
            var result: T?
            let work = HostWork { result = .some(body()) }
            let ran = withExtendedLifetime(work) {
                rune_desktop_linux_call({ context in
                    guard let context else { return }
                    Unmanaged<HostWork>.fromOpaque(context).takeUnretainedValue().run()
                }, Unmanaged.passUnretained(work).toOpaque())
            }
            if ran != 0, let result { return result }
            return body()
        }
    }

    static func connectLinuxHost(windowID: UInt32 = 0) {
        rune_desktop_linux_set_wheel_scope(rune_linux_collecting_native_input)
        rune_desktop_linux_connect(windowID)
        rune_linux_set_altgr_resolver(rune_desktop_linux_right_alt_is_altgr)
    }
    static func pumpLinuxHost() { rune_desktop_linux_pump() }
    static func disconnectLinuxHost() { rune_desktop_linux_disconnect() }

    static func writePrimarySelection(_ text: String) {
        var value = text
        value.withUTF8 { rune_linux_primary_write($0.baseAddress, $0.count) }
    }

    private final class PrimaryRead {
        let complete: @Sendable (String?) -> Void
        init(_ complete: @escaping @Sendable (String?) -> Void) { self.complete = complete }
    }

    static func readPrimarySelection(_ completion: @escaping @Sendable (String?) -> Void) {
        let pending = Unmanaged.passRetained(PrimaryRead(completion))
        rune_linux_primary_read({ context, bytes, count in
            guard let context else { return }
            let request = Unmanaged<PrimaryRead>.fromOpaque(context).takeRetainedValue()
            let text = bytes.flatMap { String(bytes: UnsafeBufferPointer(start: $0, count: count), encoding: .utf8) }
            request.complete(text)
        }, pending.toOpaque())
    }
    #endif

    private static let plain = "text/plain;charset=utf-8"
    private static let windowsRGBA = "application/x-rune-windows-rgba8"
    private static let windowsPaths = "application/x-rune-windows-file-paths"
    private static let reserved: Set<String> = [
        plain, "text/plain", "text/html", "text/rtf", "image/png", "text/uri-list",
        windowsPaths, windowsRGBA, Clipboard.concealedPasteboardType, "x-kde-passwordManagerHint",
    ]

    static var clipboardRevision: Int { Int(rune_clipboard_revision()) }

    private static func filePath(_ url: URL) -> String? {
        guard url.isFileURL, !url.path(percentEncoded: false).utf8.contains(0) else { return nil }
        return url.withUnsafeFileSystemRepresentation { $0.map(String.init(cString:)) }
    }

    static func write(_ payload: RichClipboardPayload) -> Int? {
        guard let list = rune_mime_create() else { return nil }
        defer { rune_mime_free(list) }
        func add(_ type: String, _ data: Data) -> Bool {
            guard !type.utf8.contains(0) else { return false }
            return data.withUnsafeBytes { raw in
                rune_mime_add(list, type, raw.bindMemory(to: UInt8.self).baseAddress, raw.count) != 0
            }
        }
        if !payload.content.text.isEmpty || !payload.isRich {
            #if os(Windows)
            let text = payload.content.text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "\r\n")
            #else
            let text = payload.content.text
            #endif
            guard add(plain, Data(text.utf8)) else { return nil }
        }
        if let html = payload.content.html {
            #if os(Windows)
            let data = ClipboardHTMLSanitizer.packCFHTML(html)
            #else
            let data = Data(html.utf8)
            #endif
            guard add("text/html", data) else { return nil }
        }
        if let rtf = payload.content.rtf, !add("text/rtf", Data(rtf.utf8)) { return nil }
        if let image = payload.image ?? payload.content.image {
            guard add("image/png", image.pngData) else { return nil }
            #if os(Windows)
            if let png = ClipboardImage.fromPNG(image.pngData),
               UInt64(png.width) * UInt64(png.height) <= (64 * 1024 * 1024 - 8) / 4,
               let rgba = png.decodeRGBA() {
                var bitmap = Data()
                withUnsafeBytes(of: png.width.littleEndian) { bitmap.append(contentsOf: $0) }
                withUnsafeBytes(of: png.height.littleEndian) { bitmap.append(contentsOf: $0) }
                bitmap.append(rgba)
                // The PNG remains available when the second representation exceeds the transfer limit.
                _ = add(windowsRGBA, bitmap)
            }
            #endif
        }
        let files = payload.files.filter(\.isFileURL)
        if !files.isEmpty {
            #if os(Windows)
            var data = Data()
            for file in files {
                guard let path = filePath(file) else { return nil }
                data.append(contentsOf: path.utf8)
                data.append(0)
            }
            guard add(windowsPaths, data) else { return nil }
            #else
            let uris = files.map(\.absoluteString).joined(separator: "\r\n") + "\r\n"
            guard add("text/uri-list", Data(uris.utf8)) else { return nil }
            #endif
        }
        for (type, data) in payload.customPayloads where !reserved.contains(type) {
            guard add(type, data) else { return nil }
        }
        if payload.isConcealed, !add(Clipboard.concealedPasteboardType, Data()) { return nil }
        let revision = rune_clipboard_write(list, payload.isConcealed ? 1 : 0)
        return revision >= 0 ? Int(revision) : nil
    }

    static func read(sanitizeHTML: Bool) -> RichClipboardPayload {
        guard let list = rune_clipboard_read() else { return RichClipboardPayload() }
        defer { rune_mime_free(list) }
        var formats: [String: Data] = [:]
        for index in 0..<rune_mime_count(list) {
            var length = 0
            guard let type = rune_mime_type(list, index),
                  let bytes = rune_mime_bytes(list, index, &length) else { continue }
            formats[String(cString: type)] = Data(bytes: bytes, count: length)
        }
        let rawText = formats[plain].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        #if os(Windows)
        let text = rawText.replacingOccurrences(of: "\r\n", with: "\n")
        #else
        let text = rawText
        #endif
        #if os(Windows)
        var html = formats["text/html"].flatMap(ClipboardHTMLSanitizer.unpackCFHTML)
        #else
        var html = formats["text/html"].flatMap { String(data: $0, encoding: .utf8) }
        #endif
        if sanitizeHTML, let raw = html { html = RichClipboardPayload.sanitizeHTML(raw) }
        let rtf = formats["text/rtf"].flatMap { String(data: $0, encoding: .utf8) }
        var image = formats["image/png"].flatMap(ClipboardImage.fromPNG)
        #if os(Windows)
        if image == nil, let bitmap = formats[windowsRGBA], bitmap.count >= 8 {
            let (width, height) = bitmap.withUnsafeBytes { bytes in
                (UInt32(littleEndian: bytes.loadUnaligned(as: UInt32.self)),
                 UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
            }
            image = ClipboardImage.fromRGBA(width: width, height: height, rgba: bitmap.dropFirst(8))
        }
        #endif
        let files: [URL]
        if let data = formats[windowsPaths] {
            files = data.split(separator: 0).compactMap {
                String(bytes: $0, encoding: .utf8).map { URL(fileURLWithPath: $0) }
            }
        } else if let data = formats["text/uri-list"], let text = String(data: data, encoding: .utf8) {
            files = text.split(whereSeparator: \.isNewline).compactMap {
                guard !$0.hasPrefix("#"), let url = URL(string: String($0)), url.isFileURL else { return nil }
                return url
            }
        } else {
            files = []
        }
        return RichClipboardPayload(
            content: ClipboardContent(text, html: html, rtf: rtf, image: image, files: files),
            image: image, files: files, customPayloads: formats.filter { !reserved.contains($0.key) },
            isConcealed: formats[Clipboard.concealedPasteboardType] != nil
                || formats["x-kde-passwordManagerHint"] == Data("secret".utf8)
        )
    }

    static func clear(expected: Int? = nil) -> Bool {
        rune_clipboard_clear(Int64(expected ?? -1)) != 0
    }

    static func openURL(_ normalized: String) throws {
        guard rune_desktop_open_url(UrlOpener.percentEncodeNonAscii(normalized)) != 0 else {
            throw OpenUrlError.failed("the desktop has no available handler for this URL")
        }
    }

    static func choose(kind: FileDialogKind, options: FileDialogOptions) throws -> [URL]? {
        guard let picker = rune_picker_create() else { throw FileDialogError("could not create file chooser") }
        defer { rune_picker_free(picker) }
        for filter in options.filters where !filter.extensions.isEmpty {
            let patterns = filter.extensions.map { "*." + $0 }.joined(separator: ";")
            guard rune_picker_filter(picker, filter.name, patterns) != 0 else {
                throw FileDialogError("invalid file chooser filter")
            }
        }
        let result = rune_picker_show(
            picker, kind == .save ? 1 : 0, kind == .folder ? 1 : 0,
            options.allowsMultipleSelection ? 1 : 0, options.title,
            options.directory.flatMap(filePath) ?? "", options.fileName ?? ""
        )
        if result == 0 { return nil }
        guard result > 0 else { throw FileDialogError("the desktop file chooser is unavailable") }
        return (0..<rune_picker_count(picker)).compactMap { index in
            rune_picker_path(picker, index).map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }
}
#endif
