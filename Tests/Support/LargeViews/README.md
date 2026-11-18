# Large-view benchmark

Run the Release executable from the Swift Rune checkout. The 100,000-row table (900 × 900) and 50,000-file tree (360 × 900) scroll by −48 logical points 600 times. The 50,000-line interactive code diff (1200 × 900) changes every seventh line and flings by −400 points 600 times. Headless runs use a 2× target. The runner verifies the full visible row-key sequence after the final scroll. The diff also checks the 240,000-point offset and excludes rows covered by the sticky header.

```sh
swift run --package-path Tests/Support/LargeViews -c release ScrollBench table reference --capture .build/scroll/swift
swift run --package-path Tests/Support/LargeViews -c release ScrollBench tree reference --capture .build/scroll/swift
swift run --package-path Tests/Support/LargeViews -c release ScrollBench table production
swift run --package-path Tests/Support/LargeViews -c release ScrollBench tree window
swift run --package-path Tests/Support/LargeViews -c release ScrollBench diff production
```

To measure the same interactive diff in Chrome, use Node 22 or later, a matching Swift compiler and WASI SDK, and the `dist` directory from `@bjorn3/browser_wasi_shim`. The runner sends one 400-pixel DOM wheel event per animation frame at a trusted pointer position. It requires a scene submission for each accepted wheel and verifies the accessible row labels, clipped bounds and scroll offsets at six checkpoints. After ten warmup events, it reports the overall submission rate and the median and 95th-percentile intervals between consecutive WebGPU queue returns in milliseconds, excluding checkpoint pauses. The output includes the adapter and SHA-256 hashes of the initial and final settled PNG screenshots.

```sh
./scripts/build-web.sh swift-6.4.2-RELEASE_wasm BrowserDiffBench --package-path Tests/Support/LargeViews -c release
node Tests/Browser/run.mjs --fixture diff-scroll-wasi --webgpu \
  --diff-wasm Tests/Support/LargeViews/.build/release/BrowserDiffBench.wasm \
  --wasi-shim /path/to/node_modules/@bjorn3/browser_wasi_shim/dist
```

For Metal on macOS, add `--angle metal` to the Node command. Use `--wheel-delta 17` for a scroll slightly shorter than one row, or `--wheel-delta 1 --steps 1200` for a sustained one-pixel scroll. The default fling moves 20 rows per wheel. Each distance uses the same input, WebGPU and visible-row checks.

The Chrome diff defaults to 2× device scale. Add `--device-scale 1` for a 1200 × 900 backing surface or `--device-scale 1.25` for 1500 × 1125. The logical viewport and wheel distances stay the same. The output records the actual device scale and backing dimensions.

Use `--steps 60` for a short run with checkpoints at 0, 1, 24 and 60 wheels. Pass the same `--steps 60` to `presentations.py` when scoring its Metal CSV. Both commands default to 600 wheels. Window runs accept `--frame-samples file.json` to export the initial frame, each wheel’s host update and encode timings, and the intervals between frame reports. Compare a 60-wheel Rust window capture with `compare.py --native-window diff --native-steps 60`.

- `reference` measures elapsed CPU-side frame construction time using a monotonic wall clock. Logical time advances by 1/120 second per frame. Captures export row keys and clipped geometry at frames 0, 1, 24, 60, 300, and 600 and full top-down RGBA8 pixels and viewable PNGs at frames 0 and 60, outside the timed interval.
- `production` times CPU work in `Runtime.renderFrame`, the instance stream consumed by the native GPU renderer. Timings exclude wheel dispatch and rasterization. With `--capture`, checkpoints record scene geometry and the native instance count. Use separate capture directories for each mode.
- `window` opens a desktop window and delivers one wheel event per host frame report. The JSON includes actual pixel dimensions, reported frame work and intervals between consecutive draw reports. Native window runs use the host display scale and scheduling. Measuring physical display cadence additionally requires presentation timestamps from the platform.

