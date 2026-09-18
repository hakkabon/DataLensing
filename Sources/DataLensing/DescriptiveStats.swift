// DescriptiveStats.swift
// DataLensing
//
// Lightweight descriptive statistics over a column of doubles, plus
// convenience extensions on ChartModel that expose per-axis summaries.
// The viewer sidebar and export path consume this; no SwiftUI import
// needed here so it stays in the Foundation-only portion of the library.

import Foundation

/// A concise set of order-statistics and moments for one numeric column.
///
/// All statistics are computed eagerly from the initialiser's `values`
/// array.  The caller passes in already-cleaned data (no `NaN`, no
/// `±∞`) — the same surviving points that live in `ChartModel.rawX` /
/// `ChartModel.rawY`.
public struct DataSummary: Sendable {
    /// Number of finite data points.
    public let n: Int
    /// Arithmetic mean.
    public let mean: Double
    /// Median (linearly interpolated for even n).
    public let median: Double
    /// Sample standard deviation (Bessel-corrected, `0` when n ≤ 1).
    public let std: Double
    /// Minimum value.
    public let min: Double
    /// First quartile (Q1, lower quartile, 25th percentile).
    public let q1: Double
    /// Third quartile (Q3, upper quartile, 75th percentile).
    public let q3: Double
    /// Maximum value.
    public let max: Double

    /// Interquartile range (Q3 − Q1).
    public var iqr: Double { q3 - q1 }

    /// Compute summary statistics over `values`.
    ///
    /// - Parameter values: The raw numeric column, already stripped of NaN/Inf.
    ///   An empty array produces a summary with `n == 0` and all statistics `0`.
    public init(values: [Double]) {
        guard !values.isEmpty else {
            n = 0; mean = 0; median = 0; std = 0
            min = 0; q1 = 0; q3 = 0; max = 0
            return
        }
        n = values.count
        let sum = values.reduce(0, +)
        mean = sum / Double(n)

        let sorted = values.sorted()
        min = sorted[0]
        max = sorted[sorted.count - 1]
        median = Self.percentile(sorted: sorted, p: 0.5)
        q1 = Self.percentile(sorted: sorted, p: 0.25)
        q3 = Self.percentile(sorted: sorted, p: 0.75)

        if n > 1 {
            let m = mean  // local copy avoids 'self captured before initialized' error
            let variance = values.reduce(0.0) { $0 + ($1 - m) * ($1 - m) } / Double(n - 1)
            std = variance.squareRoot()
        } else {
            std = 0
        }
    }

    // MARK: - Export

    /// Tab-separated header + data row, suitable for pasting into a
    /// spreadsheet or copying to the clipboard.
    public var exportLine: String {
        let fmt: (Double) -> String = { String(format: "%.6g", $0) }
        return [n.description, fmt(mean), fmt(median), fmt(std),
                fmt(min), fmt(q1), fmt(q3), fmt(max)].joined(separator: "\t")
    }

    /// Column headers matching `exportLine`.
    public static let exportHeader =
        ["n", "mean", "median", "std", "min", "Q1", "Q3", "max"].joined(separator: "\t")

    // MARK: - Internals

    /// Linear-interpolation percentile on a pre-sorted array.
    private static func percentile(sorted: [Double], p: Double) -> Double {
        let n = sorted.count
        guard n > 1 else { return sorted[0] }
        let pos = p * Double(n - 1)
        let lo = Int(pos)
        let hi = Swift.min(lo + 1, n - 1)
        let frac = pos - Double(lo)
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }
}

// MARK: - ChartModel convenience extensions

public extension ChartModel {
    /// Descriptive statistics over the surviving predictor values.
    var xSummary: DataSummary { DataSummary(values: rawX) }

    /// Descriptive statistics over the surviving response values.
    var ySummary: DataSummary { DataSummary(values: rawY) }

    /// Normal QQ coordinates for finite residuals, ordered by residual.
    var residualQQ: (theoretical: [Double], observed: [Double]) {
        let observed = residuals.filter(\.isFinite).sorted()
        guard !observed.isEmpty else { return ([], []) }
        let n = Double(observed.count)
        let theoretical = observed.indices.map { i in
            NormalQuantile.inverse((Double(i) + 0.5) / n)
        }
        return (theoretical, observed)
    }

    /// Tab-separated representation of the fitted grid suitable for
    /// clipboard export.  Columns: x, fit, lower (or fit), upper (or fit).
    var fittedGridTSV: String {
        var lines = ["x\tfit\tlower\tupper"]
        for j in gridX.indices {
            let lo = hasBand ? lower[j] : mean[j]
            let up = hasBand ? upper[j] : mean[j]
            lines.append(String(
                format: "%.8g\t%.8g\t%.8g\t%.8g",
                gridX[j], mean[j], lo, up
            ))
        }
        return lines.joined(separator: "\n")
    }
}

/// Acklam's rational approximation to the inverse standard-normal CDF.
/// Accurate to better than 1e-9 over the plotting probabilities used here.
private enum NormalQuantile {
    static func inverse(_ p: Double) -> Double {
        precondition(p > 0 && p < 1, "normal quantile probability must be inside (0, 1)")
        let a = [-39.69683028665376, 220.9460984245205, -275.9285104469687,
                 138.3577518672690, -30.66479806614716, 2.506628277459239]
        let b = [-54.47609879822406, 161.5858368580409, -155.6989798598866,
                 66.80131188771972, -13.28068155288572]
        let c = [-0.007784894002430293, -0.3223964580411365, -2.400758277161838,
                 -2.549732539343734, 4.374664141464968, 2.938163982698783]
        let d = [0.007784695709041462, 0.3224671290700398,
                 2.445134137142996, 3.754408661907416]
        let tail = 0.02425
        if p < tail {
            let q = sqrt(-2 * log(p))
            return (((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        if p > 1 - tail {
            let q = sqrt(-2 * log(1 - p))
            return -(((((c[0] * q + c[1]) * q + c[2]) * q + c[3]) * q + c[4]) * q + c[5])
                / ((((d[0] * q + d[1]) * q + d[2]) * q + d[3]) * q + 1)
        }
        let q = p - 0.5
        let r = q * q
        return (((((a[0] * r + a[1]) * r + a[2]) * r + a[3]) * r + a[4]) * r + a[5]) * q
            / (((((b[0] * r + b[1]) * r + b[2]) * r + b[3]) * r + b[4]) * r + 1)
    }
}
