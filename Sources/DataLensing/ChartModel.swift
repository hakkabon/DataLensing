// ChartModel.swift
// DataLensing
//
// The shared seam between a fitted smoother and anything that draws it:
// plain `Double` arrays (raw points, evaluation grid, mean ± 2 SE band).
// Both the CLI spike and the SwiftUI chart consume this; neither the
// parser nor the view needs to know about the other.

import DataLens
import Foundation

/// Everything a chart needs from a fit: the surviving raw points plus
/// the fitted curve with an uncertainty band on a shared grid.
///
/// All arrays are parallel: `rawX[i]` pairs with `rawY[i]`, and
/// `gridX[j]` pairs with `mean[j]` / `lower[j]` / `upper[j]`.
public struct ChartModel: Sendable {
    /// Surviving training coordinates (post-`droppingMissing`, in order).
    public let rawX: [Double]
    /// Surviving training responses (post-`droppingMissing`, in order).
    public let rawY: [Double]
    /// Evaluation grid (evenly spaced over the training hull).
    public let gridX: [Double]
    /// Fitted mean on the grid.
    public let mean: [Double]
    /// Mean − 2 SE on the grid.
    public let lower: [Double]
    /// Mean + 2 SE on the grid.
    public let upper: [Double]

    public init(
        rawX: [Double], rawY: [Double],
        gridX: [Double], mean: [Double], lower: [Double] = [], upper: [Double] = []
    ) {
        precondition(rawX.count == rawY.count, "rawX and rawY must have equal counts")
        precondition(gridX.count == mean.count, "gridX and mean must have equal counts")
        precondition(
            lower.count == upper.count && (lower.isEmpty || lower.count == mean.count),
            "lower and upper must have matching counts and either be empty or match mean count"
        )
        self.rawX = rawX
        self.rawY = rawY
        self.gridX = gridX
        self.mean = mean
        self.lower = lower
        self.upper = upper
    }

    /// Whether an uncertainty band (±2 SE) is available on the grid.
    public var hasBand: Bool {
        !lower.isEmpty && lower.count == mean.count && upper.count == mean.count
    }

    /// Build a chart model from parsed columns and a fit.
    ///
    /// - Parameters:
    ///   - trainX: row-major training coordinates (the `[[Double]]` handed to the fit).
    ///   - trainY: training responses, with missing values as `.nan`.
    ///   - fit: the smoother already fitted with `droppingMissing: true`.
    ///   - gridCount: number of evenly spaced grid points over the
    ///     surviving hull (must be positive).
    /// - Returns: `nil` when no rows survive, the grid is empty, or the
    ///   fit reports no `keptIndices` (data-dependent failures, never traps).
    public static func make(
        trainX: [[Double]], trainY: [Double], fit: FittedSmoother, gridCount: Int = 200,
        fastAdaptivePrediction: Bool = false
    ) -> ChartModel? {
        guard let prepared = prepare(trainX: trainX, trainY: trainY, fit: fit, gridCount: gridCount) else {
            return nil
        }
        let mean: [Double]
        let optionals: [Double?]
        if fastAdaptivePrediction, case .adaptive(let adaptive) = fit {
            mean = adaptive.predictFast(prepared.grid)
            optionals = adaptive.standardErrorsFast(at: prepared.grid)
        } else {
            mean = fit.predict(prepared.grid)
            optionals = fit.standardErrors(at: prepared.grid)
        }
        return assemble(prepared: prepared, mean: mean, optionalsSE: optionals, gridCount: gridCount)
    }

    /// Concurrent twin of `make`: the grid is evaluated with the
    /// smoother's concurrent batch paths (identical values, spread over
    /// the cooperative pool). The viewer path; the sync `make` stays
    /// for CLI/tests.
    public static func makeConcurrently(
        trainX: [[Double]], trainY: [Double], fit: FittedSmoother, gridCount: Int = 200,
        fastAdaptivePrediction: Bool = false
    ) async throws -> ChartModel? {
        guard let prepared = prepare(trainX: trainX, trainY: trainY, fit: fit, gridCount: gridCount) else {
            return nil
        }
        let mean: [Double]
        let optionals: [Double?]
        if fastAdaptivePrediction, case .adaptive(let adaptive) = fit {
            mean = try await adaptive.predictFastConcurrently(prepared.grid)
            optionals = try await adaptive.standardErrorsFastConcurrently(at: prepared.grid)
        } else {
            mean = try await fit.predictConcurrently(prepared.grid)
            optionals = try await fit.standardErrorsConcurrently(at: prepared.grid)
        }
        return assemble(prepared: prepared, mean: mean, optionalsSE: optionals, gridCount: gridCount)
    }

