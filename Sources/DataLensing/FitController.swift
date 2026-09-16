// FitController.swift
// DataLensing
//
// The windowed refit policy: scroll evaluates the cached fit, refits
// happen only when the visible window leaves the fitted hull (plus
// margin) or the data changes. Never refit per frame.

import DataLens
import DataTables
import Foundation

/// Pure hull × margin rule: refit when the visible window is not
/// contained in the fitted hull expanded by `marginFraction` of its
/// width on each side. No fitting here — deterministically testable.
public struct CoveragePolicy: Sendable, Hashable {
    /// Margin as a fraction of hull width, each side. Must be ≥ 0.
    public var marginFraction: Double

    public init(marginFraction: Double = 0.25) {
        precondition(marginFraction >= 0, "marginFraction must be non-negative")
        self.marginFraction = marginFraction
    }

    /// Whether `visible` escapes the margined hull (or the hull is
    /// degenerate — zero-width or non-finite — in which case refit).
    public func needsRefit(hull: ClosedRange<Double>, visible: ClosedRange<Double>) -> Bool {
        let width = hull.upperBound - hull.lowerBound
        guard width > 0, width.isFinite else { return true }
        let margin = marginFraction * width
        return visible.lowerBound < hull.lowerBound - margin
            || visible.upperBound > hull.upperBound + margin
    }
}

/// Which smoother a `FitController` fits: the automatic competition or
/// one explicit leg. Raw values feed picker labels directly.
///
/// Explicit legs take their span from the budget (`spans?.first`, else
/// 0.5) and skip tuning competition — their `LoadedChart.summary` is
/// nil, with the choice recorded in `smootherName` instead. The kernel
/// and Whittaker legs ignore `degree`/`robustIterations` (no polynomials
/// or reweighting there); Whittaker reads `smoothingPenalty` (GCV grid
/// when nil).
public enum SmootherChoice: String, Sendable, Hashable {
    case automatic = "Auto"
    case loess = "Loess"
    case adaptive = "Adaptive"
    case kernel = "Kernel"
    case whittaker = "Whittaker"
}

/// Owns one file's columns, tuning budget, smoother choice, and cached fit.
///
/// - `loadController(from:)` parses and picks columns (milliseconds).
/// - `fit()` / `fitConcurrently()` spend the budget once and cache.
/// - `needsRefit(covering:)` answers the per-scroll question without
///   touching the smoother.
public struct FitController: Sendable {
    public let trainX: [[Double]]
    public let trainY: [Double]
    public let xName: String
    public let yName: String
    public let budget: TuningBudget
    public let smoother: SmootherChoice
    public private(set) var loaded: LoadedChart?
    /// File-row index per fitted-subset position. Identity after a full
    /// `fit()`; the surviving window after `refit(covering:)`.
    public private(set) var windowBase: [Int]

    /// Fitted hull over the surviving predictors, or `nil` before the
    /// first fit.
    public var hull: ClosedRange<Double>? {
        guard let xs = loaded?.model.rawX, let lo = xs.min(), let hi = xs.max(), hi > lo else {
            return nil
        }
        return lo...hi
    }

    /// File-level join-back for the cached fit: subset survivors mapped
    /// through the window, or `nil` before the first fit.
    public var keptFileIndices: [Int]? {
        guard let kept = loaded?.keptIndices else { return nil }
        return kept.map { windowBase[$0] }
    }

    public init(
        trainX: [[Double]], trainY: [Double], xName: String, yName: String,
        budget: TuningBudget = .full, smoother: SmootherChoice = .automatic
    ) {
        precondition(trainX.count == trainY.count, "trainX and trainY must have equal counts")
        self.trainX = trainX
        self.trainY = trainY
        self.xName = xName
        self.yName = yName
        self.budget = budget
        self.smoother = smoother
        self.windowBase = Array(trainX.indices)
    }

    /// Fit synchronously (CLI / tests), spending the budget once.
    @discardableResult
    public mutating func fit() throws -> LoadedChart {
        let loaded = try fittedChart(trainX: trainX, trainY: trainY)
        self.loaded = loaded
        self.windowBase = Array(trainX.indices)
        return loaded
    }

    /// Fit with the grid evaluated concurrently (viewer path).
    @discardableResult
    public mutating func fitConcurrently() async throws -> LoadedChart {
        let loaded = try await fittedChartConcurrently(trainX: trainX, trainY: trainY)
        self.loaded = loaded
        self.windowBase = Array(trainX.indices)
        return loaded
    }

    /// The per-scroll question: does `visible` escape the cached fit?
    /// `true` before the first fit (nothing cached yet).
    public func needsRefit(
        covering visible: ClosedRange<Double>, policy: CoveragePolicy = CoveragePolicy()
    ) -> Bool {
        guard let hull else { return true }
        return policy.needsRefit(hull: hull, visible: visible)
    }

