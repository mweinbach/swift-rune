import Foundation
import Rune
import RuneKit
import RuneMotion

/// Port of `crates/rune-kit/examples/diff.rs`.
///
/// Renders a multi-file PR diff in `DiffView` (texts, unified patch rename/binary, inline review
/// annotation, segmented unified/split toggle, and `--scene` presets `split`, `scrolled`, `folded`,
/// `long`, `line-info`, and `added`).

private let oldRs = """
use std::time::Duration;

/// How long to wait before trying a request again.
pub struct Backoff {
    base: Duration,
    max: Duration,
    attempt: u32,
}

impl Backoff {
    pub fn new(base: Duration, max: Duration) -> Backoff {
        Backoff { base, max, attempt: 0 }
    }

    /// The wait before the next attempt.
    pub fn next(&mut self) -> Duration {
        let wait = self.base * 2u32.pow(self.attempt);
        self.attempt += 1;
        wait.min(self.max)
    }

    pub fn reset(&mut self) {
        self.attempt = 0;
    }

    pub fn attempts(&self) -> u32 {
        self.attempt
    }

    pub fn base(&self) -> Duration {
        self.base
    }

    pub fn max(&self) -> Duration {
        self.max
    }

    pub fn is_fresh(&self) -> bool {
        self.attempt == 0
    }

    pub fn exhausted(&self, limit: u32) -> bool {
        self.attempt >= limit
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doubles_until_the_cap() {
        let mut b = Backoff::new(Duration::from_millis(100), Duration::from_secs(1));
        assert_eq!(b.next(), Duration::from_millis(100));
        assert_eq!(b.next(), Duration::from_millis(200));
    }
}
"""

private let newRs = """
use std::time::Duration;

/// How long to wait before trying a request again, with jitter so clients spread out.
pub struct Backoff {
    base: Duration,
    max: Duration,
    attempt: u32,
    jitter: f32,
}

impl Backoff {
    pub fn new(base: Duration, max: Duration) -> Backoff {
        Backoff { base, max, attempt: 0, jitter: 0.2 }
    }

    /// The wait before the next attempt, give or take `jitter` of it.
    pub fn next(&mut self, roll: f32) -> Duration {
        let wait = self.base.saturating_mul(2u32.saturating_pow(self.attempt));
        self.attempt += 1;
        wait.min(self.max).mul_f32(1.0 + self.jitter * (roll * 2.0 - 1.0))
    }

    pub fn reset(&mut self) {
        self.attempt = 0;
    }

    pub fn attempts(&self) -> u32 {
        self.attempt
    }

    pub fn base(&self) -> Duration {
        self.base
    }

    pub fn max(&self) -> Duration {
        self.max
    }

    pub fn is_fresh(&self) -> bool {
        self.attempt == 0
    }

    pub fn exhausted(&self, limit: u32) -> bool {
        self.attempt >= limit
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn doubles_until_the_cap() {
        let mut b = Backoff::new(Duration::from_millis(100), Duration::from_secs(1));
        b.jitter = 0.0;
        assert_eq!(b.next(0.5), Duration::from_millis(100));
        assert_eq!(b.next(0.5), Duration::from_millis(200));
    }
}
"""

private let oldTs = """
export async function fetchWithRetry(url: string, tries = 3): Promise<Response> {
\tfor (let i = 0; i < tries; i++) {
\t\tconst res = await fetch(url)
\t\tif (res.ok) return res
\t}
\tthrow new Error(`gave up on ${url}`)
}
"""

private let newTs = """
export async function fetchWithRetry(url: string, tries = 3, signal?: AbortSignal): Promise<Response> {
\tlet last: Response | undefined
\tfor (let i = 0; i < tries; i++) {
\t\tlast = await fetch(url, { signal })
\t\tif (last.ok) return last
\t\tawait sleep(backoff(i))
\t}
\tthrow new Error(`gave up on ${url} after ${tries} tries (${last?.status})`)
}
"""

private let oldToml = "[retry]\nbase_ms = 100\nmax_ms = 1000\n"
private let newToml = "[retry]\nbase_ms = 100\nmax_ms = 1000\njitter = 0.2\n"

