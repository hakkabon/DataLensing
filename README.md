# DataLensing

Interactive smoothing explorer: load a CSV, fit it with
[Swift-DataLens](https://github.com/hakkabon/Swift-DataLens), and scroll
through raw points + fitted curve + uncertainty band in Swift Charts.

The library (`DataLens`) owns the statistics. This repo owns everything
around it: streaming data-in, the windowed refit policy, the tuning
budget, point decimation, and the viewer app. The engine↔app contract is
one call — `AutomaticSmoother.fit(...) → (FittedSmoother, TuningSummary)`
— with `predict` / `standardErrors` evaluated on cached fits, never
refit per frame.

## Layout

```
Package.swift                  # DataTables + DataLensing + CLI; pins Swift-DataLens by revision
Sources/DataTables/            # Local data-in: streaming CSV, type inference, [[Double]] extraction
Sources/DataLensing/           # App-support lib: ChartModel, FitController, budgets, decimation, chart view
Sources/DataLensingApp/        # CLI spike: bundled sine.csv → fit → terminal report (dogfoods loadChart)
Sources/DataLensingApp/SampleData/sine.csv  # 1000 deterministic rows, ~2% missing
Tests/DataTablesTests/         # Parser, inference, errors, 100k-row streaming proof
Tests/DataLensingTests/        # Contract, policy, budgets, decimation, loader
Viewer/                        # Xcode macOS app hosting SmootherChartView (file picker, scroll, coverage)
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
swift test                         # 32 tests (see below)
swift run data-lensing-app         # CLI spike on the bundled sample
```

```bash
# Viewer app (macOS)
xcodebuild -project Viewer/DataLensingViewer.xcodeproj \
  -scheme DataLensingViewer -configuration Debug build
# …or open the project in Xcode and press Run, then "Open CSV…".
```

Sample data regenerates deterministically (`random.Random(42)`); see the
header in `Sources/DataLensingApp/DataLensingApp.swift`.

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
  coverage, budgets, decimation, concurrent parity).
- **Docs live with the change**: public API is documented; update this
  file in the same commit as the feature.

## Performance notes (measured, not assumed)

On 1000 sine rows: parse ≈ 0.01s; full auto-tune ≈ 38s release
(≈ 210s debug); light fit ≈ 13s release; 200-pt grid + SEs ≈ 16s
release exact, ≈ 0.5s borrowed-bandwidth. Debug numerics run ~10–25×
slow — use the **Release** scheme for real files.

The levers, in order: `TuningBudget` (`.full` vs `.interactive`),
`FitController` (scroll evaluates the cached fit; refit only outside
hull × margin), concurrent grid evaluation, borrowed-bandwidth
adaptive paths (opt-in via the budget, agreement inside half the noise
scale), min-max point decimation per pixel. The remaining wall is
tuning-side fit cost — an upstream estimator-policy decision.

## Versions

`0.1.0` DataTables checkpoint · `0.2.0` sample→fit→chart spike ·
`0.3.0` Xcode viewer · `0.4.0` windowed refit policy + budgets ·
`0.5.0` upstream fast grids (Swift-DataLens `0.6.3`) · `0.6.0`
decimation + streaming proof · `0.7.0` scroll-aware chart + coverage.

Upstream is pinned by commit revision (it pins NumericCore by revision,
so stable-version requirements can't resolve — see `Package.swift`).
Re-pin on each upstream tag; the pin comment records which tag the hash is.
