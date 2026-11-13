import Foundation
import OpenCodeTheme
import Rune
import RuneKit

// MARK: - Icons & File Tree

private func galleryGrid(minWidth: Float, gap: Float, cells: [El<GalleryState>]) -> El<GalleryState> {
    let columns = max(Int(floor((672.0 + gap) / (minWidth + gap))), 1)
    let width = (672.0 - gap * Float(columns - 1)) / Float(columns)
    var rowsCol: El<GalleryState> = col().gap(gap)
    var idx = 0
    while idx < cells.count {
        let end = min(idx + columns, cells.count)
        var r: El<GalleryState> = row().gap(gap)
        for j in idx..<end {
            r = r.child(cells[j].w(width))
        }
        rowsCol = rowsCol.child(r)
        idx = end
    }
    return rowsCol
}

private func iconLabel(_ k: Kit, _ label: String) -> El<GalleryState> {
    text(label).font(TextStyle(size: 12, weight: 440, lineHeight: 18)).color(k.c.textMuted).ellipsis()
}

func fileIconSamples(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let items: [(String, Bool)] = [
        ("README.md", false), ("package.json", false), ("tsconfig.json", false), ("index.ts", false),
        ("styles.css", false), ("logo.svg", false), ("photo.png", false), ("Dockerfile", false),
        (".env", false), ("src", true), ("public", true),
    ]
    let cells = items.map { path, dir in
        let glyph = dir ? OpenCodeFileIcons.folder(path, expanded: false) : OpenCodeFileIcons.file(path)
        return row().gap(8).itemsCenter()
            .child(icon(glyph, size: 16).color(k.c.textBase))
            .child(iconLabel(k, path))
    }
    return galleryGrid(minWidth: 120, gap: 12, cells: cells)
}

func fileIconFolder(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    row().child(icon(OpenCodeFileIcons.folder("src", expanded: true), size: 16).color(k.c.textBase))
}

func iconGallery(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let names = [
        "archive", "arrow-left", "arrow-right", "arrow-up-right", "branch", "check", "chevron-down", "close",
        "code-slash", "edit", "folder", "graduation-cap", "help", "magnifying-glass", "menu", "monitor",
        "outline-arrow-to-corner-top-right", "outline-copy", "outline-dots", "outline-eye", "outline-eye-slash",
        "outline-hexagonal-warning", "plus", "review", "settings-gear", "trash", "workspace",
    ]
    let cells: [El<GalleryState>] = names.map { name in
        let glyph = OpenCodeIcons.byName(name) ?? KitIcons.plus
        return col().gap(6).itemsCenter()
            .child(icon(glyph, size: 16).color(k.c.iconBase))
            .child(text(name).font(TextStyle(size: 10, weight: 440, lineHeight: 15)).color(k.c.textMuted).ellipsis())
    }
    return galleryGrid(minWidth: (672.0 - 48.0) / 5.0, gap: 12, cells: cells)
}

func iconCatalog(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let cells: [El<GalleryState>] = OpenCodeIcons.allData.map { item in
        row().gap(8).itemsCenter()
            .child(icon(item.svgIcon, size: 16).color(k.c.iconBase))
            .child(iconLabel(k, item.name))
    }
    return galleryGrid(minWidth: 128, gap: 8, cells: cells)
}

func fileIconCatalog(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let cells: [El<GalleryState>] = OpenCodeFileIcons.allData.map { item in
        row().gap(8).itemsCenter()
            .child(icon(item.svgIcon, size: 16).color(k.c.textBase))
            .child(iconLabel(k, item.name))
    }
    return galleryGrid(minWidth: 128, gap: 8, cells: cells)
}

func treeIconCatalog(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let dark = k.dark
    let cells: [El<GalleryState>] = OpenCodeTreeIcons.allTreeIcons.map { item in
        let svg = OpenCodeTreeIcons.icon(for: item.token)
        return row().gap(6).itemsCenter()
            .child(icon(svg, size: 16).color(k.c.iconMuted))
            .child(icon(svg, size: 16).color(item.color(dark: dark)))
            .child(iconLabel(k, item.token))
    }
    return galleryGrid(minWidth: 128, gap: 8, cells: cells)
}

func fileTreeStory(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let roots: [TreeItem<String>] = [
        TreeItem(id: ".git", label: ".git", isFolder: true, children: [
            TreeItem(id: ".git/HEAD", label: "HEAD"),
        ]),
        TreeItem(id: "src", label: "src", isFolder: true, children: [
            TreeItem(id: "src/util", label: "util", isFolder: true, children: [
                TreeItem(id: "src/util/format.ts", label: "format.ts"),
            ]),
            TreeItem(id: "src/money.ts", label: "money.ts"),
            TreeItem(id: "src/index.ts", label: "index.ts"),
        ]),
        TreeItem(id: "package.json", label: "package.json"),
        TreeItem(id: "README.md", label: "README.md"),
    ]
    return col().w(240).bg(k.c.bgBase).pt(4).px(8).child(
        k.tree(
            key: "files",
            roots: roots,
            expanded: s.fileExpanded,
            selected: s.fileSelected,
            onToggleExpand: { st, id in
                if !st.fileExpanded.remove(id).isNil { return }
                st.fileExpanded.insert(id)
            },
            onSelect: { st, id in
                st.fileSelected = id
            }
        ).h(8.0 * 28.0 + 8.0)
    )
}

private extension Optional {
    var isNil: Bool { self == nil }
}

// MARK: - Markdown & Mermaid

private let sampleMarkdown = """
# Rune markdown

Paragraphs take **strong**, *emphasis*, `inline code` and [links](https://rune.dev). Links are styled now and become clickable with rich-text spans.

## Lists

- First item
- Second item with `code`

1. One
2. Two

### Quote and rule

> Quoted text sits behind a rule.

---

#### A muted heading

```rust
fn main() {
    println!("hello");
}
```
"""

