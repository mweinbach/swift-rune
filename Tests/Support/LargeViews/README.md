# Large-view benchmark

Run the Release executable from the Swift Rune checkout. It shares its 100,000-row table and 50,000-file tree with the RuneKit performance tests. Each workload scrolls by −48 logical points 600 times. The table viewport is 900 × 900 and the tree viewport is 360 × 900. Both use a 2× target in headless runs. The runner verifies the full visible row-key sequence after the final scroll.

```sh
swift run --package-path Tests/Support/LargeViews -c release ScrollBench table reference --capture .build/scroll/swift
swift run --package-path Tests/Support/LargeViews -c release ScrollBench tree reference --capture .build/scroll/swift
swift run --package-path Tests/Support/LargeViews -c release ScrollBench table production
swift run --package-path Tests/Support/LargeViews -c release ScrollBench tree window
```

- `reference` measures elapsed CPU-side frame construction time using a monotonic wall clock. Logical time advances by 1/120 second per frame. Captures export row keys and clipped geometry at frames 0, 1, 24, 60, 300, and 600 and full top-down RGBA8 pixels and viewable PNGs at frames 0 and 60, outside the timed interval.
- `production` times CPU work in `Runtime.renderFrame`, the instance stream consumed by the native GPU renderer. Timings exclude wheel dispatch and rasterization. With `--capture`, checkpoints record scene geometry and the native instance count. Use separate capture directories for each mode.
- `window` opens a desktop window and delivers one wheel event per host frame report. The JSON includes actual pixel dimensions, reported frame work and intervals between consecutive draw reports. Native window runs use the host display scale and scheduling. Measuring physical display cadence additionally requires presentation timestamps from the platform.

For the Rust comparison, give the following command a local clone containing the revision in `.upstream-sync.json`. To reproduce an older comparison, pass `--revision <commit>` to either Rust runner. Each records the exact commit used. The headless runner executes the unmodified upstream benchmarks and a second copy with a fixed time step and the same sRGB blend mode as the Swift fixture. It saves separate stock timing, matched timing, geometry and pixel files. Cargo dependencies for the chosen revision and a host C toolchain are required.

```sh
python3 Tests/Support/LargeViews/rust-oracle.py /path/to/rust-rune .build/scroll/rust
python3 Tests/Support/LargeViews/compare.py .build/scroll/swift .build/scroll/rust
```

Use the same machine and quiet system conditions when comparing timings. The comparator checks dimensions, data row keys and visible geometry and reports pixel differences. Pass `--pixel-tolerance N` to enforce a maximum difference across every painted channel, or `--geometry-only` to compare production checkpoints and report native instance counts without reading pixel files. A `header` row counts toward total mounted table rows but sits outside the data row range. The final visible keys are `f1028` through `f1059` in the table and `pkg11/file88.rs` through `pkg12/file24.rs` in the tree.

On a Mac with a visible Metal display, both ports can write a CSV of presentation timestamps from actual drawables. Each record includes the wheel step and drawable size. The Swift runner sends the next wheel through the runtime after each draw. The Rust fixture runs the original widgets and sends one precise AppKit wheel to their Winit view after each draw. Both verify the final visible row sequence. The summary reports how many inputs appeared on screen, the observed rate of distinct presentations and, when all 600 appeared at distinct times, the full-run `displayedFPS`. Run the timing pass separately from `--capture` to keep geometry and pixel export outside the measured run.

```sh
swift run --package-path Tests/Support/LargeViews -c release ScrollBench table window --metal-presents .build/scroll/swift-table.csv
python3 Tests/Support/LargeViews/presentations.py .build/scroll/swift-table.csv
swift run --package-path Tests/Support/LargeViews -c release ScrollBench tree window --metal-presents .build/scroll/swift-tree.csv
python3 Tests/Support/LargeViews/presentations.py .build/scroll/swift-tree.csv
python3 Tests/Support/LargeViews/rust-native.py /path/to/rust-rune .build/scroll/rust-mac
```

The 50,000-line code diff has a separate benchmark. It changes every seventh line and measures elapsed frame-construction time for ordinary scrolls, 400-point flings, and jumps between distant hunks. Run the Swift command from this checkout and the Cargo command from the pinned Rust checkout. The reported times exclude GPU submission and physical presentation.

```sh
RUNE_DIFF_BENCH=1 swift test -c release --filter diff50kTimings
cargo test -p rune-kit --profile perf --test diff diff_50k_time -- --ignored --nocapture
```
