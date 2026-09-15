// GenerationGate.swift
// DataLensing
//
// Why cancel feels slow without this: a cancelled task stuck awaiting a
// synchronous CPU-bound child (the fit) finishes the child before its
// `catch` runs — and a superseded task that finishes normally would
// otherwise overwrite newer state with stale results. The gate fixes
// both: the UI updates optimistically on cancel, and every completion
// applies only when its generation is still current.

import Foundation

/// Monotonic generations for supersedable work: each new task takes the
/// next generation; cancel invalidates without starting work; completions
/// check currency before touching shared state.
public struct GenerationGate: Sendable {
    private var current = 0

    public init() {}

    /// Claim the generation for a new task.
    public mutating func next() -> Int {
        current += 1
        return current
    }

    /// Invalidate outstanding work (cancel). Future completions fail
    /// `isCurrent` until a new task claims `next()`.
    public mutating func invalidate() {
        current += 1
    }

    /// Whether `generation` is still the latest claim.
    public func isCurrent(_ generation: Int) -> Bool {
        generation == current
    }
}
