import Foundation
import Rune

/// A node of a file tree: a folder (`isDirectory`) or a file carrying optional metadata (`rune_kit::tree::FileNode`).
public struct FileNode<Data: Sendable>: Sendable {
    public var name: String
    public var path: String
    public var isDirectory: Bool
    public var data: Data?

    public init(name: String, path: String, isDirectory: Bool, data: Data? = nil) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.data = data
    }

    public func icon(isOpen: Bool) -> SVGIcon {
        if isDirectory {
            return isOpen ? KitIcons.folderOpen : KitIcons.folder
        }
        return FileTreeBuilder.fileIcon(for: name)
    }
}

/// Builds hierarchical `TreeItem<String>` / `FileNode` trees from slash-separated file paths (`rune_kit::tree::FileTree`).
public struct FileTreeBuilder: Sendable {
    public var compactFolders: Bool
    public var directoriesFirst: Bool

    public init(compactFolders: Bool = true, directoriesFirst: Bool = true) {
        self.compactFolders = compactFolders
        self.directoriesFirst = directoriesFirst
    }

    /// Returns the appropriate `KitIcons` glyph for a file name by extension.
    public static func fileIcon(for name: String) -> SVGIcon {
        let ext = name.split(separator: ".").last.map { $0.lowercased() } ?? ""
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

    /// Natural case-insensitive comparison (`"file2"` < `"file10"`).
    public static func naturalCompare(_ a: String, _ b: String) -> ComparisonResult {
        a.localizedStandardCompare(b)
    }

    private final class DirBox<D> {
        var dirs: [String: DirBox<D>] = [:]
        var files: [(String, D)] = []
    }

    /// Builds sorted `TreeItem<String>` roots from `(path, data)` pairs.
    public func buildTreeItems<Data: Sendable>(_ files: [(path: String, data: Data)]) -> [TreeItem<String>] {
        let root = DirBox<Data>()
        for (rawPath, data) in files {
            let trimmed = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty else { continue }
            var parts = trimmed.split(separator: "/").map(String.init).filter { !$0.isEmpty }
            guard let fileName = parts.popLast() else { continue }
            var cursor = root
            for dirName in parts {
                if let existing = cursor.dirs[dirName] {
                    cursor = existing
                } else {
                    let created = DirBox<Data>()
                    cursor.dirs[dirName] = created
                    cursor = created
                }
            }
            cursor.files.append((fileName, data))
        }

        func emit(_ box: DirBox<Data>, prefix: String) -> [TreeItem<String>] {
            var dirItems: [TreeItem<String>] = []
            for (dirName, subBox) in box.dirs {
                var label = dirName
                var path = prefix.isEmpty ? dirName : "\(prefix)/\(dirName)"
                var current = subBox
                while compactFolders && current.files.isEmpty && current.dirs.count == 1,
                      let (childName, childBox) = current.dirs.first {
                    label = "\(label)/\(childName)"
                    path = "\(path)/\(childName)"
                    current = childBox
                }
                let children = emit(current, prefix: path)
                dirItems.append(TreeItem(id: path, label: label, isFolder: true, children: children))
            }

            let fileItems: [TreeItem<String>] = box.files.map { fileName, _ in
                let path = prefix.isEmpty ? fileName : "\(prefix)/\(fileName)"
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

extension Kit {
    /// Renders a file tree from slash-separated paths using `FileTreeBuilder` and `Kit.tree`.
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
