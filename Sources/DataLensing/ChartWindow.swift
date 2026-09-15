// ChartWindow.swift
// DataLensing
//
// Viewer windowing policy, kept pure and testable: small series show
// the full hull (nothing to scroll); large ones open on a leading
// window so scrolling exists and every rendered frame stays cheap.

import Foundation

/// Initial visible-window policy for the chart.
public enum ChartWindow: Sendable {
    /// Length of the initial visible x-window, or `nil` for the full hull.
    ///
    /// - Parameters:
    ///   - hull: fitted hull, or `nil` before the first fit.
    ///   - pointCount: surviving raw points.
    ///   - threshold: point counts at or below this show everything.
    ///   - fraction: window share of the hull width for large series.
    /// - Returns: `nil` when the full hull fits the policy (small series
    ///   or degenerate hull), else `fraction` of the hull width.
    public static func initialVisibleLength(
        hull: ClosedRange<Double>?, pointCount: Int, threshold: Int = 4000, fraction: Double = 0.2
    ) -> Double? {
        precondition(threshold >= 0, "threshold must be non-negative")
        precondition(fraction > 0 && fraction <= 1, "fraction must be in (0, 1]")
        guard let hull, pointCount > threshold else { return nil }
        let width = hull.upperBound - hull.lowerBound
        guard width > 0, width.isFinite else { return nil }
        return width * fraction
    }
}
