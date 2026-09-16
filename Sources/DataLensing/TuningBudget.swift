// TuningBudget.swift
// DataLensing
//
// What a fit is allowed to spend: tuning breadth, robustness passes,
// and curve resolution. Measured on 1000 sine rows (release): full
// auto-tune ≈ 38s, single-span light ≈ 13s, parse ≈ 0.01s — the fit
// dominates everything, so the budget is the interactive lever.

import Foundation

/// What one fit may spend.
///
/// `spans: nil` means the library defaults (`AutomaticSmoother`
/// default spans with adaptive-vs-fixed competition); an explicit list
/// still runs the adaptive contender once — the budget trims the fixed
/// spans and robustness passes, not the competition itself.
///
/// `fastAdaptivePrediction` routes adaptive grid evaluation through the
/// borrowed-bandwidth fast paths (upstream bench: ~25× means, ~45× SEs,
/// agreement inside half the noise scale). Exact by default; on for the
/// interactive preset, where a 60 Hz scroll matters more than the third
/// decimal.
///
/// `adaptiveContender` mirrors `AutomaticSmoother.fit`: `false` skips
/// the adaptive leg and tunes fixed-span Loess only (shallow tuning).
/// Measured 14.1s → 5.2s release on the interactive budget. The fitted
/// summary always records the skip — shallow fits say they are shallow.
///
/// `smoothingPenalty` is the Whittaker λ (penalty scale, not a span —
/// think 1…1e6, not 0.3…0.75). `nil` selects by GCV over a coarse
/// log-spaced grid; an explicit value skips selection. Only read by the
/// `.whittaker` choice.
public struct TuningBudget: Sendable, Hashable {
    /// Local-polynomial degree (0...2, mirroring the smoothers).
    public var degree: Int
    /// Fixed spans to compete, or `nil` for the library defaults.
    public var spans: [Double]?
    /// Robustness reweighting passes.
    public var robustIterations: Int
    /// Evaluation-grid points per curve build.
    public var gridCount: Int
    /// Borrowed-bandwidth adaptive grids (approximation, documented above).
    public var fastAdaptivePrediction: Bool
    /// Whether the adaptive smoother competes in tuning (see above).
    public var adaptiveContender: Bool
    /// Whittaker penalty λ, or nil for GCV selection (see above).
    public var smoothingPenalty: Double?

    /// Full quality: library-default tuning, the 0.1.0–0.3.0 behavior.
    public static let full = TuningBudget(
        degree: 2, spans: nil, robustIterations: 4, gridCount: 200,
        fastAdaptivePrediction: false, adaptiveContender: true,
        smoothingPenalty: nil
    )
    /// Interactive: one fixed span, one robust pass, fast adaptive grids,
    /// no adaptive contender. Same routing, a fraction of the spend —
    /// the viewer default.
    public static let interactive = TuningBudget(
        degree: 2, spans: [0.5], robustIterations: 1, gridCount: 200,
        fastAdaptivePrediction: true, adaptiveContender: false,
        smoothingPenalty: nil
    )

    public init(
        degree: Int = 2, spans: [Double]? = nil, robustIterations: Int = 4,
        gridCount: Int = 200, fastAdaptivePrediction: Bool = false,
        adaptiveContender: Bool = true, smoothingPenalty: Double? = nil
    ) {
        precondition((0...2).contains(degree), "degree must be 0, 1, or 2")
        if let spans {
            precondition(!spans.isEmpty, "spans must be non-empty when provided")
            precondition(spans.allSatisfy { $0.isFinite && $0 > 0 }, "spans must be finite and positive")
        }
        precondition(robustIterations >= 0, "robustIterations must be non-negative")
        precondition(gridCount > 0, "gridCount must be positive")
        if let smoothingPenalty {
            precondition(
                smoothingPenalty.isFinite && smoothingPenalty >= 0,
                "smoothingPenalty must be finite and non-negative when provided"
            )
        }
        self.degree = degree
        self.spans = spans
        self.robustIterations = robustIterations
        self.gridCount = gridCount
        self.fastAdaptivePrediction = fastAdaptivePrediction
        self.adaptiveContender = adaptiveContender
        self.smoothingPenalty = smoothingPenalty
    }
}