For the Rust comparison, give the following command a local clone containing the revision in `.upstream-sync.json`. To reproduce an older comparison, pass `--revision <commit>` to either Rust runner. Each records the exact commit used. The headless runner executes the unmodified upstream benchmarks and a second copy with a fixed time step and the same sRGB blend mode as the Swift fixture. It saves separate stock timing, matched timing, geometry and pixel files. Cargo dependencies for the chosen revision and a host C toolchain are required.

```sh
python3 Tests/Support/LargeViews/rust-oracle.py /path/to/rust-rune .build/scroll/rust
python3 Tests/Support/LargeViews/compare.py .build/scroll/swift .build/scroll/rust
```

Use the same machine and quiet system conditions when comparing timings. The comparator checks dimensions, data row keys and visible geometry and reports pixel differences. Pass `--pixel-tolerance N` to enforce a maximum difference across every painted channel, or `--geometry-only` to compare production checkpoints and report native instance counts without reading pixel files. A `header` row counts toward total mounted table rows but sits outside the data row range. The final visible keys are `f1028` through `f1059` in the table and `pkg11/file88.rs` through `pkg12/file24.rs` in the tree.

On a Mac with a visible Metal display, both ports can write a CSV of presentation timestamps from actual drawables. Each record includes the wheel step and drawable size. Both fixtures send one precise AppKit scroll event to their own native view after each draw. Swift routes it through the Rune Metal host and Rust through Winit. Both verify the final visible row sequence. The summary reports how many inputs appeared on screen, the observed rate of distinct presentations and, when all 600 appeared at distinct times, the full-run `displayedFPS`. Run the timing pass separately from `--capture` to keep geometry and pixel export outside the measured run.

```sh
swift run --package-path Tests/Support/LargeViews -c release ScrollBench table window --metal-presents .build/scroll/swift-table.csv
python3 Tests/Support/LargeViews/presentations.py .build/scroll/swift-table.csv
swift run --package-path Tests/Support/LargeViews -c release ScrollBench tree window --metal-presents .build/scroll/swift-tree.csv
python3 Tests/Support/LargeViews/presentations.py .build/scroll/swift-tree.csv
python3 Tests/Support/LargeViews/rust-native.py /path/to/rust-rune .build/scroll/rust-mac
xcrun swift run --package-path Tests/Support/LargeViews -c release ScrollBench diff window --metal-presents .build/scroll/swift-diff.csv
python3 Tests/Support/LargeViews/presentations.py .build/scroll/swift-diff.csv
python3 Tests/Support/LargeViews/rust-native.py /path/to/rust-rune .build/scroll/rust-mac --case diff
```

The presentation summary can also check a fixed-rate display. For example, on a 60 Hz display, the following gate requires all 600 wheel events to appear in order and permits up to two missed refreshes over the run.

```sh
python3 Tests/Support/LargeViews/presentations.py .build/scroll/swift-diff.csv --refresh-hz 60 --max-missed-refreshes 2
```

To compare the native windows, capture one Swift run and use the Rust window JSON from the same workload. The comparator checks the order and clipped bounds of every visible row at all six checkpoints. For the diff it also verifies the scroll offsets. Mounted counts can vary with the number of display frames available for overscan.

```sh
xcrun swift run --package-path Tests/Support/LargeViews -c release ScrollBench diff window --capture .build/scroll/swift-diff-window --metal-presents .build/scroll/swift-diff-window/run.csv
python3 Tests/Support/LargeViews/compare.py .build/scroll/swift-diff-window .build/scroll/rust-mac/diff.json --native-window diff
```

The 50,000-line code diff has a separate benchmark. It changes every seventh line and measures elapsed frame-construction time for ordinary scrolls, 400-point flings, and jumps between distant hunks. Run the Swift command from this checkout and the Cargo command from the pinned Rust checkout. The reported times exclude GPU submission and physical presentation.

```sh
RUNE_DIFF_BENCH=1 swift test -c release --filter diff50kTimings
cargo test -p rune-kit --profile perf --test diff diff_50k_time -- --ignored --nocapture
```
