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
                               # plus portable workbench tools, replayable sessions, and analysis documents
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

GitHub CI runs this matrix for pull requests and for tag pushes. Ordinary work
is validated before merge; a release tag validates the merged SHA once, rather
than duplicating the three-platform matrix for both the branch and tag events.
Use the workflow's manual-dispatch control for a direct branch build.

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

## Analysis documents — lab-notebook foundation

`AnalysisDocument` is the first persistence layer for a native numerical-
statistics lab notebook. It is a structured dependency graph, not an
arbitrary-code notebook: a project records a privacy-preserving source identity
(schema, row count, streaming content fingerprint, never an absolute path),
declarative transformations, a serializable model recipe, frozen report and
workbench evidence, and user notes.

Editing a source, transformation, or model marks all downstream blocks
**stale**; it never silently refits or overwrites evidence. A fresh fit or
validation run must create a new evidence snapshot. Documents use strict
versioned decoding, reject dangling dependencies and mismatched source
fingerprints, and round-trip as stable pretty JSON. The initial transformation
vocabulary covers column selection, missing-value policy, numeric filters, and
log-derived columns.

`AnalysisTransformationExecutor` now replays those operations against a CSV
source, retaining original row IDs through every filter and derived column. A
document replay follows only the transformations upstream of a selected target
block and refuses source bytes whose fingerprint differs from the document.
Changing data therefore requires an explicit source update and downstream
staleness—not a silent substitution beneath existing evidence.

The document workbench now creates, opens, saves, annotates, and explicitly
recomputes those records on macOS and iPadOS. Advanced model evidence also
preserves held-out validation, calibration, bootstrap stability, and numerical
execution provenance: the requested solver policy, accepted backend, and—when
native CGLS was accepted—the CSR shape, nonzero count, iterations, convergence,
normal residual, and working objective. A document therefore distinguishes an
explicit sparse request, an automatic dense selection, and an automatic sparse
fallback rather than treating a preference as proof of execution.

Every explicit recomputation now appends an immutable `AnalysisRun` block. It
snapshots the source fingerprint, ordered transformation ancestry, model recipe,
validation/bootstrap seeds, requested numerical policy, start/completion times,
retained-row count, and a completed or failed terminal verdict. New figures and
evidence depend on that run block, so a later recomputation cannot overwrite or
silently reassign prior evidence. Editing an upstream block marks historic runs
stale while preserving their recorded inputs and outcome.

Every newly recorded run also captures reproducibility closure: the host build
identifier, Swift language version, platform/architecture, resolved
Swift-DataLens / Swift-NumericCore / Rust-NumericCore versions, and the checked-
in resolver fingerprint. These fields describe the execution stack; they do not
claim bitwise equivalence across a changed stack. The workbench can diff any two
saved runs without mutating the document, separating changed replay inputs
(source, transformations, folds, scale policy/selection) from changed model,
solver, bootstrap, environment, and terminal-outcome fields. Older documents
remain readable with an explicit “environment unavailable” result rather than a
fabricated match.

Validation plans are now first-class notebook blocks. A plan records fold
construction (shuffled, blocked ordered/spatial, or binary-stratified), its
deterministic seed, optional bootstrap policy, and an optional comparison cohort.
Models retain the plan's resolved configuration alongside their exact statistical
specification; changing a plan makes dependent models and runs visibly stale
while preserving their immutable historical snapshots.

Notebook composition provides the presentation layer for that record. Its saved
sections contain prose and an ordered, non-duplicated set of references to
existing blocks; they cannot execute code or alter model dependencies. The
viewer can generate a conservative Data & preparation / Models & validation /
Results & interpretation outline, then lets reviewers add narrative, move
sections, and place later uncomposed blocks explicitly. This makes a document
readable as a statistical report while retaining the underlying replay graph.

Documents now also carry a portable review record: a user-entered display label,
severity, optional target block, finding text, and an explicit resolution or
dismissal rationale. This is deliberately file-based review readiness, not a
claim of live collaboration or authenticated identity. A document can be marked
ready only when it has analysis blocks, no stale blocks, and no open blockers;
acceptance additionally requires every finding to be closed with a recorded
outcome. Any execution or narrative edit returns the review state to draft, so
a readiness badge cannot conceal changed inputs or unresolved feedback. The
document can also record paired comparative evidence between two completed
advanced-model runs. A comparison retains direct references to both immutable
runs and their held-out validation snapshots, then stores a compact paired-loss
summary rather than duplicating every out-of-fold prediction. It is marked
comparable only when source fingerprint, transformation lineage, realized
statistical scale selection, fold construction, held-out observations, and
response family agree. Otherwise it persists the exact non-comparability
verdict—for example different transformations, scale selection, validation
configuration, response family, or fold assignment—rather than presenting a
misleading winner.

## Scaled statistical workflows

Display scaling and statistical scaling are deliberately separate. Dense chart
samples continue to use lossless viewport min/max decimation, while an analysis
recipe may now explicitly request a bounded statistical fit. The available
bounded policy stratifies finite observations along the leading predictor and
draws one deterministic observation per stratum; it preserves broad trend
coverage while bounding smoother, GAM, validation, and bootstrap cost. It is
not an implicit approximation: the recipe stores the policy and seed, and each
completed run records input, finite-eligible, and selected counts. Full-data is
the default. The viewer exposes 25k and 100k bounded policies for advanced
models, alongside the full finite-data option.

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
DataLensing consumes Swift-DataLens `0.20.1`, which in turn resolves its
compatible Swift-NumericCore release. The ecosystem compatibility workflow
continues to exercise source-head integration separately from these stable
consumer constraints.
