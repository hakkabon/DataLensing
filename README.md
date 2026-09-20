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
Package.swift                  # DataTables + DataLensing + CLI; semantic Swift-DataLens release range
Sources/DataTables/            # Local data-in: streaming CSV, type inference, [[Double]] extraction
Sources/DataLensing/           # App-support lib: ChartModel, FitController, budgets, smoother
                               # choice, decimation, generation gate, chart view + window policy
                               # plus portable workbench tools and replayable sessions
Sources/DataLensingApp/        # CLI: bundled samples → fit → terminal report (dogfoods loadChart)
Sources/DataLensingApp/SampleData/  # deterministic 1D and 2D examples
Tests/DataTablesTests/         # Parser, inference, errors, chunk-size independence, 100k streaming
Tests/DataLensingTests/        # Contracts, diagnostics, surfaces, policies, decimation, loaders
Viewer/                        # Xcode macOS + iPad app: file/sample/column/smoother pickers,
                               # diagnostics, 2D surfaces, scroll/refit, click-to-inspect
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
swift test                         # 66 tests (see below)
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
- `surface.csv` — deterministic 5×5 plane, `response = 2x1 − 3x2 + 4`,
  for the two-predictor response surface and trend-vector display.

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

## UI Interactions (viewer app)

| Shortcut | Action |
|----------|--------|
| `⌘O` | Open CSV file picker |
| `⌘W` | Clear chart (back to idle) |
| `⌘E` | Export fitted grid to clipboard (tab-separated: x, fit, lower, upper) |
| `⌘⇧W` | Copy the current workbench configuration as versioned JSON |
| `←` / `→` | Step the probe cursor one grid point left / right (with smooth animation) |
| `Escape` | Dismiss probe cursor |
| Click / drag | Set probe to clicked x position |

The **Descriptive Statistics** sidebar section (below Model Information) shows
n, mean, std, median, min, max for the X and Y columns of the surviving data
(post-missing-drop). The **Copy Fitted Grid** button in that section copies
the same tab-separated grid that `⌘E` does.

Chart colours track the system accent colour (System Preferences → General
→ Accent Colour) so the fitted curve and uncertainty band stay visually
consistent with the rest of the macOS UI.

The display controls also expose a linked first-derivative plot,
training-point residuals, and a normal QQ plot. Continuous smoothers use raw
residuals; binomial and Poisson local-likelihood fits use Pearson residuals and
label fitted values as probabilities or expected counts. Choosing a **Second
Predictor** fits a regular two-dimensional grid and switches the detail area to
a Canvas response heatmap with normalized gradient vectors.

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
planar layer separation (`ChartPlanes`: gridlines, samples, hull, curve,
gradient, residuals, QQ), and `DecimationIndex`. The index is built once on a
background task and uses a min/max segment tree, so a 500k-point viewport
query touches at most the requested buckets × logarithmic lookups rather than
rescanning 500k rows. Small envelopes remain accessible Swift Charts marks;
larger envelopes use one SwiftUI Canvas pass while Charts retains the axes,
curve, and probe interaction. Scrolling never refits or re-sorts data. The 2D
grid also uses Canvas to avoid thousands of mark nodes.

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
layers + confidence interval probe inspection + memoized decimation ·
`0.20.0` descriptive statistics sidebar + keyboard shortcuts (⌘O/W/E,
arrow-key probe stepping) + export fitted grid + accent colour theming
+ polished empty / loading / error states · `0.21.0` viewer build repair +
scene commands + iPad clipboard, typed response scales, gradient/residual/QQ
diagnostics, keyed 500k-point decimation cache, and two-predictor Canvas
surfaces with trend vectors.

`AnalysisReport.make(from:sourceURL:inputObservationCount:)` produces a
schema-versioned provenance sidecar with source metadata, model/tuning choices,
retained-row join keys, fitted values, and residuals. Reports export as stable
JSON and observation-level CSV; non-finite diagnostics become explicit nulls
rather than invalid JSON numbers.

The scheduled `Ecosystem compatibility` workflow checks source-head builds of
DataLensing, Swift-DataLens, and Swift-NumericCore together and rejects drift in
their shared solver fixture. Tagged backend releases can dispatch the same
check immediately; the weekly run is the no-secret fallback.

## Statistical workflow

The frontend now turns a fitted chart into a family-aware `ModelAssessment`.
Continuous fits report RMSE, MAE, bias, R², normal-QQ correlation, residual
autocorrelation, and standardized-residual counts. Binary and count fits use
model-appropriate deviance and null-deviance reduction rather than presenting
R² as though it had the same meaning. Threshold findings call out residual
bias, heavy/non-normal residuals, remaining x-ordered structure, and weak
deviance reduction. These checks are descriptive training diagnostics—not
out-of-sample validation—and the API and report state that limitation.

The viewer displays the assessment beside the model and includes its complete
machine-readable form in every analysis-report JSON export. This keeps the
interactive review, copied report, and automated consumers on one calculation
path.

## Extensible workbench

`WorkbenchTool` is the extension seam for additional statistical panels. A
tool accepts a `WorkbenchInput` (the public `LoadedChart`, a path-free source
identity, and optional retained-row join keys) and returns a portable
`WorkbenchOutput`: summary, metrics, and an optional rectangular table. The
validated `WorkbenchCatalog` preserves display/execution order and makes a
duplicate or unknown tool identifier an explicit error. It carries no SwiftUI,
file-system, or parser state, so the same tool can be hosted by the viewer, a
CLI, or a future automation.

The built-in catalog contains descriptive statistics, family-aware model
assessment, out-of-fold validation, a largest-residual review table, and a
bounded **Residual Profile**. The profile sorts finite predictor/residual pairs
only when explicitly run, then emits at most 32 equal-count bins with mean and
RMS residuals. It makes remaining predictor-ordered structure inspectable on
very large files without turning the workbench into another dense point view.
The validation tool refits Swift-DataLens’s automatic model separately in every
training fold, using the same degree, span, robustness, and adaptive-tuning
policy as the interactive chart. It reports Gaussian RMSE/MAE or
binomial/Poisson mean deviance, plus the largest held-out errors joined back to
source rows. The viewer runs it explicitly from the **Workbench** sidebar
section; fitting, chart scrolling, and surface rendering never run analysis
panels implicitly. Refitting or replacing a chart cancels and clears stale
results.

`WorkbenchSession` schema v2 captures the selected columns, smoother,
complete tuning budget, validation-fold configuration, active planes, enabled
tool identifiers, and a source display name + row count in versioned JSON. It
deliberately excludes absolute paths and source data. Schema-v1 sessions remain
readable; their validation configuration is recovered from the recorded tuning
budget. A host loading a session must ask for a source file, then can validate
and replay the recorded configuration. **Copy Workbench Session** is available
from the sidebar and `⌘⇧W` on macOS.

Swift package resolution uses compatible tagged release ranges:
DataLensing consumes Swift-DataLens `0.15.x`, which in turn resolves its
compatible Swift-NumericCore release. The ecosystem compatibility workflow
continues to exercise source-head integration separately from these stable
consumer constraints.
