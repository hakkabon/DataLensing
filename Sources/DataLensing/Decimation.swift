// Decimation.swift
// DataLensing
//
// Min-max bucketing for the raw-points layer: Swift Charts chokes
// plotting 100k PointMarks, while the fitted curve stays full
// resolution (a few hundred grid evaluations). Per pixel column we keep
// the min-y and max-y points, which preserves the visual envelope with
// at most 2·buckets points — the standard downsampling for dense
// scatterplots.

import Foundation

/// Downsampling for dense point layers.
public enum Decimation: Sendable {
    /// Min-max bucketing over `x`.
    ///
    /// - Parameters:
    ///   - x: coordinates (need not be sorted; sorted internally).
    ///   - y: values, parallel to `x`.
    ///   - visible: optional x-window; points outside are dropped first.
    ///   - buckets: pixel columns to bucket into (must be positive).
    /// - Returns: at most `2 * buckets` points (plus nothing else),
    ///   ordered by x: per bucket the lowest-y and highest-y points.
    ///   Empty input (or nothing visible) yields empty output — never a trap.
    public static func decimate(
        x: [Double], y: [Double], visible: ClosedRange<Double>? = nil, buckets: Int
    ) -> (x: [Double], y: [Double]) {
        precondition(x.count == y.count, "x and y must have equal counts")
        precondition(buckets > 0, "buckets must be positive")
        guard !x.isEmpty else { return ([], []) }
        let lo: Double
        let hi: Double
        if let visible {
            lo = visible.lowerBound
            hi = visible.upperBound
        } else {
            guard let minX = x.min(), let maxX = x.max(), maxX > minX else {
                // Single x (or non-finite): one bucket keeps the envelope.
                return singleBucket(x: x, y: y)
            }
            lo = minX
            hi = maxX
        }
        guard hi > lo, hi.isFinite, lo.isFinite else {
            return singleBucket(x: x, y: y)
        }
        let width = hi - lo
        // Per-bucket min/max trackers (y value + original order for ties).
        var minY = [Double](repeating: .infinity, count: buckets)
        var maxY = [Double](repeating: -.infinity, count: buckets)
        var minX = [Double](repeating: 0, count: buckets)
        var maxX = [Double](repeating: 0, count: buckets)
        var counts = [Int](repeating: 0, count: buckets)
        for (px, py) in zip(x, y) {
            guard px.isFinite, py.isFinite, px >= lo, px <= hi else { continue }
            var b = Int((px - lo) / width * Double(buckets))
            if b >= buckets { b = buckets - 1 }  // px == hi lands exactly on the edge
            counts[b] += 1
            if counts[b] == 1 {
                minY[b] = py; maxY[b] = py; minX[b] = px; maxX[b] = px
            } else {
                if py < minY[b] { minY[b] = py; minX[b] = px }
                if py > maxY[b] { maxY[b] = py; maxX[b] = px }
            }
        }
        var outX: [Double] = []
        var outY: [Double] = []
        outX.reserveCapacity(2 * buckets)
        outY.reserveCapacity(2 * buckets)
        for b in 0..<buckets where counts[b] > 0 {
            if counts[b] == 1 {
                outX.append(minX[b]); outY.append(minY[b])
            } else if minX[b] < maxX[b] {
                outX.append(minX[b]); outY.append(minY[b])
                outX.append(maxX[b]); outY.append(maxY[b])
            } else if minX[b] > maxX[b] {
                outX.append(maxX[b]); outY.append(maxY[b])
                outX.append(minX[b]); outY.append(minY[b])
            } else {
                // Same x (vertical stack): both extremes matter.
                outX.append(minX[b]); outY.append(minY[b])
                outX.append(maxX[b]); outY.append(maxY[b])
            }
        }
        return (outX, outY)
    }

    /// Degenerate range: the envelope is just the global min/max.
    private static func singleBucket(x: [Double], y: [Double]) -> (x: [Double], y: [Double]) {
        var finite = zip(x, y).filter { $0.0.isFinite && $0.1.isFinite }
        guard !finite.isEmpty else { return ([], []) }
        finite.sort { $0.0 < $1.0 }
        let minPt = finite.min(by: { $0.1 < $1.1 })!
        let maxPt = finite.max(by: { $0.1 < $1.1 })!
        if minPt == maxPt { return ([minPt.0], [minPt.1]) }
        let pair = [minPt, maxPt].sorted { $0.0 < $1.0 }
        return (pair.map(\.0), pair.map(\.1))
    }
}
