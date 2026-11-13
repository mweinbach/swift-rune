import Foundation
import Testing
@testable import Rune
@testable import RuneKit
@testable import OpenCodeTheme

@MainActor
@Suite("tests/markdown_fixture.rs #136-#143: Markdown golden element trees with OpenCodeTheme")
struct MarkdownFixtureGoldenTests {
    private static let doc = #"""
## What's happening

The server sends a heartbeat every **10 seconds**, but `stream.ts` only reconnects on an `error` event. When the machine sleeps, the TCP connection goes half-open: the *client* never sees an error, so it waits forever. See [the retry notes](https://example.com/retry) for the long version, which is deliberately wordy so that this paragraph has to wrap onto several lines at every width.

Two smaller issues make it worse:

- `backoff.ts` resets its delay on *every* message, so a flapping server is retried at full speed.
- The sidebar store ignores `session.updated` events that arrive before the first list fetch.
  - A nested point with `code` in it.

### The fix

Treat silence as failure. If no event or heartbeat arrives for 25 seconds, close the stream and reconnect with backoff:

```ts
const QUIET_MS = 25_000

function watchdog(stream: EventStream, reconnect: () => void) {
  let timer = setTimeout(fire, QUIET_MS) // restarted on every message
  function fire() {
    stream.close()
    reconnect()
  }
  stream.on("message", () => {
    clearTimeout(timer)
    timer = setTimeout(fire, QUIET_MS)
  })
}
```

```
plain text fence, no language
  keeps its   spacing
```

> Quoted advice: the reset must wait for a healthy minute.
> It spans two lines.

1. **Watchdog**: closes and reopens the stream after 25 s of silence.
2. **Backoff**: the delay only resets after a minute of healthy traffic.
3. **Sidebar**: early events are queued until the list loads.

- [x] watchdog added
- [ ] reconnect test
- [ ] docs

| Case | Delay | Resets |
| :--- | ---: | :---: |
| flapping | 1s, 2s, 4s | no |
| healthy minute | 1s | yes |
| capped | 30s | no |

---

```mermaid
graph TD
  A[Event arrives] --> B{Quiet for 25 s?}
  B -- yes --> C[Close stream]
  C --> D[Reconnect with backoff]
  B -- no --> A
```

```mermaid
sequenceDiagram
  participant C as Client
  participant S as Server
  C->>S: open stream
  S-->>C: heartbeat
  Note over C: 25 s of silence
  C->>S: reconnect
```

```mermaid
graph LR
  this is not valid
```

Done. All 14 tests in `src/net` pass.
"""#

    private static let streaming = "I'll add a test that drives the backoff with a fake clock.\n\n- a flapping server that fails right after each message;\n- a stream that stays healthy for a minute\n\n| Case | Delay |\n| --- | --- |\n| flapping | 1s |\n| healthy | 1"

    private static let streamingFence = "Here is the test:\n\n```ts\nimport { expect, test } from \"bun:test\"\n\ntest(\"flapping keeps backing off\", () => {\n  const clock = fakeClock()\n  const delays = [1, 2, 3].map(() => b.fail())"

    private struct GoldenNode: Decodable, Equatable {
        let path: String
        let role: String
        let rect: [Double]
        let fill: String
        let key: String?
        let text: String?
        let color: String?
        let opacity: Double?
    }

    private struct S: Sendable {
        let src: String
        let dark: Bool
        let streaming: Bool
    }

    private static func rustPath(from swiftPath: String) -> String {
        let parts = swiftPath.split(separator: "/").map { seg -> String in
            if seg.hasPrefix("@") {
                return String(seg.dropFirst())
            } else {
                return "#\(seg)"
            }
        }
        return parts.joined(separator: "/")
    }

    private static func renderElements(src: String, dark: Bool, streaming: Bool, width: Float) -> [ElementInfo] {
        HeadlessRunner.registerFonts(OpenCodeTheme.fonts)
        var els: [ElementInfo] = []
        Theme.withBlend(false) {
            withFontFamilies(sans: OpenCodeTheme.families.sans, mono: OpenCodeTheme.families.mono) {
                let rt = Runtime<S>(
                    state: S(src: src, dark: dark, streaming: streaming),
                    viewport: Vec2(width, 900.0),
                    pixelScale: 2.0,
                    systemDark: dark
                ) { s, _ in
                    let kit = OpenCodeTheme.kit(dark: s.dark)
                    return col().wFull().p(16).child(
                        Markdown(s.src).style(MarkdownStyle.fromKit(kit)).streaming(s.streaming).build(kit)
                    )
                }
                rt.srgbBlend = false
                _ = rt.frame(at: 0.0)
                _ = rt.frame(at: 1.0)
                els = rt.elements()
            }
        }
        return els
    }

    private static func loadGolden(_ name: String) throws -> [GoldenNode] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("\(name).json")
        let raw = try String(contentsOf: url, encoding: .utf8)
        let normalized = raw.replacingOccurrences(
            of: #"\\u\{([0-9a-fA-F]{4})\}"#,
            with: #"\\u$1"#,
            options: .regularExpression
        )
        let data = Data(normalized.utf8)
        return try JSONDecoder().decode([GoldenNode].self, from: data)
    }

    // Strip only Rune `El.isolate` LRI/PDI wrappers around prose tokens (`What's`, `half-open`,
    // and outer wrapper around inline code) because `Sources/Rune` does not expose `El.isolate`;
    // inline code isolates emitted by `RuneKit` (`\u{202F}\u{202F}\u{2066}...\u{2069}\u{202F}\u{202F}`)
    // are kept verbatim so any `RuneKit` isolate regression still fails.
    private static func stripCoreElIsolates(_ s: String) -> String {
        let pad = "\u{202F}\u{202F}"
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            let next = s.index(after: i)
            if ch == "\u{2066}" {
                if s[..<i].hasSuffix(pad) {
                    out.append(ch)
                }
            } else if ch == "\u{2069}" {
                if s[next...].hasPrefix(pad) {
                    out.append(ch)
                }
            } else {
                out.append(ch)
            }
            i = next
        }
        return out
    }

    private static func roleMatches(_ actual: ElementRole, expected: String) -> Bool {
        switch expected {
        case "image": return actual == .image      // Rust "image" <-> Swift ElementRole.image ("img")
        case "cell": return actual == .gridCell    // Rust "cell" <-> Swift ElementRole.gridCell ("gridcell")
        case "figure": return actual == .group     // Swift ElementRole has no `.figure`; Mermaid card uses `.group`
        default: return actual.rawValue == expected
        }
    }

    private static func rectTolerance(for node: GoldenNode) -> Double {
        // CoreText vs upstream parley/swash glyph advances differ by <= 0.50pt in table cells
        // and Mermaid label boxes (including 0.052pt on `e:A>B`/`e:B>A` label height).
        // All blocks, headings, lists, blockquotes, code fences, rules, and vertical positions match <= 0.02pt.
        let inTableOrMermaid = node.role == "table"
            || node.path.contains("/th")
            || node.path.contains("/card/diagram")
            || node.path.range(of: #"/(r|s)\d+(/|$)"#, options: .regularExpression) != nil
        return inTableOrMermaid ? 0.51 : 0.02
    }

    private func checkGolden(_ name: String, src: String, dark: Bool, streaming: Bool, width: Float) throws {
        let expected = try Self.loadGolden(name)
        let actual = Self.renderElements(src: src, dark: dark, streaming: streaming, width: width)

        // `RuneMermaid` does not emit `hover:*/#0/lit` image placeholders inside hover groups.
        let expFiltered = expected.filter { $0.key != "lit" }
        if actual.count != expFiltered.count {
            let aSet = Set(actual.map { "\(Self.rustPath(from: $0.path))|\($0.key ?? "")" })
            let eSet = Set(expFiltered.map { "\($0.path)|\($0.key ?? "")" })
            let missing = expFiltered.filter { !aSet.contains("\($0.path)|\($0.key ?? "")") }.prefix(15).map { "\($0.path)(\($0.role),\($0.key ?? ""))" }
            let extra = actual.filter { !eSet.contains("\(Self.rustPath(from: $0.path))|\($0.key ?? "")") }.prefix(15).map { "\(Self.rustPath(from: $0.path))(\($0.role.rawValue),\($0.key ?? ""))" }
            Issue.record("\(name): count actual=\(actual.count) expected=\(expFiltered.count); missing=\(missing); extra=\(extra)")
            return
        }

        for (i, (a, e)) in zip(actual, expFiltered).enumerated() {
            let aPath = Self.rustPath(from: a.path)
            #expect(aPath == e.path, "\(name)[\(i)] path: \(aPath) != \(e.path)")
            #expect(Self.roleMatches(a.role, expected: e.role), "\(name)[\(i)] (\(e.path)) role: \(a.role.rawValue) != \(e.role)")
            #expect(a.key == e.key, "\(name)[\(i)] (\(e.path)) key")
            let expectedText = e.text.map(Self.stripCoreElIsolates)
            #expect(a.text == expectedText, "\(name)[\(i)] (\(e.path)) text")
            #expect(a.fill.hex() == e.fill, "\(name)[\(i)] (\(e.path)) fill: \(a.fill.hex()) != \(e.fill)")
            #expect(a.textColor?.hex() == e.color, "\(name)[\(i)] (\(e.path)) color: \(a.textColor?.hex() ?? "nil") != \(e.color ?? "nil")")
            let expectedOpacity = Float(e.opacity ?? 1.0)
            #expect(abs(a.opacity - expectedOpacity) <= 0.002, "\(name)[\(i)] (\(e.path)) opacity: \(a.opacity) != \(expectedOpacity)")
            let tol = Self.rectTolerance(for: e)
            for c in 0..<4 {
                #expect(abs(Double(a.rect[c]) - e.rect[c]) <= tol, "\(name)[\(i)] (\(e.path)) rect[\(c)]: \(a.rect[c]) != \(e.rect[c])")
            }
        }
    }

    @Test("tests/markdown_fixture.rs #136: session_dark")
    func sessionDark() throws {
        try checkGolden("session-dark", src: Self.doc, dark: true, streaming: false, width: 720.0)
    }

    @Test("tests/markdown_fixture.rs #137: session_light")
    func sessionLight() throws {
        try checkGolden("session-light", src: Self.doc, dark: false, streaming: false, width: 720.0)
    }

    @Test("tests/markdown_fixture.rs #138: narrow_dark")
    func narrowDark() throws {
        try checkGolden("narrow-dark", src: Self.doc, dark: true, streaming: false, width: 340.0)
    }

    @Test("tests/markdown_fixture.rs #139: narrow_light")
    func narrowLight() throws {
        try checkGolden("narrow-light", src: Self.doc, dark: false, streaming: false, width: 340.0)
    }

    @Test("tests/markdown_fixture.rs #140: streaming_table_dark")
    func streamingTableDark() throws {
        try checkGolden("streaming-table-dark", src: Self.streaming, dark: true, streaming: true, width: 720.0)
    }

    @Test("tests/markdown_fixture.rs #141: streaming_table_light")
    func streamingTableLight() throws {
        try checkGolden("streaming-table-light", src: Self.streaming, dark: false, streaming: true, width: 720.0)
    }

    @Test("tests/markdown_fixture.rs #142: streaming_fence_dark")
    func streamingFenceDark() throws {
        try checkGolden("streaming-fence-dark", src: Self.streamingFence, dark: true, streaming: true, width: 720.0)
    }

    @Test("tests/markdown_fixture.rs #143: streaming_fence_light")
    func streamingFenceLight() throws {
        try checkGolden("streaming-fence-light", src: Self.streamingFence, dark: false, streaming: true, width: 720.0)
    }
}
