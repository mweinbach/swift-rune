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

private let sampleMarkdown = #"""
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
"""#

private let walkthroughMarkdown = #"""
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

```mermaid
sequenceDiagram
    autonumber
    actor U as User
    participant C as Client
    participant S as Server
    U->>+C: send(req)
    loop until success or budget spent
        C->>S: POST /items
        S--xC: 503 Unavailable
        Note right of S: overloaded
    end
    C-->>-U: Err(last error)
```
"""#

private let diagramsMarkdown = #"""
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
    W2 -.-> Q>Queue]
```

```mermaid
flowchart LR
    a([Stadium]) --> b[[Subroutine]] --> c((Circle)) --o d{Diamond}
    d --x e[/Lean/] <--> f[/Trapezoid\]
```

| Narrow | Table |
|---|---|
| wraps | when its column runs out of room, like this long cell does |

```mermaid
pie title Pets
    "Dogs" : 386
    "Cats" : 85
```

```mermaid
kanban
    Todo
        Write docs
```
"""#

private let lenientMarkdown = #"""
```mermaid
flowchart LR
    A[List + count] --> B[/items split view]
    B --> C[Details]
    C --> D[Pause / Resume / Delete]
    C -- --> D
```

```mermaid
flowchart LR
    a[setting.some_name] --> b[run_* + /go]
    c[(store -> row)] --> d[Item.Worker]
    d --> e[/api/v2/item]
```

```mermaid
classDiagram
    direction LR
    class Shape {
        <<trait>>
        +area() f32
    }
    class Circle {
        +radius f32
    }
    class Canvas {
        +shapes Vec~Shape~
        +draw()
    }
    Shape <|.. Circle
    Canvas o-- "many" Shape : holds
```

```mermaid
sequenceDiagram
    box Front
        actor U as User
        participant A as App
    end
    box Back
        participant S as Server
    end
    U->>A: open list
    rect rgb(80, 140, 220)
        A->>+S: fetch items
        S-->>-A: 20 items
    end
    A-->>U: show list
```
"""#

private let mermaidShapesMarkdown = #"""
```mermaid
flowchart LR
    a1[rect] ~~~ a2(rounded) ~~~ a3([stadium]) ~~~ a4[[subproc]]
    b1[(cyl)] ~~~ b2((circle)) ~~~ b3(((dbl-circ))) ~~~ b4>odd]
    c1{diam} ~~~ c2{{hex}} ~~~ c3[/lean-r/] ~~~ c4[\lean-l\]
    d1[/trap-b\] ~~~ d2[\trap-t/] ~~~ d3@{ shape: bang, label: "bang" } ~~~ d4@{ shape: cloud, label: "cloud" }
    e1@{ shape: notch-rect, label: "card" } ~~~ e2@{ shape: hourglass, label: "collate" } ~~~ e3@{ shape: bolt, label: "com-link" } ~~~ e4@{ shape: delay, label: "delay" }
    f1@{ shape: brace, label: "comment" } ~~~ f2@{ shape: brace-r, label: "brace-r" } ~~~ f3@{ shape: braces, label: "braces" } ~~~ f4@{ shape: text, label: "text" }
    g1@{ shape: h-cyl, label: "h-cyl" } ~~~ g2@{ shape: lin-cyl, label: "lin-cyl" } ~~~ g3@{ shape: curv-trap, label: "display" } ~~~ g4@{ shape: div-rect, label: "div-rect" }
    h1@{ shape: doc, label: "doc" } ~~~ h2@{ shape: lin-doc, label: "lin-doc" } ~~~ h3@{ shape: docs, label: "docs" } ~~~ h4@{ shape: tag-doc, label: "tag-doc" }
    i1@{ shape: tri, label: "extract" } ~~~ i2@{ shape: flip-tri, label: "manual file" } ~~~ i3@{ shape: win-pane, label: "win-pane" } ~~~ i4@{ shape: lin-rect, label: "lin-rect" }
    j1@{ shape: notch-pent, label: "loop limit" } ~~~ j2@{ shape: sl-rect, label: "manual input" } ~~~ j3@{ shape: st-rect, label: "processes" } ~~~ j4@{ shape: flag, label: "paper tape" }
    k1@{ shape: bow-rect, label: "stored data" } ~~~ k2@{ shape: tag-rect, label: "tag-rect" } ~~~ k3@{ shape: sm-circ } ~~~ k4@{ shape: f-circ }
    l1@{ shape: fr-circ } ~~~ l2@{ shape: cross-circ } ~~~ l3@{ shape: fork } ~~~ l4@{ shape: icon, form: circle, label: "icon" }
