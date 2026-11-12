import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(WinSDK)
import WinSDK
#elseif canImport(WASILibc)
import WASILibc
#endif

internal final class LuauFolderWatcher: @unchecked Sendable {
    #if canImport(Darwin)
    private let queue = DispatchQueue(label: "rune.luau.watch", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fileDescriptors: [Int32] = []
    #endif
    private let lock = NSLock()
    private var saving: Bool = false
    private var readyResult: Result<(Sources, CompiledSources, Duration), ScriptError>?
    private var lastCompiled: (Sources, CompiledSources)?

    func start(
        directory: URL,
        entryPath: String,
        shared: SharedScriptState
    ) throws {
        stop()
        #if canImport(Darwin)
        try watchRecursive(directory: directory, root: directory, entryPath: entryPath, shared: shared)
        #endif
    }

    #if canImport(Darwin)
    private func watchRecursive(
        directory: URL,
        root: URL,
        entryPath: String,
        shared: SharedScriptState
    ) throws {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        fileDescriptors.append(fd)
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.handleChange(root: root, entryPath: entryPath, shared: shared)
        }
        src.resume()
        sources.append(src)

        if let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children {
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir {
                    try? watchRecursive(directory: child, root: root, entryPath: entryPath, shared: shared)
                }
            }
        }
    }

    private func handleChange(root: URL, entryPath: String, shared: SharedScriptState) {
        let nextSources: Sources
        do {
            nextSources = try Sources.fromDir(root).entry(entryPath)
        } catch {
            lock.lock()
            readyResult = .failure(ScriptError(kind: .missing, message: error.localizedDescription))
            lock.unlock()
            shared.mark()
            shared.wake()
            return
        }

        if let last = lastCompiled, last.0 == nextSources {
            return
        }

        lock.lock()
        saving = true
        lock.unlock()
        shared.mark()
        shared.wake()

        let start = ContinuousClock.now
        let compiledResult: Result<(Sources, CompiledSources, Duration), ScriptError>
        do {
            let compiled = try nextSources.compileFrom(lastCompiled?.1 ?? CompiledSources(
                modules: [:], configs: [:], parentConfig: nil, folder: nil, entry: entryPath
            ))
            let elapsed = start.duration(to: .now)
            lastCompiled = (nextSources, compiled)
            compiledResult = .success((nextSources, compiled, elapsed))
        } catch let err as ScriptError {
            compiledResult = .failure(err)
        } catch {
            compiledResult = .failure(ScriptError(kind: .runtime, message: error.localizedDescription))
        }

        lock.lock()
        saving = false
        readyResult = compiledResult
        lock.unlock()
        shared.mark()
        shared.wake()
    }
    #endif

    func takeReady() -> (saving: Bool, result: Result<(Sources, CompiledSources, Duration), ScriptError>?) {
        lock.lock()
        let s = saving
        let r = readyResult
        readyResult = nil
        lock.unlock()
        return (s, r)
    }

    func stop() {
        #if canImport(Darwin)
        for src in sources {
            src.cancel()
        }
        sources.removeAll()
        for fd in fileDescriptors {
            close(fd)
        }
        fileDescriptors.removeAll()
        #endif
    }

    deinit {
        stop()
    }
}