    /// Fitted mean at `x` by linear interpolation on the grid, or `nil`
    /// when the grid is empty or `x` falls outside it (no extrapolation:
    /// the inspector shows a gap, never an invention).
    public func interpolatedMean(at x: Double) -> Double? {
        interpolatedBand(at: x)?.mean
    }

    /// Fitted mean and ±2 SE band at `x` by linear interpolation on the grid.
    /// When standard errors are absent, `lower` and `upper` return `mean`.
    /// Returns `nil` when `x` falls outside the grid.
    public func interpolatedBand(at x: Double) -> (mean: Double, lower: Double, upper: Double)? {
        guard gridX.count >= 2, mean.count == gridX.count,
              x.isFinite, let lo = gridX.first, let hi = gridX.last,
              x >= lo, x <= hi
        else { return nil }
        // Binary search the bracketing segment (grid is ascending).
        var low = 0
        var high = gridX.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if gridX[mid] <= x {
                low = mid
            } else {
                high = mid
            }
        }
        let x0 = gridX[low]
        let x1 = gridX[high]
        let t = (x1 > x0) ? (x - x0) / (x1 - x0) : 0.0
        let m = mean[low] * (1 - t) + mean[high] * t
        if hasBand {
            let l = lower[low] * (1 - t) + lower[high] * t
            let u = upper[low] * (1 - t) + upper[high] * t
            return (m, l, u)
        } else {
            return (m, m, m)
        }
    }

    // MARK: - Shared core

    /// Validated inputs: surviving points plus the grid. `nil` for the
    /// same data-dependent reasons `make` returns `nil`.
    private struct Prepared: Sendable {
        let xs: [Double]
        let ys: [Double]
        let gridX: [Double]
        let grid: [[Double]]
    }

    private static func prepare(
        trainX: [[Double]], trainY: [Double], fit: FittedSmoother, gridCount: Int
    ) -> Prepared? {
        guard gridCount > 0, !fit.keptIndices.isEmpty else { return nil }
        var xs: [Double] = []
        var ys: [Double] = []
        xs.reserveCapacity(fit.keptIndices.count)
        ys.reserveCapacity(fit.keptIndices.count)
        for i in fit.keptIndices {
            guard trainX.indices.contains(i), trainY.indices.contains(i) else { return nil }
            guard trainX[i].count == 1 else { return nil }  // spike scope: single predictor
            xs.append(trainX[i][0])
            ys.append(trainY[i])
        }
        guard let lo = xs.min(), let hi = xs.max(), hi > lo else { return nil }
        let gridX = (0..<gridCount).map { lo + (hi - lo) * Double($0) / Double(gridCount - 1) }
        return Prepared(xs: xs, ys: ys, gridX: gridX, grid: gridX.map { [$0] })
    }

    private static func assemble(
        prepared: Prepared, mean: [Double], optionalsSE: [Double?], gridCount: Int
    ) -> ChartModel? {
        guard mean.count == gridCount else { return nil }
        // If all SEs are present and finite, build full ±2 SE bands.
        // If any SE is missing/nil (e.g. non-polynomial boundary or smoother
        // without variance estimate), gracefully assemble without bands rather than failing.
        let seValues = optionalsSE.compactMap { $0 }
        let (lower, upper): ([Double], [Double])
        if seValues.count == gridCount && seValues.allSatisfy({ $0.isFinite }) {
            lower = zip(mean, seValues).map { $0 - 2 * $1 }
            upper = zip(mean, seValues).map { $0 + 2 * $1 }
        } else {
            lower = []
            upper = []
        }
        return ChartModel(
            rawX: prepared.xs, rawY: prepared.ys,
            gridX: prepared.gridX, mean: mean, lower: lower, upper: upper
        )
    }
}