private let walkthroughMarkdown = """
## Retry with backoff

The client now retries failed requests with **exponential backoff**, capped at `max_delay`.

| Attempt | Delay | Jitter | Notes |
|:--------|------:|:------:|-------|
| 1 | 0 ms | none | first try |
| 2 | 200 ms | ±20% | after a `503` |
| 3 | 400 ms | ±20% | |
| 4 | 800 ms | ±20% | gives up after this one and reports the **last** error |

```diff
@@ -12,7 +12,9 @@ impl Client {
     pub async fn send(&self, req: Request) -> Result<Response> {
-        self.inner.send(req).await
+        retry(self.policy, || self.inner.send(req.clone()))
+            .await
+            .map_err(Error::from)
     }
```

```mermaid
flowchart LR
    A[Request] --> B{Status?}
    B -->|2xx| C([Done])
    B -->|503| D[Wait backoff]
    D --> E[(Retry budget)]
    E -.->|left| A
    E -->|spent| F[Report error]
```
"""

private let diagramsMarkdown = """
```mermaid
graph TD
    subgraph client [Client]
        UI[Web app] --> Cache[(Local cache)]
    end
    subgraph edge [Edge]
        LB{{Load balancer}} --> W1[Worker 1] & W2[Worker 2]
    end
    UI ==> LB
    W1 --> DB[(Postgres)]
    W2 --> DB
```
"""

private let mermaidFlowSnippet = """
```mermaid
flowchart LR
    A[Client] --> B{Auth}
    B -->|valid| C([API])
    B -->|denied| D[401]
```
"""

private let mermaidChartsSnippet = """
```mermaid
pie title Pets
    "Dogs" : 386
    "Cats" : 85
```
"""

private let mermaidSequenceSnippet = """
```mermaid
sequenceDiagram
    actor U as User
    participant C as Client
    participant S as Server
    U->>+C: request
    C->>S: POST /items
    S-->>-U: 200 OK
```
"""

private let codeMarkdown = """
```tsx
export async function load(id: string) {
  const res = await fetch(`/api/users/${id}`);
  return res.ok ? res.json() : null;
}
```

```rust
fn backoff(n: u32) -> u64 {
    200 * 2u64.pow(n)
}
```

```swift
struct Job {
    let name: String
    var tries: Int = 3
}
```
"""

private let tableStylesMarkdown = """
| Field | Compared |
|---|---|
| title | yes |
| updatedAt | yes |
| draft cursor | no |

| Build | Files | Time | Size |
|:--|--:|--:|--:|\n| debug | 1,204 | 41.8 s | 118.4 MB |
| release | 1,204 | 71.0 s | 31.1 MB |
"""

private func mdCard(_ k: Kit, width: Float, source: String, key: String = "md") -> El<GalleryState> {
    col().w(width).child(k.markdown(source, key: key))
}

func markdownBasic(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: sampleMarkdown, key: "md-basic")
}

func markdownDiagrams(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 620, source: diagramsMarkdown, key: "md-diagrams")
}

func markdownLenient(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: "## Unclosed fence\n\n```rust\nlet x = 42;", key: "md-lenient")
}

func markdownMermaidShapes(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 620, source: diagramsMarkdown, key: "md-shapes")
}

func markdownMermaidCharts(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: mermaidChartsSnippet, key: "md-charts")
}

func markdownMermaidMaps(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 620, source: mermaidFlowSnippet, key: "md-maps")
}

func markdownMermaidGit(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 620, source: mermaidFlowSnippet, key: "md-git")
}

func markdownMermaidData(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 620, source: mermaidChartsSnippet, key: "md-data")
}

func markdownMermaidSystems(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 620, source: diagramsMarkdown, key: "md-systems")
}

func markdownMermaidFlows(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 620, source: mermaidSequenceSnippet, key: "md-flows")
}

func markdownMermaidHover(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 620, source: mermaidFlowSnippet, key: "md-hover")
}

func markdownMermaidPlan(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 620, source: mermaidFlowSnippet, key: "md-plan")
}

func markdownMermaidPlanZoomed(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 620, source: mermaidFlowSnippet, key: "md-plan-zoomed")
}

func markdownTableStyles(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: tableStylesMarkdown, key: "md-table")
}

func markdownCode(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 620, source: codeMarkdown, key: "md-code")
}

func markdownWalkthrough(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 680, source: walkthroughMarkdown, key: "md-walkthrough")
}

func markdownStreaming(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let n = Int(s.picked("md-stream", "60")) ?? 60
    let slice = String(sampleMarkdown.prefix(n))
    return col().w(560).gap(12)
        .child(k.button(key: "stream-more", "Stream more", variant: .neutral) { st, _ in
            let cur = Int(st.picked("md-stream", "60")) ?? 60
            st.pick["md-stream"] = "\(cur + 40)"
        })
        .child(k.markdown(slice, key: "md-stream"))
}

func markdownStreamTail(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    var unused: [El<GalleryState>] = []
    return markdownStreaming(s, k, &unused)
}

func markdownMermaidStreaming(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let cur = Int(s.picked("md-mstream", "60")) ?? 60
    let slice = String(mermaidFlowSnippet.prefix(cur))
    return col().w(560).gap(12)
        .child(k.button(key: "mstream-more", "Stream more", variant: .neutral) { st, _ in
            let v = Int(st.picked("md-mstream", "60")) ?? 60
            st.pick["md-mstream"] = "\(v + 30)"
        })
        .child(k.markdown(slice, key: "md-mstream"))
}