```
"""#

private let mermaidFlowsMarkdown = #"""
```mermaid
sequenceDiagram
    autonumber 10
    participant UI@{ "type": "boundary" }
    participant Ctl@{ "type": "control" }
    participant Db@{ "type": "database" }
    participant Q@{ "type": "queue" }
    UI->>Ctl: submit
    Ctl->>Db: save
    create participant Job
    Ctl->>Job: start
    Job->>Q: enqueue
    destroy Job
    Job-->>Ctl: done
    Note over UI,Ctl: saved
```

```mermaid
stateDiagram-v2
    [*] --> Ready
    state Ready {
        [*] --> Idle
        Idle --> Typing : key
        --
        [*] --> Offline
        Offline --> Online : connect
    }
    Ready --> split
    state split <<fork>>
    split --> Save
    split --> Sync
    state merge <<join>>
    Save --> merge
    Sync --> merge
    merge --> ok
    state ok <<choice>>
    ok --> [*] : fine
    ok --> Ready : retry
    note right of Save : writes to disk
```
"""#

private let mermaidChartsMarkdown = #"""
```mermaid
erDiagram
    CUSTOMER ||--o{ ORDER : places
    ORDER ||--|{ LINE-ITEM : contains
    PRODUCT |o..o{ LINE-ITEM : "listed in"
    CUSTOMER {
        string id PK
        string name
        string email UK "login"
    }
    ORDER {
        int id PK
        string customer FK
        date placed
    }
    LINE-ITEM {
        int qty
        decimal price
    }
```

```mermaid
gantt
    title Release 2.0
    dateFormat YYYY-MM-DD
    axisFormat %b %d
    excludes weekends
    section Build
    Design       :done, des, 2024-03-04, 4d
    Core engine  :active, core, after des, 8d
    Plugins      :plug, after des, 6d
    section Ship
    Beta         :crit, beta, after core plug, 4d
    Docs         :docs, after plug, 5d
    Release      :milestone, after beta docs, 0d
    Code freeze  :vert, 2024-03-18, 0d
```

```mermaid
pie showData title Where the time went
    "Building" : 42
    "Reviewing" : 23
    "Waiting on CI" : 18
    "Meetings" : 9
    "Other" : 4
```
"""#

private let mermaidMapsMarkdown = #"""
```mermaid
mindmap
  root((Rune))
    Layout
      Flex rows
      Virtual lists
      Text measure
    Motion
      Springs
      Transitions
    Platforms
      Mac
      iOS
      Web
    Diagrams
      Flowcharts
      Charts))new((
```

```mermaid
timeline
    title Shipping a release
    section Plan
        Week 1 : Scope : Design review
        Week 2 : Prototype
    section Build
        Week 3 : Core engine : Tests
        Week 4 : Plugins
    section Ship
        Week 5 : Beta : Docs
        Week 6 : Launch
```

```mermaid
journey
    title A first-time user
    section Discover
      Find the site: 4: User
      Read the docs: 3: User
    section Try
      Install: 2: User, CLI
      First build: 5: User, CLI
    section Share
      Tell a friend: 5: User
```
"""#

private let mermaidGitMarkdown = #"""
```mermaid
timeline
    title Rune
    2024 : First window
    2025 : Kit components : Motion
    2026 : Mermaid diagrams
```

```mermaid
gitGraph
    commit id: "init"
    commit id: "layout" tag: "v0.1"
    branch feature
    checkout feature
    commit id: "springs"
    commit id: "fix" type: REVERSE
    checkout main
    commit id: "docs" type: HIGHLIGHT
    merge feature id: "merge" tag: "v0.2"
    branch hotfix
    commit id: "patch"
    checkout main
    cherry-pick id: "patch"
```

```mermaid
quadrantChart
    title Reach and engagement
    x-axis Low Reach --> High Reach
    y-axis Low Engagement --> High Engagement
    quadrant-1 Expand
    quadrant-2 Promote
    quadrant-3 Re-evaluate
    quadrant-4 Improve
    Campaign A: [0.3, 0.6]
    Campaign B: [0.45, 0.23]
    Campaign C: [0.57, 0.69]
    Campaign D: [0.78, 0.34]
    Campaign E: [0.40, 0.34]
    Campaign F: [0.35, 0.78] radius: 8, color: #e8590c
```
"""#

private let mermaidDataMarkdown = #"""
```mermaid
xychart-beta
    title "Frame time by build"
    x-axis [debug, release, perf, wasm]
    y-axis "Milliseconds" 0 --> 20
    bar "p50" [16.2, 6.1, 5.8, 9.4]
    line "p99" [19.1, 8.3, 7.9, 13.2]
```

```mermaid
sankey-beta
Input,Layout,40
Input,Text,25
Layout,Paint,32
Layout,Idle,8
Text,Paint,25
Paint,GPU,50
Paint,Cache,7
```

```mermaid
block-beta
    columns 3
    app["App"]:3
    view["Views"] state[("State")] motion(["Motion"])
    block:core:2
        columns 2
        layout["Layout"] text["Text"]
    end
    gpu{{"wgpu"}}
    arrow<["frames"]>(down):3
    screen["Screen"]:3
    view --> layout
    state -- "reads" --> text
```
"""#

private let mermaidSystemsMarkdown = #"""
```mermaid
requirementDiagram
    requirement fast_start {
    id: 1
    text: First frame in 100 ms.
    risk: high
    verifymethod: test
    }
    performanceRequirement idle {
    id: 1.1
    text: An idle window draws nothing.
    risk: medium
    verifymethod: analysis
    }
    element runtime {
    type: crate
    docref: crates/rune
    }
    fast_start - contains -> idle
    runtime - satisfies -> fast_start
    runtime - verifies -> idle
```

```mermaid
C4Container
    title Notes app
    Person(user, "Writer", "Takes notes on a laptop")
    System_Boundary(app, "Notes") {
        Container(ui, "Window", "Rust, Rune", "Draws the editor")
        Container(sync, "Sync", "Rust", "Merges edits")
        ContainerDb(db, "Store", "SQLite", "Notes and history")
    }
    System_Ext(cloud, "Cloud backup", "Keeps a copy")
    Rel(user, ui, "Types in")
    Rel(ui, sync, "Sends edits")
    Rel(sync, db, "Reads and writes", "SQL")
    Rel(sync, cloud, "Uploads", "HTTPS")
```
"""#

private let mermaidHoverMarkdown = #"""
```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Loading : fetch
    Loading --> Ready : 200 OK
    Loading --> Failed : error
    Failed --> Loading : retry
    Ready --> [*]
```
"""#

private let mermaidPlanMarkdown = #"""
```mermaid
flowchart LR
  classDef done fill:#1f3d2a,stroke:#3fb950,color:#e6edf3
  classDef doing fill:#3d3416,stroke:#d29922,color:#e6edf3
  classDef waiting fill:#162a3d,stroke:#58a6ff,color:#e6edf3
  classDef blocked fill:#21262d,stroke:#6e7681,color:#c9d1d9

  subgraph PREP["Prep, done"]
    t12["t12 tokens carry byte spans"]:::done
    t07["t07 grammar table in groups"]:::done
  end

  subgraph S2["Stage 2: first pass on the new parser (the pilot)"]
    t31["t31 cache sees grammar edits"]:::waiting
    t35["t35 baseline = pinned release, built from source"]:::doing
    t44["t44 lint_unused, the pass rewritten"]:::doing
    t11["t11 old-vs-new compare hook"]:::doing
    t36["t36 link the new parser into the old tool"]:::blocked
    t37["t37 PILOT: the pass runs in the new build"]:::blocked
  end

  subgraph IR["AST track: the new parser reads the old tool's syntax trees"]
    t84["t84 formatter stops using the old evaluator"]:::doing
    t33["t33 AST binary format + reader"]:::blocked
    t34["t34 generate both sides from the grammar table"]:::blocked
    t38["t38 AST verifier, rewritten"]:::blocked
  end

  subgraph S3["Stage 3: formatter on the new parser"]
    t39["t39 layout, spacing, names"]:::blocked
    t40["t40 comments, literals, source maps"]:::blocked
    t41["t41 functions and core forms"]:::blocked
    t42["t42 imports and exports"]:::blocked
    t43["t43 macros, attribute glue"]:::blocked
    t45["t45 byte-exact match with the old one, at most 2x slower"]:::blocked
    t46["t46 the tool formats itself identically"]:::blocked
    t47["t47 delete the old formatter"]:::blocked
  end

  t31 --> t35 --> t36
  t84 --> t33 --> t34
  t33 --> t36
  t36 --> t37
  t11 --> t37
  t44 --> t37

  t34 --> t38
  t36 --> t38
  t34 --> t39
  t34 --> t40
  t39 --> t41
  t40 --> t41
  t41 --> t42
  t41 --> t43
  t42 --> t45
  t43 --> t45
  t36 --> t45
  t11 --> t45
  t45 --> t46 --> t47

  subgraph KEY["Key"]
    k1["done"]:::done
    k2["building now"]:::doing
    k3["built, waiting to land"]:::waiting
    k4["not started"]:::blocked
  end
```
"""#

private let tableStylesMarkdown = #"""
| Field | Compared |
|---|---|
| title | yes |
| updatedAt | yes |
| draft cursor | no |

| Build | Files | Time | Size |
|:--|--:|--:|--:|
| debug | 1,204 | 41.8 s | 118.4 MB |
| release | 1,204 | 71.0 s | 31.1 MB |
| perf | 1,211 | 69.6 s | 33.7 MB |

```diff
@@ -3,3 +3,3 @@ fields:
   title: compared
-  draft: compared
+  draft: ignored
```
"""#

private let codeMarkdown = #"""
```tsx
// Loads a user, then renders their card.
export async function load(id: string): Promise<User | null> {
  const res = await fetch(`/api/users/${id}`, { method: "GET" });
  return res.ok ? res.json() : null;
}
const Card = ({ user }: Props) => <div className="card">{user.name}</div>;
```

```rust
#[derive(Debug, Clone)]
pub struct Retry<'a> { name: &'a str, attempts: u32 }

fn backoff(n: u32) -> Duration {
    Duration::from_millis(200 * 2u64.pow(n)) // capped by the caller
}
```

```python
@dataclass
class Job:
    name: str
    tries: int = 3  # per run

    def label(self) -> str:
        return f"{self.name} ×{self.tries}" if self.tries > 1 else self.name
```

```go
func (s *Server) Serve(ctx context.Context) error {
	for job := range s.queue {
		if err := job.Run(ctx); err != nil {
			return fmt.Errorf("job %q: %w", job.Name, err)
		}
	}
	return nil
}
```

```sh
# Build, then ship the release.
FEATURES=markdown cargo build --release && echo "done in $SECONDS s"
if [ -n "$TAG" ]; then gh release create "$TAG" ./target/*.tar.gz; fi
```

```sql
SELECT u.id, count(*) AS posts
FROM users u JOIN posts p ON p.user_id = u.id
WHERE u.created_at > '2026-01-01' AND p.draft = false
GROUP BY u.id ORDER BY posts DESC LIMIT 10;
```

```yaml
name: ci
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-15 # Apple silicon
    timeout-minutes: 30
    steps:
      - run: cargo test --workspace
```
"""#

private let tailStreamChunks = [
    "Open **Settings ›",
    " Appearance** and pick *Dark*.\n\n- run `theme",
    " dark`\n- then ~~restart",
    "~~ nothing\n\nChanged:\n\n| File",
    " | Change |\n|---|---|\n| theme.rs | dark |\n",
]

private let diagramStreamSource = #"""
Here's the flow:

```mermaid
flowchart LR
    A[Request] --> B{Cached?}
    B -->|yes| C[Serve]
    B -->|no| D[Fetch]
    D --> E[(Store)]
    E --> C
```

And who talks to whom:

```mermaid
sequenceDiagram
    participant U as User
    participant A as App
    participant S as Server
    U->>A: Open
    A->>S: GET /items
    S-->>A: 200 OK
    A-->>U: Show list
```
"""#

func nextDrawnLine(_ src: String, from: Int) -> Int {
    func isQuiet(_ line: Substring) -> Bool {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t.hasPrefix("```") || t == "flowchart LR" || t == "sequenceDiagram"
    }
    let utf8 = src.utf8
    let clampedFrom = min(max(from, 0), utf8.count)
    let startIdx = utf8.index(utf8.startIndex, offsetBy: clampedFrom)
    let rest = src[startIdx...]
    let lines = rest.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
    var at = clampedFrom
    for (i, line) in lines.enumerated() {
        let byteLen = line.utf8.count + (i + 1 < lines.count ? 1 : 0)
        at += byteLen
        if !isQuiet(line) {
            break
        }
    }
    let remainingIdx = utf8.index(utf8.startIndex, offsetBy: min(at, utf8.count))
    let remainingLines = src[remainingIdx...].split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" })
    if remainingLines.allSatisfy(isQuiet) {
        return utf8.count
    }
    return at
}

private func mdCard(_ k: Kit, width: Float, source: String, key: String = "md") -> El<GalleryState> {
    col().w(width).child(k.markdown(source, key: key))
}

func markdownBasic(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: sampleMarkdown, key: "md-basic")
}

func markdownDiagrams(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 520, source: diagramsMarkdown, key: "md-diagrams")
}

func markdownLenient(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: lenientMarkdown, key: "md-lenient")
}

func markdownMermaidShapes(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: mermaidShapesMarkdown, key: "md-shapes")
}

func markdownMermaidCharts(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: mermaidChartsMarkdown, key: "md-charts")
}

func markdownMermaidMaps(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: mermaidMapsMarkdown, key: "md-maps")
}

func markdownMermaidGit(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: mermaidGitMarkdown, key: "md-git")
}

func markdownMermaidData(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: mermaidDataMarkdown, key: "md-data")
}

func markdownMermaidSystems(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: mermaidSystemsMarkdown, key: "md-systems")
}

func markdownMermaidFlows(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: mermaidFlowsMarkdown, key: "md-flows")
}

func markdownMermaidHover(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 560, source: mermaidHoverMarkdown, key: "md-hover")
}

func markdownMermaidPlan(_: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    mdCard(k, width: 680, source: mermaidPlanMarkdown, key: "md-plan")
}

func markdownMermaidPlanZoomed(_ s: GalleryState, _ k: Kit, _ overlays: inout [El<GalleryState>]) -> El<GalleryState> {
    col().w(680).scale(3.0).child(markdownMermaidPlan(s, k, &overlays))
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
    let isStreaming = slice.count < sampleMarkdown.count
    return col().w(560).gap(12)
        .child(k.button(key: "stream-more", "Stream more", variant: .neutral) { st, _ in
            let cur = Int(st.picked("md-stream", "60")) ?? 60
            st.pick["md-stream"] = "\(cur + 40)"
        })
        .child(k.markdown(slice, key: "md-stream", searchQuery: nil, activeMatch: nil, streaming: isStreaming))
}

func markdownStreamTail(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let n = min(Int(s.picked("md-tail-stream", "0")) ?? 0, tailStreamChunks.count)
    let src = tailStreamChunks.prefix(n).joined()
    return col().w(560).gap(12)
        .child(k.button(key: "stream-more", "Stream more", variant: .neutral) { st, _ in
            let cur = Int(st.picked("md-tail-stream", "0")) ?? 0
            st.pick["md-tail-stream"] = "\(cur + 1)"
        })
        .child(k.markdown(src, key: "md-tail-stream", searchQuery: nil, activeMatch: nil, streaming: n < tailStreamChunks.count))
}

func markdownMermaidStreaming(_ s: GalleryState, _ k: Kit, _: inout [El<GalleryState>]) -> El<GalleryState> {
    let end = min(Int(s.picked("md-diagram-stream", "0")) ?? 0, diagramStreamSource.utf8.count)
    let utf8 = diagramStreamSource.utf8
    let endIdx = utf8.index(utf8.startIndex, offsetBy: end)
    let slice = String(diagramStreamSource[..<endIdx])
    return col().w(560).gap(12)
        .child(k.button(key: "stream-more", "Stream more", variant: .neutral) { st, _ in
            let cur = min(Int(st.picked("md-diagram-stream", "0")) ?? 0, diagramStreamSource.utf8.count)
            st.pick["md-diagram-stream"] = "\(nextDrawnLine(diagramStreamSource, from: cur))"
        })
        .child(k.markdown(slice, key: "md-mstream", searchQuery: nil, activeMatch: nil, streaming: end < utf8.count))
}
