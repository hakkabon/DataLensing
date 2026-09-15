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

/// Owns one file's columns, tuning budget, and cached fit.
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
    public private(set) var loaded: LoadedChart?

    /// Fitted hull over the surviving predictors, or `nil` before the
    /// first fit.
    public var hull: ClosedRange<Double>? {
        guard let xs = loaded?.model.rawX, let lo = xs.min(), let hi = xs.max(), hi > lo else {
            return nil
        }
        return lo...hi
    }

    public init(trainX: [[Double]], trainY: [Double], xName: String, yName: String, budget: TuningBudget = .full) {
        precondition(trainX.count == trainY.count, "trainX and trainY must have equal counts")
        self.trainX = trainX
        self.trainY = trainY
        self.xName = xName
        self.yName = yName
        self.budget = budget
    }

    /// Fit synchronously (CLI / tests), spending the budget once.
    @discardableResult
    public mutating func fit() throws -> LoadedChart {
        guard let (fit, summary) = AutomaticSmoother.fit(
            trainX: trainX, trainY: trainY,
            degree: budget.degree, spans: budget.spans,
            robustIterations: budget.robustIterations, droppingMissing: true
        ) else {
            throw ChartLoadError.fitFailed
        }
        try Task.checkCancellation()
        guard let model = ChartModel.make(
            trainX: trainX, trainY: trainY, fit: fit, gridCount: budget.gridCount,
            fastAdaptivePrediction: budget.fastAdaptivePrediction
        ) else {
            throw ChartLoadError.modelFailed
        }
        let loaded = LoadedChart(model: model, summary: summary, xName: xName, yName: yName)
        self.loaded = loaded
        return loaded
    }

    /// Fit with the grid evaluated concurrently (viewer path).
    @discardableResult
    public mutating func fitConcurrently() async throws -> LoadedChart {
        guard let (fit, summary) = AutomaticSmoother.fit(
            trainX: trainX, trainY: trainY,
            degree: budget.degree, spans: budget.spans,
            robustIterations: budget.robustIterations, droppingMissing: true
        ) else {
            throw ChartLoadError.fitFailed
        }
        try Task.checkCancellation()
        guard let model = try await ChartModel.makeConcurrently(
            trainX: trainX, trainY: trainY, fit: fit, gridCount: budget.gridCount,
            fastAdaptivePrediction: budget.fastAdaptivePrediction
        ) else {
            throw ChartLoadError.modelFailed
        }
        let loaded = LoadedChart(model: model, summary: summary, xName: xName, yName: yName)
        self.loaded = loaded
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
}

/// Parse a file and pick its columns without fitting: the cheap half of
/// `loadChart(from:)`, so a UI can open instantly and fit in the
/// background. Column policy matches `loadChart`.
public func loadController(
    from url: URL, xColumn: String? = nil, yColumn: String? = nil, budget: TuningBudget = .full
) throws -> FitController {
    let table = try CSVTable.load(contentsOf: url)
    try Task.checkCancellation()
    let (xName, yName) = try pickColumns(in: table, xColumn: xColumn, yColumn: yColumn)
    guard let trainX = table.numericMatrix(columns: [xName]),
          let trainY = table.doubles(forColumn: yName)
    else {
        throw ChartLoadError.badColumn("'\(xName)' / '\(yName)'")
    }
    return FitController(trainX: trainX, trainY: trainY, xName: xName, yName: yName, budget: budget)
}