private let patchText = """
diff --git a/src/net/retry.rs b/src/net/backoff_policy.rs
similarity index 100%
rename from src/net/retry.rs
rename to src/net/backoff_policy.rs
diff --git a/assets/retry-curve.png b/assets/retry-curve.png
new file mode 100644
index 0000000..4b825dc
Binary files /dev/null and b/assets/retry-curve.png differ
"""

private let longOld = """
pub fn describe(&self) -> String {
    format!("retry {} times starting at {:?}, doubling up to {:?}", self.limit, self.base, self.max)
}

pub fn jitter_for(&self, attempt: u32) -> Duration {
    self.base * 2u32.pow(attempt)
}

pub fn clamp(&self, wait: Duration) -> Duration {
    wait.min(self.max)
}
"""

private let longNew = """
pub fn describe(&self) -> String {
    format!("retry {} times starting at {:?}, doubling up to {:?}, with {:.0}% jitter so clients that failed together spread out when they retry", self.limit, self.base, self.max, self.jitter * 100.0)
}

pub fn jitter_for(&self, attempt: u32) -> Duration {
    let wait = self.base * 2u32.pow(attempt);
    wait.mul_f64(1.0 + self.jitter * (self.rng.next_f64() - 0.5) * 2.0).min(self.max + self.max.mul_f64(self.jitter))
}

pub fn clamp(&self, wait: Duration) -> Duration {
    wait.min(self.max)
}
"""

private let addedMd = """
# Retry backoff

Waits double from `base_ms` up to `max_ms`, then spread by `jitter`.
"""

private let deletedToml = "[retry]\nlegacy = true\ndelay_ms = 250\n"

public struct ReviewState: Sendable {
    public var diff: DiffState
    public var composing: DiffLineRange?
    public var foldRow: DiffFoldRow

    public init(
        diff: DiffState,
        composing: DiffLineRange? = nil,
        foldRow: DiffFoldRow = .summary
    ) {
        self.diff = diff
        self.composing = composing
        self.foldRow = foldRow
    }
}

public func initialReviewState() -> ReviewState {
    var files: [FileDiff] = [
        FileDiff.fromTexts(path: "src/net/backoff.rs", old: oldRs, new: newRs),
        FileDiff.fromTexts(path: "web/fetch.ts", old: oldTs, new: newTs),
        FileDiff.fromTexts(path: "config/retry.toml", old: oldToml, new: newToml),
    ]
    files.append(contentsOf: FileDiff.parse(patchText))
    let annotation = DiffAnnotation(
        id: "c0",
        file: 0,
        side: .new,
        line: 19,
        body: "jitter"
    )
    let diff = DiffState(files: files, annotations: [annotation])
    return ReviewState(diff: diff, composing: nil, foldRow: .summary)
}

private func foldedDiff(lineCount: Int, changes: [Int: (oldLine: String, newLine: String)]) -> FileDiff {
    var oldLines: [String] = []
    var newLines: [String] = []
    oldLines.reserveCapacity(lineCount)
    newLines.reserveCapacity(lineCount)
    for n in 1...lineCount {
        if let pair = changes[n] {
            oldLines.append(pair.oldLine)
            newLines.append(pair.newLine)
        } else {
            let ctx = "    line \(n)"
            oldLines.append(ctx)
            newLines.append(ctx)
        }
    }
    return FileDiff.fromTexts(
        path: "config/retry.rs",
        old: oldLines.joined(separator: "\n"),
        new: newLines.joined(separator: "\n"),
        context: 4
    )
}

private func longFoldedState() -> DiffState {
    DiffState(
        diff: foldedDiff(
            lineCount: 60,
            changes: [
                8: ("    attempts: 3,", "    attempts: 5,"),
                45: ("    jitter: 0.0,", "    jitter: 0.2,"),
            ]
        )
    )
}

