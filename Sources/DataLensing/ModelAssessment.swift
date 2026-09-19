import Foundation

/// Severity of a model-checking observation.
public enum DiagnosticSeverity: String, Codable, Sendable, Hashable {
    case information
    case caution
}

/// A concise, serializable model-checking observation.
public struct DiagnosticFinding: Codable, Sendable, Hashable {
    public let severity: DiagnosticSeverity
    public let code: String
    public let message: String

    public init(severity: DiagnosticSeverity, code: String, message: String) {
        self.severity = severity
        self.code = code
        self.message = message
    }
}

/// Family-aware goodness-of-fit and residual checks for a rendered model.
///
/// These are descriptive training diagnostics, not claims about out-of-sample
/// performance. That distinction is part of the exported contract.
public struct ModelAssessment: Codable, Sendable, Hashable {
    public let responseScale: ResponseScale
    public let observationCount: Int
    public let rootMeanSquaredError: Double
    public let meanAbsoluteError: Double
    public let meanResidual: Double
    public let rSquared: Double?
    public let deviancePerObservation: Double?
    public let devianceExplained: Double?
    public let qqCorrelation: Double?
    public let residualLagOneCorrelation: Double?
    public let largeResidualCount: Int
    public let findings: [DiagnosticFinding]

    /// Assess the retained training observations in a chart model.
    public static func make(from model: ChartModel) -> ModelAssessment? {
        let triples = model.rawY.indices.compactMap { index -> (Double, Double, Double, Double)? in
            guard model.fittedAtTraining.indices.contains(index),
                  model.residuals.indices.contains(index) else { return nil }
            let y = model.rawY[index]
            let fitted = model.fittedAtTraining[index]
            let residual = model.residuals[index]
            guard y.isFinite, fitted.isFinite, residual.isFinite else { return nil }
            return (model.rawX[index], y, fitted, residual)
        }
        guard !triples.isEmpty else { return nil }
        let n = Double(triples.count)
        let rawResiduals = triples.map { $0.1 - $0.2 }
        let rmse = sqrt(rawResiduals.reduce(0) { $0 + $1 * $1 } / n)
        let mae = rawResiduals.reduce(0) { $0 + abs($1) } / n
        let bias = rawResiduals.reduce(0, +) / n
        let large = triples.filter { abs($0.3) > 2 }.count

        let rSquared: Double?
        let deviance: (perObservation: Double, explained: Double)?
        switch model.responseScale {
        case .continuous:
            let mean = triples.reduce(0) { $0 + $1.1 } / n
            let total = triples.reduce(0) { $0 + pow($1.1 - mean, 2) }
            let residual = rawResiduals.reduce(0) { $0 + $1 * $1 }
            rSquared = total > 0 ? 1 - residual / total : nil
            deviance = nil
        case .probability:
            rSquared = nil
            let epsilon = 1e-15
            let fitted = triples.reduce(0.0) { sum, item in
                let mu = min(max(item.2, epsilon), 1 - epsilon)
                return sum - 2 * (item.1 * log(mu) + (1 - item.1) * log(1 - mu))
            }
            let mean = min(max(triples.reduce(0) { $0 + $1.1 } / n, epsilon), 1 - epsilon)
            let null = triples.reduce(0.0) { sum, item in
                sum - 2 * (item.1 * log(mean) + (1 - item.1) * log(1 - mean))
            }
            deviance = (fitted / n, null > 0 ? 1 - fitted / null : 0)
        case .intensity:
            rSquared = nil
            let epsilon = 1e-15
            func poisson(_ y: Double, _ mu: Double) -> Double {
                y == 0 ? 2 * mu : 2 * (y * log(y / max(mu, epsilon)) - (y - mu))
            }
            let fitted = triples.reduce(0.0) { $0 + poisson($1.1, $1.2) }
            let mean = max(triples.reduce(0) { $0 + $1.1 } / n, epsilon)
            let null = triples.reduce(0.0) { $0 + poisson($1.1, mean) }
            deviance = (fitted / n, null > 0 ? 1 - fitted / null : 0)
        }

        let qq = model.responseScale == .continuous ? correlation(model.residualQQ.theoretical,
                                                                    model.residualQQ.observed) : nil
        let lag = lagOneCorrelation(residuals: rawResiduals, x: triples.map(\.0))
        var findings: [DiagnosticFinding] = []
        if large > 0 {
            findings.append(.init(severity: Double(large) / n > 0.05 ? .caution : .information,
                                  code: "large-residuals",
                                  message: "\(large) of \(triples.count) standardized residuals exceed |2|."))
        }
        if let qq, qq < 0.97 {
            findings.append(.init(severity: .caution, code: "non-normal-residuals",
                                  message: "Residual QQ correlation is \(format(qq)); Gaussian intervals may be unreliable."))
        }
        if let lag, abs(lag) > 0.3 {
            findings.append(.init(severity: .caution, code: "residual-autocorrelation",
                                  message: "Lag-one residual correlation is \(format(lag)); structure remains along x."))
        }
        if let explained = deviance?.explained, explained < 0.1 {
            findings.append(.init(severity: .caution, code: "low-deviance-explained",
                                  message: "The fit explains only \(format(100 * explained))% of null deviance."))
        }
        if abs(bias) > 0.1 * max(rmse, 1e-15) {
            findings.append(.init(severity: .caution, code: "residual-bias",
                                  message: "Mean residual is large relative to RMSE."))
        }

        return ModelAssessment(
            responseScale: model.responseScale, observationCount: triples.count,
            rootMeanSquaredError: rmse, meanAbsoluteError: mae, meanResidual: bias,
            rSquared: rSquared, deviancePerObservation: deviance?.perObservation,
            devianceExplained: deviance?.explained, qqCorrelation: qq,
            residualLagOneCorrelation: lag, largeResidualCount: large, findings: findings
        )
    }

    private static func correlation(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count > 2 else { return nil }
        let n = Double(x.count)
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var numerator = 0.0, xx = 0.0, yy = 0.0
        for (a, b) in zip(x, y) {
            numerator += (a - mx) * (b - my)
            xx += pow(a - mx, 2)
            yy += pow(b - my, 2)
        }
        let denominator = sqrt(xx * yy)
        return denominator > 0 ? numerator / denominator : nil
    }

    private static func lagOneCorrelation(residuals: [Double], x: [Double]) -> Double? {
        guard residuals.count == x.count, residuals.count > 3 else { return nil }
        let ordered = residuals.indices.sorted { x[$0] < x[$1] }.map { residuals[$0] }
        return correlation(Array(ordered.dropLast()), Array(ordered.dropFirst()))
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3g", value)
    }
}