    /// Refit to a visible window: subset rows whose x falls in `visible`
    /// expanded by the policy margin (hysteresis, so edge scrolls don't
    /// immediately re-trigger), then spend the budget there.
    ///
    /// - Returns: `false` — keeping the cached fit — when the window is
    ///   already covered, degenerate, or holds no rows.
    @discardableResult
    public mutating func refit(
        covering visible: ClosedRange<Double>, policy: CoveragePolicy = CoveragePolicy()
    ) throws -> Bool {
        guard let subset = windowIndices(covering: visible, policy: policy) else { return false }
        let loaded = try fittedChart(
            trainX: subset.map { trainX[$0] }, trainY: subset.map { trainY[$0] }
        )
        self.loaded = loaded
        self.windowBase = subset
        return true
    }

    /// Concurrent twin of `refit(covering:)` (viewer path).
    @discardableResult
    public mutating func refitConcurrently(
        covering visible: ClosedRange<Double>, policy: CoveragePolicy = CoveragePolicy()
    ) async throws -> Bool {
        guard let subset = windowIndices(covering: visible, policy: policy) else { return false }
        let loaded = try await fittedChartConcurrently(
            trainX: subset.map { trainX[$0] }, trainY: subset.map { trainY[$0] }
        )
        self.loaded = loaded
        self.windowBase = subset
        return true
    }

    /// Subset positions covering `visible` plus margin, or `nil` when no
    /// refit is warranted. Rows use their first coordinate (the charted
    /// predictor); non-finite coordinates never match a window.
    private func windowIndices(
        covering visible: ClosedRange<Double>, policy: CoveragePolicy
    ) -> [Int]? {
        guard needsRefit(covering: visible, policy: policy) else { return nil }
        let width = visible.upperBound - visible.lowerBound
        guard width > 0, width.isFinite else { return nil }
        let margin = policy.marginFraction * width
        let lo = visible.lowerBound - margin
        let hi = visible.upperBound + margin
        let subset = trainX.indices.filter { i in
            guard let xv = trainX[i].first, xv.isFinite else { return false }
            return xv >= lo && xv <= hi
        }
        guard !subset.isEmpty else { return nil }
        return subset
    }

    /// Default GCV grid for a nil `smoothingPenalty`: log-spaced across
    /// the penalty scales real data spans (GCV picks; the grid only has
    /// to bracket the optimum, not resolve it).
    static let defaultSmoothingPenalties: [Double] = [0.1, 1, 10, 100, 1e3, 1e4, 1e5, 1e6]

    /// Whittaker fit honoring the budget: explicit penalty, else GCV
    /// over the default grid (order 2 — the Hodrick–Prescott form).
    private func whittakerFit(trainX: [[Double]], trainY: [Double]) -> WhittakerEilers? {
        if let penalty = budget.smoothingPenalty {
            return WhittakerEilers.fit(
                trainX: trainX, trainY: trainY, lambda: penalty, droppingMissing: true
            )
        }
        return WhittakerEilers.selectLambda(
            trainX: trainX, trainY: trainY, lambdas: Self.defaultSmoothingPenalties,
            droppingMissing: true
        )?.fit
    }

    private func fittedChart(trainX: [[Double]], trainY: [Double]) throws -> LoadedChart {
        let (fit, summary, name): (FittedSmoother, TuningSummary?, String)
        switch smoother {
        case .automatic:
            guard let tuned = AutomaticSmoother.fit(
                trainX: trainX, trainY: trainY,
                degree: budget.degree, spans: budget.spans,
                robustIterations: budget.robustIterations, droppingMissing: true,
                adaptiveContender: budget.adaptiveContender
            ) else {
                throw ChartLoadError.fitFailed
            }
            (fit, summary, name) = (tuned.fit, tuned.summary, tuned.summary.smoother)
        case .loess:
            let span = budget.spans?.first ?? 0.5
            guard let loess = Loess.fit(
                trainX: trainX, trainY: trainY, span: span,
                degree: budget.degree, robustIterations: budget.robustIterations,
                droppingMissing: true
            ) else {
                throw ChartLoadError.fitFailed
            }
            (fit, summary, name) = (.loess(loess), nil, "Loess")
        case .adaptive:
            guard let adaptive = AdaptiveLoess.fit(
                trainX: trainX, trainY: trainY, degree: budget.degree,
                robustIterations: budget.robustIterations, droppingMissing: true
            ) else {
                throw ChartLoadError.fitFailed
            }
            (fit, summary, name) = (.adaptive(adaptive), nil, "AdaptiveLoess")
        case .kernel:
            let span = budget.spans?.first ?? 0.5
            guard let kernel = NadarayaWatson.fit(
                trainX: trainX, trainY: trainY, span: span,
                robustIterations: budget.robustIterations, droppingMissing: true
            ) else {
                throw ChartLoadError.fitFailed
            }
            (fit, summary, name) = (.nadarayaWatson(kernel), nil, "NadarayaWatson")
        case .whittaker:
            guard let penalized = whittakerFit(trainX: trainX, trainY: trainY) else {
                throw ChartLoadError.fitFailed
            }
            (fit, summary, name) = (.whittakerEilers(penalized), nil, "WhittakerEilers")
        }
        try Task.checkCancellation()
        guard let model = ChartModel.make(
            trainX: trainX, trainY: trainY, fit: fit, gridCount: budget.gridCount,
            fastAdaptivePrediction: budget.fastAdaptivePrediction
        ) else {
            throw ChartLoadError.modelFailed
        }
        return LoadedChart(
            model: model, summary: summary, smootherName: name,
            xName: xName, yName: yName, keptIndices: fit.keptIndices
        )
    }

