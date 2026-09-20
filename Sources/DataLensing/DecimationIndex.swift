import Foundation

/// Immutable spatial index for repeated dense-scatter decimation.
///
/// Building the index sorts finite observations once and materializes a
/// min/max segment tree. Subsequent viewport queries cost
/// `O(buckets · log(n))`, rather than scanning every source row each time a
/// chart scrolls or zooms. It is intended for interactive series large enough
/// that `Decimation.decimate`'s one-pass scan is no longer frame-friendly.
public struct DecimationIndex: Sendable {
    private struct Point: Sendable {
        let x: Double
        let y: Double
        let sourceOrder: Int
    }

    private let points: [Point]
    private let leafBase: Int
    // `-1` is the empty-node sentinel. Int32 keeps a 500k-point index under
    // roughly 16 MB in addition to the source arrays, which matters on iPad.
    private let minimum: [Int32]
    private let maximum: [Int32]

    /// Build an index from parallel coordinate arrays. Non-finite points are
    /// excluded, matching `Decimation.decimate`.
    public init(x: [Double], y: [Double]) {
        precondition(x.count == y.count, "x and y must have equal counts")
        var finite: [Point] = []
        finite.reserveCapacity(x.count)
        for (index, pair) in zip(x.indices, zip(x, y)) where pair.0.isFinite && pair.1.isFinite {
            finite.append(Point(x: pair.0, y: pair.1, sourceOrder: index))
        }
        finite.sort {
            $0.x == $1.x ? $0.sourceOrder < $1.sourceOrder : $0.x < $1.x
        }
        points = finite

        var base = 1
        while base < finite.count { base <<= 1 }
        leafBase = base
        var minimum = [Int32](repeating: -1, count: 2 * base)
        var maximum = [Int32](repeating: -1, count: 2 * base)
        for index in finite.indices {
            minimum[base + index] = Int32(index)
            maximum[base + index] = Int32(index)
        }
        if base > 1 {
            for node in stride(from: base - 1, through: 1, by: -1) {
                minimum[node] = DecimationIndex.pickMinimum(
                    minimum[node * 2], minimum[node * 2 + 1], points: finite
                )
                maximum[node] = DecimationIndex.pickMaximum(
                    maximum[node * 2], maximum[node * 2 + 1], points: finite
                )
            }
        }
        self.minimum = minimum
        self.maximum = maximum
    }

    /// Whether the index contains at least one finite observation.
    public var isEmpty: Bool { points.isEmpty }

    /// Decimate a visible x-window into min/max envelopes.
    ///
    /// Results are x-ordered and contain at most `2 * buckets` points.
    /// Invalid/degenerate windows use the index's full finite hull, while a
    /// non-overlapping window returns no points.
    public func decimate(visible: ClosedRange<Double>? = nil, buckets: Int) -> (x: [Double], y: [Double]) {
        precondition(buckets > 0, "buckets must be positive")
        guard let first = points.first, let last = points.last, first.x <= last.x else { return ([], []) }
        let domain: ClosedRange<Double>
        if let visible, visible.lowerBound.isFinite, visible.upperBound.isFinite,
           visible.upperBound > visible.lowerBound {
            domain = visible
        } else if last.x > first.x {
            domain = first.x...last.x
        } else {
            return envelope(in: 0..<points.count)
        }
        guard domain.upperBound >= first.x, domain.lowerBound <= last.x else { return ([], []) }
        let clippedLower = max(domain.lowerBound, first.x)
        let clippedUpper = min(domain.upperBound, last.x)
        guard clippedUpper >= clippedLower else { return ([], []) }
        if clippedUpper == clippedLower { return envelope(in: range(for: clippedLower...clippedUpper)) }

        let width = clippedUpper - clippedLower
        var selected = Set<Int>()
        selected.reserveCapacity(2 * buckets)
        for bucket in 0..<buckets {
            let lower = clippedLower + width * Double(bucket) / Double(buckets)
            let upper = bucket == buckets - 1
                ? clippedUpper
                : clippedLower + width * Double(bucket + 1) / Double(buckets)
            let range = range(for: lower...upper, upperInclusive: bucket == buckets - 1)
            let extrema = extrema(in: range)
            if extrema.minimum >= 0 { selected.insert(Int(extrema.minimum)) }
            if extrema.maximum >= 0 { selected.insert(Int(extrema.maximum)) }
        }
        let ordered = selected.sorted()
        return (ordered.map { points[$0].x }, ordered.map { points[$0].y })
    }

    private func envelope(in range: Range<Int>) -> (x: [Double], y: [Double]) {
        let extrema = extrema(in: range)
        var selected: [Int] = []
        if extrema.minimum >= 0 { selected.append(Int(extrema.minimum)) }
        if extrema.maximum >= 0, extrema.maximum != extrema.minimum { selected.append(Int(extrema.maximum)) }
        selected.sort()
        return (selected.map { points[$0].x }, selected.map { points[$0].y })
    }

    private func range(for visible: ClosedRange<Double>, upperInclusive: Bool = true) -> Range<Int> {
        let lower = lowerBound(visible.lowerBound)
        let upper = upperInclusive ? upperBound(visible.upperBound) : lowerBound(visible.upperBound)
        return lower..<max(lower, upper)
    }

    private func lowerBound(_ value: Double) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].x < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func upperBound(_ value: Double) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].x <= value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func extrema(in range: Range<Int>) -> (minimum: Int32, maximum: Int32) {
        guard !range.isEmpty else { return (-1, -1) }
        var left = range.lowerBound + leafBase
        var right = range.upperBound + leafBase
        var minimum: Int32 = -1
        var maximum: Int32 = -1
        while left < right {
            if (left & 1) == 1 {
                minimum = Self.pickMinimum(minimum, self.minimum[left], points: points)
                maximum = Self.pickMaximum(maximum, self.maximum[left], points: points)
                left += 1
            }
            if (right & 1) == 1 {
                right -= 1
                minimum = Self.pickMinimum(minimum, self.minimum[right], points: points)
                maximum = Self.pickMaximum(maximum, self.maximum[right], points: points)
            }
            left >>= 1
            right >>= 1
        }
        return (minimum, maximum)
    }

    private static func pickMinimum(_ lhs: Int32, _ rhs: Int32, points: [Point]) -> Int32 {
        guard lhs >= 0 else { return rhs }
        guard rhs >= 0 else { return lhs }
        let left = points[Int(lhs)]
        let right = points[Int(rhs)]
        return right.y < left.y ? rhs : lhs
    }

    private static func pickMaximum(_ lhs: Int32, _ rhs: Int32, points: [Point]) -> Int32 {
        guard lhs >= 0 else { return rhs }
        guard rhs >= 0 else { return lhs }
        let left = points[Int(lhs)]
        let right = points[Int(rhs)]
        return right.y > left.y ? rhs : lhs
    }
}
