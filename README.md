# DataLensing

Interactive smoothing explorer: load a CSV, fit it with
[Swift-DataLens](https://github.com/hakkabon/Swift-DataLens), and scroll
through raw points + fitted curve + uncertainty band in Swift Charts.

The library (`DataLens`) owns the statistics. This repo owns everything
around it: streaming data-in, the windowed refit policy, the tuning
budget, explicit smoother choice, point decimation, and the viewer app.
The engine↔app contract is one call — `AutomaticSmoother.fit(...) →
(FittedSmoother, TuningSummary)` — with `predict` / `standardErrors`
evaluated on cached fits, never refit per frame. Explicit legs (Loess,
Adaptive, Kernel, Whittaker, Total Variation) skip the competition via
`SmootherChoice`; the tuner never routes kernel/penalized/edge-preserving
fits (pinned upstream by test).

## Layout

```
Package.swift                  # DataTables + DataLensing + CLI; pins Swift-DataLens by revision
Sources/DataTables/            # Local data-in: streaming CSV, type inference, [[Double]] extraction
Sources/DataLensing/           # App-support lib: ChartModel, FitController, budgets, smoother
                               # choice, decimation, generation gate, chart view + window policy
Sources/DataLensingApp/        # CLI: bundled samples → fit → terminal report (dogfoods loadChart)
Sources/DataLensingApp/SampleData/  # sine.csv, steps.csv, outliers.csv (deterministic, documented below)
Tests/DataTablesTests/         # Parser, inference, errors, chunk-size independence, 100k streaming
Tests/DataLensingTests/        # Contract, policy, budgets, refits, decimation, choices, loader, gates
Viewer/                        # Xcode macOS + iPad app: file/sample/column/smoother pickers,
                               # scroll + coverage + refit-to-view, click-to-inspect
```

`DataTables` lives in-repo (one consumer) as Foundation-only portable
code; extract to its own package if a second consumer appears. The
chart view compiles only where SwiftUI/Charts exist
(`#if canImport`); everything else builds on Linux too.

## Requirements

- Swift 6.1+, strict concurrency
- macOS 14+ / iOS 17+ for the viewer (`chartScrollableAxes` needs it);
  the library and CLI build on Linux
- Xcode 16+ for `Viewer/`; SwiftPM CLI for everything else

## Build, test, run

```bash
swift build                        # all SPM targets
swift test                         # 42 tests (see below)
swift run data-lensing-app         # CLI on the bundled sine sample
```

```bash
# Viewer app (macOS + iPad)
xcodebuild -project Viewer/DataLensingViewer.xcodeproj \
  -scheme DataLensingViewer -configuration Debug build
# …or open the project in Xcode and press Run, then "Open CSV…" or Samples.
# iPad runs from Xcode with team signing; iPhone builds but is best-effort.
```

Sample data regenerates deterministically (`random.Random(42)`); see the
header in `Sources/DataLensingApp/DataLensingApp.swift`.

## Samples

`Sources/DataLensingApp/SampleData/` (bundled in both the CLI and the
viewer, which discovers them live — adding a CSV needs no code change):

- `sine.csv` — 1000 rows of sin(x) + N(0, 0.15) on x ∈ [0, 10], ~2%
  missing. The smooth periodic reference (`Random(42)`).
- `steps.csv` — 600 rows of piecewise-constant levels (0 / 2 / 1) +
  N(0, 0.12), ~1% missing. Step-response demo: kernel and Whittaker
  legs behave very differently here (`Random(7)`).
- `outliers.csv` — 400 rows of 2x + 1 + N(0, 0.2) with ~6% heavy
  outliers (±3–6) and sparse missing. Robustness demo
  (`Random(7)`, continued stream).

## Conventions

- **Value semantics**: models are `struct`s conforming to `Sendable`.
  The streaming parser's byte feeder is the exception (wraps an
  `InputStream`, confined to the driving task — documented).
- **Failures**: `precondition` for programmer errors (bad counts,
  non-positive grids); `nil`/`throw` for data-dependent ones (ragged
  rows, string columns, singular bands). Never trap on file content.
- **Tests** are deterministic (fixed seeds, exact assertions, NaN-aware
  helpers): `DataTablesTests` (quoting, delimiters, inference, errors,
  chunk-size independence, file≡string, 100k streaming) and
  `DataLensingTests` (CSV→fit→join-back, loader policy, windowed
  coverage + refits, budgets incl. shallow/fast flags, decimation,
  concurrent parity, explicit choices, column inspect, gates,
  interpolation).
- **Docs live with the change**: public API is documented; update this
  file in the same commit as the feature.

## Performance notes (measured, not assumed)

On 1000 sine rows: parse ≈ 0.01s; full auto-tune ≈ 38s release
(≈ 210s debug); shallow-Loess interactive ≈ 5s; adaptive interactive +
fast grids ≈ 13s; Whittaker interactive ≈ 0.3s; TV interactive ≈ 0.8s.
Debug numerics run ~10–25× slow — use the **Release** scheme for real
files.

The levers, in order: `TuningBudget` (`.full` vs `.interactive`,
shallow/fast flags, per-leg penalty grids), `FitController` (scroll
evaluates the cached fit; refit only outside hull × margin; windowed
subset refits), concurrent grid evaluation, explicit smoother choice
(auto-tune vs direct legs), min-max point decimation per pixel, and
planar layer separation (`ChartPlanes`: gridlines, samples, hull, curve)
with memoized decimation to ensure scrub operations never trigger re-bucketing.

## Versions

`0.1.0` DataTables checkpoint · `0.2.0` sample→fit→chart spike ·
`0.3.0` Xcode viewer · `0.4.0` windowed refit policy + budgets ·
`0.5.0` upstream fast grids (Swift-DataLens `0.6.3`) · `0.6.0`
decimation + streaming proof · `0.7.0` scroll-aware chart + coverage ·
`0.8.0` README + CI · `0.9.0` windowed subset refits · `0.9.1`
signing/CI fixes · `0.10.0` column pickers · `0.10.1` responsive
cancel · `0.11.0` click-to-inspect · `0.12.0` shallow tuning
(Swift-DataLens `0.6.4`) · `0.13.0` sample button + axes ·
`0.14.0` explicit smoother choice (Swift-DataLens `0.7.x`) ·
`0.15.0` iPad destination · `0.16.x` CI arch fixes · `0.17.0`
Whittaker picker (Swift-DataLens `0.8.0`) · `0.17.1` tag hygiene ·
`0.18.0` TV picker (Swift-DataLens `0.9.0`) · `0.19.0` planar rendering
layers + confidence interval probe inspection + memoized decimation.

Upstream is pinned by commit revision (it pins NumericCore by revision,
so stable-version requirements can't resolve — see `Package.swift`).
Re-pin on each upstream tag; the pin comment records which tag the hash is.
