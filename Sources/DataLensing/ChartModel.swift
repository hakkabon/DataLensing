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
        gridX: [Double], mean: [Double], lower: [Double], upper: [Double]
    ) {
        precondition(rawX.count == rawY.count, "rawX and rawY must have equal counts")
        precondition(
            gridX.count == mean.count && mean.count == lower.count && lower.count == upper.count,
            "gridX, mean, lower, and upper must have equal counts"
        )
        self.rawX = rawX
        self.rawY = rawY
        self.gridX = gridX
        self.mean = mean
        self.lower = lower
        self.upper = upper
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
        trainX: [[Double]], trainY: [Double], fit: FittedSmoother, gridCount: Int = 200
    ) -> ChartModel? {
        guard let prepared = prepare(trainX: trainX, trainY: trainY, fit: fit, gridCount: gridCount) else {
            return nil
        }
        let mean = fit.predict(prepared.grid)
        let optionals = fit.standardErrors(at: prepared.grid)
        return assemble(prepared: prepared, mean: mean, se: optionals.compactMap { $0 }, gridCount: gridCount)
    }

    /// Concurrent twin of `make`: the grid is evaluated with the
    /// smoother's concurrent batch paths (identical values, spread over
    /// the cooperative pool). The viewer path; the sync `make` stays
    /// for CLI/tests.
    public static func makeConcurrently(
        trainX: [[Double]], trainY: [Double], fit: FittedSmoother, gridCount: Int = 200
    ) async throws -> ChartModel? {
        guard let prepared = prepare(trainX: trainX, trainY: trainY, fit: fit, gridCount: gridCount) else {
            return nil
        }
        let mean = try await fit.predictConcurrently(prepared.grid)
        let optionals = try await fit.standardErrorsConcurrently(at: prepared.grid)
        return assemble(prepared: prepared, mean: mean, se: optionals.compactMap { $0 }, gridCount: gridCount)
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

    private static func assemble(prepared: Prepared, mean: [Double], se: [Double], gridCount: Int) -> ChartModel? {
        // Nil SEs mean "unavailable here" (width mismatch or a
        // non-polynomial policy refusing to extrapolate) — the band has
        // no honest value at those points, so the build fails rather
        // than inventing one. On the training hull with the default
        // policy this never triggers.
        guard mean.count == gridCount, se.count == gridCount else { return nil }
        let lower = zip(mean, se).map { $0 - 2 * $1 }
        let upper = zip(mean, se).map { $0 + 2 * $1 }
        return ChartModel(
            rawX: prepared.xs, rawY: prepared.ys,
            gridX: prepared.gridX, mean: mean, lower: lower, upper: upper
        )
    }
}