    private func fittedChartConcurrently(trainX: [[Double]], trainY: [Double]) async throws -> LoadedChart {
        let (fit, summary, name): (FittedSmoother, TuningSummary?, String)
        switch smoother {
        case .automatic:
            guard let tuned = AutomaticSmoother.fit(
                trainX: trainX, trainY: trainY,
                degree: budget.degree, spans: budget.spans,
                robustIterations: budget.robustIterations, droppingMissing: true,
                adaptiveContender: budget.adaptiveContender
            ) else {
                throw ChartLoadError.fitFailed
            }
            (fit, summary, name) = (tuned.fit, tuned.summary, tuned.summary.smoother)
        case .loess:
            let span = budget.spans?.first ?? 0.5
            guard let loess = Loess.fit(
                trainX: trainX, trainY: trainY, span: span,
                degree: budget.degree, robustIterations: budget.robustIterations,
                droppingMissing: true
            ) else {
                throw ChartLoadError.fitFailed
            }
            (fit, summary, name) = (.loess(loess), nil, "Loess")
        case .adaptive:
            guard let adaptive = AdaptiveLoess.fit(
                trainX: trainX, trainY: trainY, degree: budget.degree,
                robustIterations: budget.robustIterations, droppingMissing: true
            ) else {
                throw ChartLoadError.fitFailed
            }
            (fit, summary, name) = (.adaptive(adaptive), nil, "AdaptiveLoess")
        case .kernel:
            let span = budget.spans?.first ?? 0.5
            guard let kernel = NadarayaWatson.fit(
                trainX: trainX, trainY: trainY, span: span,
                robustIterations: budget.robustIterations, droppingMissing: true
            ) else {
                throw ChartLoadError.fitFailed
            }
            (fit, summary, name) = (.nadarayaWatson(kernel), nil, "NadarayaWatson")
        case .whittaker:
            guard let penalized = whittakerFit(trainX: trainX, trainY: trainY) else {
                throw ChartLoadError.fitFailed
            }
            (fit, summary, name) = (.whittakerEilers(penalized), nil, "WhittakerEilers")
        }
        try Task.checkCancellation()
        guard let model = try await ChartModel.makeConcurrently(
            trainX: trainX, trainY: trainY, fit: fit, gridCount: budget.gridCount,
            fastAdaptivePrediction: budget.fastAdaptivePrediction
        ) else {
            throw ChartLoadError.modelFailed
        }
        return LoadedChart(
            model: model, summary: summary, smootherName: name,
            xName: xName, yName: yName, keptIndices: fit.keptIndices
        )
    }
}

/// Parse a file and pick its columns without fitting: the cheap half of
/// `loadChart(from:)`, so a UI can open instantly and fit in the
/// background. Column policy matches `loadChart`.
public func loadController(
    from url: URL, xColumn: String? = nil, yColumn: String? = nil,
    budget: TuningBudget = .full, smoother: SmootherChoice = .automatic
) throws -> FitController {
    let table = try CSVTable.load(contentsOf: url)
    try Task.checkCancellation()
    let (xName, yName) = try pickColumns(in: table, xColumn: xColumn, yColumn: yColumn)
    guard let trainX = table.numericMatrix(columns: [xName]),
          let trainY = table.doubles(forColumn: yName)
    else {
        throw ChartLoadError.badColumn("'\(xName)' / '\(yName)'")
    }
    return FitController(
        trainX: trainX, trainY: trainY, xName: xName, yName: yName, budget: budget, smoother: smoother
    )
}
