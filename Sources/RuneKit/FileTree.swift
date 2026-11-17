import Foundation
import Rune
#if canImport(Darwin) && canImport(CoreFoundation)
import CoreFoundation
#endif

/// A node of a file tree: a folder (`isDirectory`) or a file carrying optional metadata (`rune_kit::tree::FileNode`).
public struct FileNode<Data: Sendable>: Sendable {
    /// What the row shows: the file or folder name, or `a/b/c` for compacted single-child folders.
    public var name: String
    /// The path from the root, which is also the node's id.
    public var path: String
    public var isDirectory: Bool
    /// The file's data; `nil` for folders.
    public var data: Data?

    public var dir: Bool { isDirectory }

    public init(name: String, path: String, isDirectory: Bool, data: Data? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.data = data
    }

    public func label() -> String {
        name
    }

    /// The folder or file icon for this node (`FileTreeBuilder.fileIcon(for:)`).
    public func icon(isOpen: Bool) -> SVGIcon {
        if isDirectory {
            return isOpen ? KitIcons.folderOpen : KitIcons.folder
        }
        return FileTreeBuilder.fileIcon(for: name)
    }
}

extension FileNode: Equatable where Data: Equatable {}

/// Builds `TreeModel<FileNode<Data>>` (and legacy `TreeItem<String>`) trees from slash-separated file paths
/// (`rune_kit::tree::FileTree`).
public struct FileTreeBuilder: Sendable {
    public var compactFolders: Bool
    public var directoriesFirst: Bool
    public var key: String

    public init(compactFolders: Bool = true, directoriesFirst: Bool = true, key: String = "files") {
        self.compactFolders = compactFolders
        self.directoriesFirst = directoriesFirst
        self.key = key
    }

    /// Show a chain of single-folder folders as one `a/b/c` row (on by default).
    public func compactFolders(_ on: Bool) -> FileTreeBuilder {
        var copy = self
        copy.compactFolders = on
        return copy
    }

    /// Sort folders before files (on by default); off, they mix by name.
    public func dirsFirst(_ on: Bool) -> FileTreeBuilder {
        var copy = self
        copy.directoriesFirst = on
        return copy
    }

    /// The model's row-key prefix (`"files"` by default).
    public func key(_ key: String) -> FileTreeBuilder {
        var copy = self
        copy.key = key
        return copy
    }

    /// Returns the appropriate `KitIcons` glyph for a file name by extension (`rsplit_once('.')`: dotless names return `KitIcons.file`).
    public static func fileIcon(for name: String) -> SVGIcon {
        let ext: String
        if let dot = name.lastIndex(of: ".") {
            ext = String(name[name.index(after: dot)...]).lowercased()
        } else {
            ext = ""
        }
        switch ext {
        case "rs", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "go", "swift", "c", "h", "cc", "cpp",
             "hpp", "m", "mm", "java", "kt", "rb", "php", "cs", "zig", "lua", "sh", "bash", "zsh",
             "fish", "wgsl", "glsl", "metal", "html", "css", "scss", "vue", "svelte", "sql", "ex",
             "exs", "hs", "ml", "scala", "dart":
            return KitIcons.fileCode
        case "md", "mdx", "txt", "rst", "adoc", "json", "jsonc", "toml", "yaml", "yml", "lock",
             "xml", "csv", "ini", "cfg", "conf", "env":
            return KitIcons.fileText
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "ico", "bmp", "tiff", "avif", "heic":
            return KitIcons.fileImage
        default:
            return KitIcons.file
        }
    }

    /// Compares names as people sort them (`rune::text::compare_names` / `natural_cmp`):
    /// OS collator with numeric ordering and case/width insensitivity, falling back to exact
    /// UTF-8 code-unit order so the comparison is total (`"A"` < `"a"`).
    public static func naturalCompare(_ a: String, _ b: String) -> ComparisonResult {
        let primary = collate(a, b)
        if primary != .orderedSame {
            return primary
        }
        let ab = a.utf8
        let bb = b.utf8
        if ab.elementsEqual(bb) {
            return .orderedSame
        }
        return ab.lexicographicallyPrecedes(bb) ? .orderedAscending : .orderedDescending
    }