private func commentCard(_ k: Kit, _ annotation: DiffAnnotation) -> El<ReviewState> {
    let body = "Jitter keeps a crowd of clients that failed together from retrying together. "
        + "0.2 matches what the server's rate limiter assumes."
    let header: El<ReviewState> = row()
        .gap(8)
        .itemsCenter()
        .child(text("Reviewer").font(k.ty.uiMedium).color(k.c.textBase))
        .child(text("on line \(annotation.line)").font(k.ty.ui).color(k.c.textFaint))
    let replyBtn: El<ReviewState> = k.button(key: "reply-\(annotation.id)", "Reply", variant: .ghost) { _, _ in }
    let resolveBtn: El<ReviewState> = k.button(key: "resolve-\(annotation.id)", "Resolve", variant: .ghost) { _, _ in }
    let actions: El<ReviewState> = row()
        .gap(8)
        .child(replyBtn)
        .child(resolveBtn)
    let bodyBase: El<ReviewState> = text(body)
    let cardBody: El<ReviewState> = bodyBase.font(k.ty.body).color(k.c.textBase)
    let cardBase: El<ReviewState> = col()
    let card: El<ReviewState> = cardBase
        .wFull()
        .p(12)
        .gap(6)
        .rounded(8)
        .bg(k.c.layer01)
        .border(1, k.c.borderWeak)
        .child(header)
        .child(cardBody)
        .child(actions)
    let wrapper: El<ReviewState> = col()
    return wrapper
        .wFull()
        .px(12)
        .py(8)
        .bg(k.c.bgBase)
        .child(card)
}

public func reviewView(_ s: ReviewState, _ cx: inout Cx<ReviewState>) -> El<ReviewState> {
    let k = Kit.neutral(dark: cx.systemDark)
    let split = s.diff.mode == .split
    let modes: El<ReviewState> = k.segmentedControl(
        key: "modes",
        options: [(id: 0, label: "Unified"), (id: 1, label: "Split")],
        selected: split ? 1 : 0
    ) { (state: inout ReviewState, picked: Int) in
        state.diff.setMode(picked == 1 ? .split : .unified)
    }.w(160)

    let adds = s.diff.files.reduce(0) { $0 + $1.additionsCount }
    let dels = s.diff.files.reduce(0) { $0 + $1.deletionsCount }
    let fileCount = s.diff.files.count
    let filesLabel = fileCount == 1 ? "1 file" : "\(fileCount) files"

    let bar: El<ReviewState> = row()
        .key("bar")
        .wFull()
        .h(48)
        .px(16)
        .gap(12)
        .itemsCenter()
        .bg(k.c.layer01)
        .child(text("Add jitter to retry backoff").font(k.ty.uiMedium).color(k.c.textBase))
        .child(text("\(filesLabel)  +\(adds) \u{2212}\(dels)").font(k.ty.ui).color(k.c.textMuted))
        .child(row().grow(1))
        .child(modes)

    let diffEl = k.diffView(key: "diff", state: s, cx: cx, at: \ReviewState.diff) { dv in
        dv
            .foldRow(s.foldRow)
            .annotation { _, ann in commentCard(k, ann) }
            .onComment { state, range, _ in state.composing = range }
    }
    .wFull()
    .grow(1)
    .minH(0)

    return col()
        .wFull()
        .hFull()
        .bg(k.c.bgBase)
        .child(bar)
        .child(diffEl)
}

public func makeApp() -> App<ReviewState> {
    App(
        title: "Diff",
        size: Vec2(900, 620),
        state: initialReviewState(),
        view: reviewView
    )
    .families(["Inter", "ui-monospace, Inter"])
    .onKey { state, ev, tx in
        state.diff.key(ev, keyPrefix: "diff", tx: &tx)
    }
    .scene("split") { state, _ in
        state.diff.setMode(.split)
    }
    .scene("scrolled") { state, _ in
        state.diff = DiffState(
            diff: FileDiff.fromTexts(path: "src/net/backoff.rs", old: longOld, new: longNew)
        )
    }
    .scene("folded") { state, _ in
        state.diff = DiffState(
            diff: foldedDiff(lineCount: 40, changes: [8: ("    attempts: 3,", "    attempts: 5,")])
        )
    }
    .scene("long") { state, _ in
        state.diff = longFoldedState()
    }
    .scene("line-info") { state, _ in
        state.diff = longFoldedState()
        state.foldRow = .lineInfo
    }
    .scene("added") { state, _ in
        state.diff = DiffState(
            files: [
                FileDiff.patch(old: nil, new: addedMd, path: "docs/retry.md"),
                FileDiff.patch(old: deletedToml, new: nil, path: "config/legacy.toml"),
            ],
            mode: .split
        )
    }
}

@main
enum RuneKitDiffMain {
    static func main() throws {
        try makeApp().run()
    }
}
