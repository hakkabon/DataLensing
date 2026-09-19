// ChartModel.swift
// DataLensing
//
// The shared seam between a fitted smoother and anything that draws it:
// plain `Double` arrays (raw points, evaluation grid, mean ± 2 SE band).
// Both the CLI spike and the SwiftUI chart consume this; neither the
// parser nor the view needs to know about the other.

import DataLens
import Foundation

/// Semantic scale of fitted values shown by the frontend.
public enum ResponseScale: String, Codable, Sendable, Hashable {
    case continuous = "Response"
    case probability = "Probability"
    case intensity = "Expected count"
}

/// Residual definition used by a chart model.
public enum ResidualKind: String, Sendable, Hashable {
    case raw = "Raw residual"
    case pearson = "Pearson residual"
}

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
    /// First partial derivative on the one-dimensional evaluation grid.
    /// Degenerate local fits are represented by `NaN` to preserve alignment.
    public let gradient: [Double]
    /// Fitted response at each surviving training point.
    public let fittedAtTraining: [Double]
    /// Diagnostic residual at each surviving training point.
    public let residuals: [Double]
    public let responseScale: ResponseScale
    public let residualKind: ResidualKind

    public init(
        rawX: [Double], rawY: [Double],
        gridX: [Double], mean: [Double], lower: [Double] = [], upper: [Double] = [],
        gradient: [Double] = [], fittedAtTraining: [Double] = [], residuals: [Double] = [],
        responseScale: ResponseScale = .continuous, residualKind: ResidualKind = .raw
    ) {
        precondition(rawX.count == rawY.count, "rawX and rawY must have equal counts")
        precondition(gridX.count == mean.count, "gridX and mean must have equal counts")
        precondition(
            lower.count == upper.count && (lower.isEmpty || lower.count == mean.count),
            "lower and upper must have matching counts and either be empty or match mean count"
        )
        precondition(gradient.isEmpty || gradient.count == gridX.count,
                     "gradient must be empty or match gridX")
        precondition(fittedAtTraining.isEmpty || fittedAtTraining.count == rawX.count,
                     "fittedAtTraining must be empty or match rawX")
        precondition(residuals.isEmpty || residuals.count == rawX.count,
                     "residuals must be empty or match rawX")
        self.rawX = rawX
        self.rawY = rawY
        self.gridX = gridX
        self.mean = mean
        self.lower = lower
        self.upper = upper
        self.gradient = gradient
        self.fittedAtTraining = fittedAtTraining
        self.residuals = residuals
        self.responseScale = responseScale
        self.residualKind = residualKind
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
        let gradients = fit.gradients(at: prepared.grid).map { $0?.first ?? .nan }
        return assemble(
            prepared: prepared, fit: fit, mean: mean, optionalsSE: optionals,
            gradients: gradients, gridCount: gridCount
        )
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
        let gradients = try await fit.gradientsConcurrently(at: prepared.grid).map { $0?.first ?? .nan }
        return assemble(
            prepared: prepared, fit: fit, mean: mean, optionalsSE: optionals,
            gradients: gradients, gridCount: gridCount
        )
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
        prepared: Prepared, fit: FittedSmoother, mean: [Double], optionalsSE: [Double?],
        gradients: [Double], gridCount: Int
    ) -> ChartModel? {
        guard mean.count == gridCount, gradients.count == gridCount,
              fit.fittedValues.count == prepared.ys.count else { return nil }
        // If all SEs are present and finite, build full ±2 SE bands.
        // If any SE is missing/nil (e.g. non-polynomial boundary or smoother
        // without variance estimate), gracefully assemble without bands rather than failing.
        let metadata = responseMetadata(for: fit)
        let seValues = optionalsSE.compactMap { $0 }
        let (lower, upper): ([Double], [Double])
        if seValues.count == gridCount && seValues.allSatisfy({ $0.isFinite }) {
            lower = zip(mean, seValues).map { fitted, se in
                let value = fitted - 2 * se
                return metadata.scale == .continuous ? value : max(0, value)
            }
            upper = zip(mean, seValues).map { fitted, se in
                let value = fitted + 2 * se
                return metadata.scale == .probability ? min(1, value) : value
            }
        } else {
            lower = []
            upper = []
        }
        let residuals = zip(prepared.ys, fit.fittedValues).map { pair in
            let (y, fitted) = pair
            switch metadata.residualKind {
            case .raw:
                return y - fitted
            case .pearson:
                let variance: Double
                switch metadata.scale {
                case .probability: variance = fitted * (1 - fitted)
                case .intensity: variance = fitted
                case .continuous: variance = 1
                }
                return variance > 0 ? (y - fitted) / sqrt(variance) : .nan
            }
        }
        return ChartModel(
            rawX: prepared.xs, rawY: prepared.ys,
            gridX: prepared.gridX, mean: mean, lower: lower, upper: upper,
            gradient: gradients, fittedAtTraining: fit.fittedValues, residuals: residuals,
            responseScale: metadata.scale, residualKind: metadata.residualKind
        )
    }

    private static func responseMetadata(
        for fit: FittedSmoother
    ) -> (scale: ResponseScale, residualKind: ResidualKind) {
        guard case .likelihood(let likelihood) = fit else { return (.continuous, .raw) }
        switch likelihood.family {
        case .gaussian: return (.continuous, .raw)
        case .binomial: return (.probability, .pearson)
        case .poisson: return (.intensity, .pearson)
        }
    }
}