    private static func collate(_ a: String, _ b: String) -> ComparisonResult {
        #if canImport(Darwin) && canImport(CoreFoundation)
        let flags: CFStringCompareFlags = [
            .compareCaseInsensitive,
            .compareNumerically,
            .compareLocalized,
            .compareWidthInsensitive,
        ]
        let cfA = a as CFString
        let cfB = b as CFString
        let result = CFStringCompareWithOptionsAndLocale(
            cfA,
            cfB,
            CFRange(location: 0, length: CFStringGetLength(cfA)),
            flags,
            CFLocaleCopyCurrent()
        )
        switch result {
        case .compareLessThan: return .orderedAscending
        case .compareGreaterThan: return .orderedDescending
        case .compareEqualTo: return .orderedSame
        @unknown default: return naturalASCIIFallback(a, b)
        }
        #elseif canImport(FoundationInternationalization) || os(Windows)
        return a.compare(b, options: [.caseInsensitive, .numeric, .widthInsensitive], range: nil, locale: .current)
        #else
        return naturalASCIIFallback(a, b)
        #endif
    }

    private static func naturalASCIIFallback(_ a: String, _ b: String) -> ComparisonResult {
        var x = a.unicodeScalars.makeIterator()
        var y = b.unicodeScalars.makeIterator()
        var nx = x.next()
        var ny = y.next()

        func isDigit(_ s: Unicode.Scalar) -> Bool { s.value >= 0x30 && s.value <= 0x39 }

        while let cx = nx, let cy = ny {
            if isDigit(cx) && isDigit(cy) {
                var sx = ""
                var curX: Unicode.Scalar? = cx
                while let d = curX, isDigit(d) {
                    sx.unicodeScalars.append(d)
                    curX = x.next()
                }
                nx = curX

                var sy = ""
                var curY: Unicode.Scalar? = cy
                while let d = curY, isDigit(d) {
                    sy.unicodeScalars.append(d)
                    curY = y.next()
                }
                ny = curY

                let mx = sx.drop { $0 == "0" }
                let my = sy.drop { $0 == "0" }
                if mx.count != my.count {
                    return mx.count < my.count ? .orderedAscending : .orderedDescending
                }
                if mx != my {
                    return mx < my ? .orderedAscending : .orderedDescending
                }
            } else {
                let lx = String(cx).lowercased()
                let ly = String(cy).lowercased()
                if lx != ly {
                    return lx < ly ? .orderedAscending : .orderedDescending
                }
                nx = x.next()
                ny = y.next()
            }
        }
        if nx == nil && ny == nil { return .orderedSame }
        return nx == nil ? .orderedAscending : .orderedDescending
    }

    private final class DirBox<D> {
        var dirNames: [String] = []
        var dirs: [String: DirBox<D>] = [:]
        var files: [(String, D)] = []

        func dir(_ name: String) -> DirBox<D> {
            if let existing = dirs[name] {
                return existing
            }
            let created = DirBox<D>()
            dirNames.append(name)
            dirs[name] = created
            return created
        }
    }

    private static func buildTrie<D>(_ files: [(String, D)]) -> DirBox<D> {
        let root = DirBox<D>()
        for (rawPath, data) in files {
            let trimmed = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty else { continue }
            var parts = trimmed.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard let fileName = parts.popLast() else { continue }
            var cursor = root
            for dirName in parts {
                cursor = cursor.dir(dirName)
            }
            cursor.files.append((fileName, data))
        }
        return root
    }

