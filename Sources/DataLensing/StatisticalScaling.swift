import Foundation

/// An explicit policy for bounding a statistical fit while retaining an
/// auditable, deterministic selection rule.
///
/// This policy affects model fitting and validation only. Chart rendering has
/// its own lossless min/max decimation path, so a display optimization can
/// never silently change a statistical result.
public enum StatisticalScalePolicy: Codable, Sendable, Hashable {
    /// Fit every finite predictor/response row.
    case fullData
    /// Divide observations ordered by their leading predictor into contiguous
    /// strata and draw one deterministic row per stratum. This preserves broad
    /// predictor coverage while bounding the cost of a smoother or GAM.
    case stratifiedLeadingPredictor(maximumObservations: Int, seed: UInt64)

    public var isValid: Bool {
        switch self {
        case .fullData: return true
        case .stratifiedLeadingPredictor(let maximumObservations, _):
            return maximumObservations >= 2
        }
    }

    public var requestedMaximumObservations: Int? {
        switch self {
        case .fullData: return nil
        case .stratifiedLeadingPredictor(let maximumObservations, _): return maximumObservations
        }
    }

    /// Select finite rows in their original source order.
    public func select(
        predictors: [[Double]], response: [Double]
    ) throws -> StatisticalScaleSelection {
        guard isValid, predictors.count == response.count,
              predictors.allSatisfy({ !$0.isEmpty }) else {
            throw StatisticalScaleError.invalidInput
        }
        let eligible = response.indices.filter { row in
            response[row].isFinite && predictors[row].allSatisfy(\.isFinite)
        }
        let selected: [Int]
        switch self {
        case .fullData:
            selected = eligible
        case .stratifiedLeadingPredictor(let maximumObservations, let seed):
            guard eligible.count > maximumObservations else {
                selected = eligible
                break
            }
            let ordered = eligible.sorted { lhs, rhs in
                let left = predictors[lhs][0]
                let right = predictors[rhs][0]
                return left == right ? lhs < rhs : left < right
            }
            var generator = SplitMix64(seed: seed)
            var sampled: [Int] = []
            sampled.reserveCapacity(maximumObservations)
            for stratum in 0..<maximumObservations {
                let lower = stratum * ordered.count / maximumObservations
                let upper = (stratum + 1) * ordered.count / maximumObservations
                let width = upper - lower
                sampled.append(ordered[lower + Int(generator.next() % UInt64(width))])
            }
            selected = sampled.sorted()
        }
        return StatisticalScaleSelection(
            policy: self, inputObservationCount: response.count,
            eligibleObservationCount: eligible.count, selectedIndices: selected
        )
    }
}

/// The observed effect of a `StatisticalScalePolicy` on one exact dataset.
public struct StatisticalScaleSelection: Codable, Sendable, Hashable {
    public let policy: StatisticalScalePolicy
    public let inputObservationCount: Int
    public let eligibleObservationCount: Int
    /// Indices into the data supplied to `StatisticalScalePolicy.select`.
    public let selectedIndices: [Int]

    public init(
        policy: StatisticalScalePolicy, inputObservationCount: Int,
        eligibleObservationCount: Int, selectedIndices: [Int]
    ) {
        self.policy = policy
        self.inputObservationCount = inputObservationCount
        self.eligibleObservationCount = eligibleObservationCount
        self.selectedIndices = selectedIndices
    }

    public var selectedObservationCount: Int { selectedIndices.count }
    public var reduced: Bool { selectedObservationCount < eligibleObservationCount }

    public var isValid: Bool {
        policy.isValid && inputObservationCount >= 0 && eligibleObservationCount >= 0
            && eligibleObservationCount <= inputObservationCount
            && selectedIndices.count <= eligibleObservationCount
            && Set(selectedIndices).count == selectedIndices.count
            && selectedIndices == selectedIndices.sorted()
            && selectedIndices.allSatisfy { (0..<inputObservationCount).contains($0) }
    }
}

public enum StatisticalScaleError: Error, Sendable, Hashable {
    case invalidInput
}

/// Small deterministic generator kept local so scale selections never depend
/// on platform RNG state or on an external random-number implementation.
private struct SplitMix64: Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
