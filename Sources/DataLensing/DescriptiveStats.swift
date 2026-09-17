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