    /// Builds a sorted `TreeModel<FileNode<Data>>` from `(path, data)` pairs.
    public func build<Data: Sendable>(_ files: [(String, Data)]) -> TreeModel<FileNode<Data>> {
        let root = Self.buildTrie(files)
        var model = TreeModel<FileNode<Data>>(key: key)

        func emit(_ box: DirBox<Data>, parent: String?, prefix: String) {
            for dirName in box.dirNames {
                guard let subBox = box.dirs[dirName] else { continue }
                var name = dirName
                var path = prefix.isEmpty ? dirName : "\(prefix)/\(dirName)"
                var current = subBox
                while compactFolders && current.files.isEmpty && current.dirNames.count == 1,
                      let childName = current.dirNames.first,
                      let childBox = current.dirs[childName] {
                    name = "\(name)/\(childName)"
                    path = "\(path)/\(childName)"
                    current = childBox
                }
                model.insert(
                    parent: parent,
                    id: path,
                    data: FileNode(name: name, path: path, isDirectory: true, data: nil)
                )
                emit(current, parent: path, prefix: path)
            }
            for (fileName, data) in box.files {
                let path = prefix.isEmpty ? fileName : "\(prefix)/\(fileName)"
                // If a file shares a folder's path (`a` and `a/b`), `insert` returns false and drops it.
                model.insert(
                    parent: parent,
                    id: path,
                    data: FileNode(name: fileName, path: path, isDirectory: false, data: data)
                )
            }
        }

        emit(root, parent: nil, prefix: "")
        let df = directoriesFirst
        model.sortBy { a, b in
            if df && a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return Self.naturalCompare(a.name, b.name) == .orderedAscending
        }
        return model
    }

    /// Builds sorted legacy `TreeItem<String>` roots from `(path, data)` pairs.
    public func buildTreeItems<Data: Sendable>(_ files: [(path: String, data: Data)]) -> [TreeItem<String>] {
        let root = Self.buildTrie(files.map { ($0.path, $0.data) })

        func emit(_ box: DirBox<Data>, prefix: String) -> [TreeItem<String>] {
            var dirItems: [TreeItem<String>] = []
            var folderPaths: Set<String> = []
            for dirName in box.dirNames {
                guard let subBox = box.dirs[dirName] else { continue }
                var label = dirName
                var path = prefix.isEmpty ? dirName : "\(prefix)/\(dirName)"
                var current = subBox
                while compactFolders && current.files.isEmpty && current.dirNames.count == 1,
                      let childName = current.dirNames.first,
                      let childBox = current.dirs[childName] {
                    label = "\(label)/\(childName)"
                    path = "\(path)/\(childName)"
                    current = childBox
                }
                folderPaths.insert(path)
                let children = emit(current, prefix: path)
                dirItems.append(TreeItem(id: path, label: label, isFolder: true, children: children))
            }

            let fileItems: [TreeItem<String>] = box.files.compactMap { fileName, _ in
                let path = prefix.isEmpty ? fileName : "\(prefix)/\(fileName)"
                if folderPaths.contains(path) { return nil }
                return TreeItem(id: path, label: fileName, isFolder: false, children: [])
            }

            if directoriesFirst {
                let sortedDirs = dirItems.sorted { Self.naturalCompare($0.label, $1.label) == .orderedAscending }
                let sortedFiles = fileItems.sorted { Self.naturalCompare($0.label, $1.label) == .orderedAscending }
                return sortedDirs + sortedFiles
            } else {
                return (dirItems + fileItems).sorted { Self.naturalCompare($0.label, $1.label) == .orderedAscending }
            }
        }

        return emit(root, prefix: "")
    }
}

/// Upstream alias (`rune_kit::tree::FileTree`).
public typealias FileTree = FileTreeBuilder

extension Kit {
    /// Renders a file tree from slash-separated paths using `FileTreeBuilder` and legacy `Kit.tree`.
    public func fileTree<State>(
        key: String = "file-tree",
        paths: [String],
        expanded: Set<String>,
        selected: String?,
        compactFolders: Bool = true,
        onToggle: @escaping (inout State, String) -> Void,
        onSelect: @escaping (inout State, String) -> Void
    ) -> El<State> {
        let items = FileTreeBuilder(compactFolders: compactFolders).buildTreeItems(paths.map { ($0, ()) })
        return tree(
            key: key,
            roots: items,
            expanded: expanded,
            selected: selected,
            onToggleExpand: onToggle,
            onSelect: onSelect
        )
    }
}
