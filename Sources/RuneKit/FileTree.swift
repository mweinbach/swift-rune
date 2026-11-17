import Foundation
import Rune

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

extension FileNode: Equatable where Data: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.path.utf8.elementsEqual(rhs.path.utf8) &&
            lhs.isDirectory == rhs.isDirectory && lhs.data == rhs.data
    }
}

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
        let bytes = name.utf8
        guard let dot = bytes.lastIndex(of: 0x2e) else { return KitIcons.file }
        let suffix = bytes[bytes.index(after: dot)...]
        guard suffix.allSatisfy({ $0 < 128 }) else { return KitIcons.file }
        let ext = String(decoding: suffix, as: UTF8.self).lowercased()
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
        nameOrder()(a, b)
    }

    /// A sort uses one snapshot of the interface language for every sibling comparison.
    private static func nameOrder() -> (String, String) -> ComparisonResult {
        RuneCollation.nameOrder(languageTag: TextLanguageRegistry.currentLanguageTag())
    }

    private final class DirBox<D> {
        var orderedDirs: [(name: String, dir: DirBox<D>)] = []
        var dirsByName: [KitSourceKey: DirBox<D>] = [:]
        var files: [(String, D)] = []

        func dir(_ name: String) -> DirBox<D> {
            let key = KitSourceKey(name)
            if let existing = dirsByName[key] {
                return existing
            }
            let created = DirBox<D>()
            orderedDirs.append((name, created))
            dirsByName[key] = created
            return created
        }
    }

    private static func buildTrie<D>(_ files: [(String, D)]) -> DirBox<D> {
        let root = DirBox<D>()
        for (rawPath, data) in files {
            let parts = rawPath.utf8.split(separator: 0x2f)
            guard let fileName = parts.last else { continue }
            var cursor = root
            for dirName in parts.dropLast() {
                cursor = cursor.dir(String(decoding: dirName, as: UTF8.self))
            }
            cursor.files.append((String(decoding: fileName, as: UTF8.self), data))
        }
        return root
    }

    /// Builds a sorted `TreeModel<FileNode<Data>>` from `(path, data)` pairs.
    public func build<Data: Sendable>(_ files: [(String, Data)]) -> TreeModel<FileNode<Data>> {
        let root = Self.buildTrie(files)
        var model = TreeModel<FileNode<Data>>(key: key)

        func emit(_ box: DirBox<Data>, parent: String?, prefix: String) {
            for (dirName, subBox) in box.orderedDirs {
                var name = dirName
                var path = prefix.isEmpty ? dirName : "\(prefix)/\(dirName)"
                var current = subBox
                while compactFolders && current.files.isEmpty && current.orderedDirs.count == 1,
                      let child = current.orderedDirs.first {
                    name = "\(name)/\(child.name)"
                    path = "\(path)/\(child.name)"
                    current = child.dir
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
        let compare = Self.nameOrder()
        model.sortBy { a, b in
            if df && a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            return compare(a.name, b.name) == .orderedAscending
        }
        return model
    }

    /// Builds sorted legacy `TreeItem<String>` roots from `(path, data)` pairs.
    public func buildTreeItems<Data: Sendable>(_ files: [(path: String, data: Data)]) -> [TreeItem<String>] {
        let root = Self.buildTrie(files.map { ($0.path, $0.data) })
        let compare = Self.nameOrder()

        func emit(_ box: DirBox<Data>, prefix: String) -> [TreeItem<String>] {
            var dirItems: [TreeItem<String>] = []
            var folderPaths: Set<KitSourceKey> = []
            for (dirName, subBox) in box.orderedDirs {
                var label = dirName
                var path = prefix.isEmpty ? dirName : "\(prefix)/\(dirName)"
                var current = subBox
                while compactFolders && current.files.isEmpty && current.orderedDirs.count == 1,
                      let child = current.orderedDirs.first {
                    label = "\(label)/\(child.name)"
                    path = "\(path)/\(child.name)"
                    current = child.dir
                }
                folderPaths.insert(KitSourceKey(path))
                let children = emit(current, prefix: path)
                dirItems.append(TreeItem(id: path, label: label, isFolder: true, children: children))
            }

            let fileItems: [TreeItem<String>] = box.files.compactMap { fileName, _ in
                let path = prefix.isEmpty ? fileName : "\(prefix)/\(fileName)"
                if folderPaths.contains(KitSourceKey(path)) { return nil }
                return TreeItem(id: path, label: fileName, isFolder: false, children: [])
            }

            if directoriesFirst {
                let sortedDirs = dirItems.sorted { compare($0.label, $1.label) == .orderedAscending }
                let sortedFiles = fileItems.sorted { compare($0.label, $1.label) == .orderedAscending }
                return sortedDirs + sortedFiles
            } else {
                return (dirItems + fileItems).sorted { compare($0.label, $1.label) == .orderedAscending }
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
