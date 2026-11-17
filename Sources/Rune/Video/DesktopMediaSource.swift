#if canImport(CRuneMedia)
import Dispatch
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Keeps a downloaded, authenticated asset alive for the lifetime of its decoder.
final class DesktopMediaSource: Sendable {
    let url: URL
    private let temporaryDirectory: URL?

    init(request: MediaRequest) throws {
        let original = request.source.locationURL
        guard !request.source.isFile, !request.headers.isEmpty else {
            url = original
            temporaryDirectory = nil
            return
        }
        guard Self.isHTTP(original) else { throw DownloadError("Media request headers require HTTP or HTTPS") }

        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        #if os(Windows)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        #else
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #endif
        var destination = directory.appendingPathComponent("media")
        let ext = original.pathExtension
        if !ext.isEmpty, ext.count <= 16, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) {
            destination.appendPathExtension(ext)
        }
        do {
            try Self.download(original, headers: request.headers, to: destination)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
        url = destination
        temporaryDirectory = directory
    }

    deinit {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    private struct DownloadError: Error, CustomStringConvertible {
        let description: String
        init(_ message: String) { description = message }
    }

    private static func isHTTP(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased()) && url.host != nil
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }

    private static func download(_ original: URL, headers: [(name: String, value: String)], to file: URL) throws {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: RedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var url = original
        var allowHeaders = true
        for _ in 0...10 {
            var request = URLRequest(url: url)
            if allowHeaders {
                for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
            }
            let exchange = Exchange()
            let task = session.downloadTask(with: request) { location, response, error in
                exchange.finish(location: location, response: response, error: error, destination: file)
            }
            task.resume()
            let response = try exchange.wait()
            switch response.statusCode {
            case 200...299: return
            case 301, 302, 303, 307, 308:
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: url)?.absoluteURL, isHTTP(next) else {
                    throw DownloadError("Invalid HTTP media redirect")
                }
                allowHeaders = allowHeaders && sameOrigin(url, next)
                url = next
            default:
                throw DownloadError("Media server returned HTTP \(response.statusCode)")
            }
        }
        throw DownloadError("Too many HTTP media redirects")
    }

    /// Rebuild each redirected request explicitly so custom headers stay on their original origin.
    private final class RedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// One producer on URLSession's private queue publishes the result to the synchronous decoder.
    private final class Exchange: @unchecked Sendable {
        private let finished = DispatchSemaphore(value: 0)
        private var result: Result<HTTPURLResponse, any Error> = .failure(DownloadError("Missing HTTP media response"))

        func finish(location: URL?, response: URLResponse?, error: (any Error)?, destination: URL) {
            defer { finished.signal() }
            do {
                if let error { throw DownloadError("Media download failed (\((error as NSError).code))") }
                guard let response = response as? HTTPURLResponse else { throw DownloadError("Missing HTTP media response") }
                if (200...299).contains(response.statusCode) {
                    guard let location else { throw DownloadError("Missing downloaded media file") }
                    try FileManager.default.moveItem(at: location, to: destination)
                }
                result = .success(response)
            } catch {
                result = .failure(error)
            }
        }

        func wait() throws -> HTTPURLResponse {
            finished.wait()
            return try result.get()
        }
    }
}
#endif
