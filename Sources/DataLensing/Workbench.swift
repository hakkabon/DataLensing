// Workbench.swift
// DataLensing
//
// A portable extension seam for statistical workbench tools.  Tools consume
// the public fitted-chart contract, so they can be used by the SwiftUI viewer,
// a command-line host, or another application without importing UI types.

import DataLens
import Foundation

/// Source identity that a workbench may retain or export.
///
/// This deliberately contains a display name and counts only: a workbench
/// session must not expose an absolute local path or a security-scoped URL.
public struct WorkbenchSource: Codable, Sendable, Hashable {
    /// User-visible source name, normally the CSV file name.
    public let displayName: String
    /// Number of observations before missing-value filtering.
    public let inputObservationCount: Int

    public init(displayName: String, inputObservationCount: Int) throws {
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              inputObservationCount >= 0 else {
            throw WorkbenchSessionError.invalidConfiguration
        }
        self.displayName = displayName
        self.inputObservationCount = inputObservationCount
    }
}

/// A fitted chart and its privacy-preserving source context supplied to a tool.
///
/// When present, `sourceRows` is parallel to `loaded.model.rawX` and contains
/// zero-based row positions in the original input. It is optional because a
/// host may intentionally avoid retaining row-level provenance.
public struct WorkbenchInput: Sendable {
    public let loaded: LoadedChart
    public let source: WorkbenchSource
    public let sourceRows: [Int]?
    /// Reproducible statistical settings used for validation of this chart.
    public let validationConfiguration: ValidationConfiguration

    public init(
        loaded: LoadedChart, source: WorkbenchSource, sourceRows: [Int]? = nil,
        validationConfiguration: ValidationConfiguration = ValidationConfiguration()
    ) throws {
        guard source.inputObservationCount >= loaded.model.rawX.count,
              sourceRows == nil || sourceRows?.count == loaded.model.rawX.count else {
            throw WorkbenchSessionError.invalidConfiguration
        }
        self.loaded = loaded
        self.source = source
        self.sourceRows = sourceRows
        self.validationConfiguration = validationConfiguration
    }
}

/// A single scalar or textual result produced by a workbench tool.
public struct WorkbenchMetric: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let value: Double?
    public let text: String?

    /// A numeric metric. Non-finite values are represented by a textual
    /// metric instead, keeping exported JSON valid and portable.
    public init(id: String, label: String, value: Double) {
        self.id = id
        self.label = label
        self.value = value.isFinite ? value : nil
        self.text = value.isFinite ? nil : "Unavailable"
    }

    /// A textual metric such as a response-family label.
    public init(id: String, label: String, text: String) {
        self.id = id
        self.label = label
        self.value = nil
        self.text = text
    }
}

/// A compact rectangular result suitable for a host to render or export.
public struct WorkbenchTable: Codable, Sendable, Hashable {
    public let columns: [String]
    public let rows: [[String]]

    public init(columns: [String], rows: [[String]]) throws {
        guard !columns.isEmpty, rows.allSatisfy({ $0.count == columns.count }) else {
            throw WorkbenchError.invalidOutput("Table rows must match the declared columns.")
        }
        self.columns = columns
        self.rows = rows
    }
}

/// A serializable result returned by one workbench tool.
public struct WorkbenchOutput: Codable, Sendable, Hashable, Identifiable {
    /// The originating tool identifier.
    public let id: String
    public let title: String
    public let summary: String
    public let metrics: [WorkbenchMetric]
    public let table: WorkbenchTable?

    public init(
        id: String, title: String, summary: String,
        metrics: [WorkbenchMetric] = [], table: WorkbenchTable? = nil
    ) throws {
        guard WorkbenchCatalog.isValidIdentifier(id), !title.isEmpty, !summary.isEmpty else {
            throw WorkbenchError.invalidOutput("A workbench result needs an identifier, title, and summary.")
        }
        self.id = id
        self.title = title
        self.summary = summary
        self.metrics = metrics
        self.table = table
    }
}

/// An independently runnable analysis panel in a statistical workbench.
///
/// Tools are intentionally value- and result-oriented. They receive no UI
/// state, file URL, or parser implementation, and can therefore be hosted by
/// DataLensingViewer, another Apple frontend, or a batch process.
public protocol WorkbenchTool: Sendable {
    /// Stable, machine-readable identifier (letters, digits, and hyphens).
    var id: String { get }
    /// User-visible panel title.
    var title: String { get }
    /// One-line explanation used by tool pickers and accessibility labels.
    var detail: String { get }

    /// Produce one portable result for a fitted chart.
    func run(on input: WorkbenchInput) async throws -> WorkbenchOutput
}

/// Errors that a workbench host can present without interpreting tool internals.
public enum WorkbenchError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalidToolIdentifier(String)
    case duplicateToolIdentifier(String)
    case unknownTool(String)
    case invalidOutput(String)

    public var description: String {
        switch self {
        case .invalidToolIdentifier(let id): return "Invalid workbench tool identifier: \(id)"
        case .duplicateToolIdentifier(let id): return "Duplicate workbench tool identifier: \(id)"
        case .unknownTool(let id): return "Unknown workbench tool: \(id)"
        case .invalidOutput(let detail): return "Invalid workbench output: \(detail)"
        }
    }
}

/// A validated, ordered collection of independently supplied workbench tools.
public struct WorkbenchCatalog: Sendable {
    public let tools: [any WorkbenchTool]

    public init(tools: [any WorkbenchTool]) throws {
        var identifiers = Set<String>()
        for tool in tools {
            guard Self.isValidIdentifier(tool.id) else {
                throw WorkbenchError.invalidToolIdentifier(tool.id)
            }
            guard identifiers.insert(tool.id).inserted else {
                throw WorkbenchError.duplicateToolIdentifier(tool.id)
            }
        }
        self.tools = tools
    }

    /// The configured tools in stable execution and display order.
    public var toolIDs: [String] { tools.map(\.id) }

    /// Run one selected tool, retaining its error for the host to display.
    public func run(id: String, on input: WorkbenchInput) async throws -> WorkbenchOutput {
        guard let tool = tools.first(where: { $0.id == id }) else {
            throw WorkbenchError.unknownTool(id)
        }
        try Task.checkCancellation()
        let output = try await tool.run(on: input)
        guard output.id == tool.id else {
            throw WorkbenchError.invalidOutput("Tool '\(tool.id)' returned '\(output.id)'.")
        }
        return output
    }

    /// Run every tool in catalog order. A cancellation or failure stops later
    /// tools, avoiding a partially misleading "complete" workbench view.
    public func runAll(on input: WorkbenchInput) async throws -> [WorkbenchOutput] {
        var outputs: [WorkbenchOutput] = []
        outputs.reserveCapacity(tools.count)
        for tool in tools {
            outputs.append(try await run(id: tool.id, on: input))
        }
        return outputs
    }

    /// Built-in panels offered by DataLensingViewer and available to other hosts.
    public static let builtIns: WorkbenchCatalog = {
        // These literal identifiers are statically known valid and unique.
        try! WorkbenchCatalog(tools: [
            DescriptiveWorkbenchTool(), AssessmentWorkbenchTool(), ValidationWorkbenchTool(),
            ResidualReviewWorkbenchTool(),
        ])
    }()

    fileprivate static func isValidIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }
}

/// Built-in descriptive statistics panel for the fitted predictor and response.
public struct DescriptiveWorkbenchTool: WorkbenchTool {
    public let id = "descriptive-statistics"
    public let title = "Descriptive Statistics"
    public let detail = "Distribution summaries for the retained predictor and response."

    public init() {}

    public func run(on input: WorkbenchInput) async throws -> WorkbenchOutput {
        let model = input.loaded.model
        let x = model.xSummary
        let y = model.ySummary
        return try WorkbenchOutput(
            id: id, title: title,
            summary: "\(x.n) retained observations from \(input.source.displayName).",
            metrics: [
                .init(id: "retained-observations", label: "Retained observations", value: Double(x.n)),
                .init(id: "predictor-mean", label: "\(input.loaded.xName) mean", value: x.mean),
                .init(id: "predictor-standard-deviation", label: "\(input.loaded.xName) standard deviation", value: x.std),
                .init(id: "response-mean", label: "\(input.loaded.yName) mean", value: y.mean),
                .init(id: "response-standard-deviation", label: "\(input.loaded.yName) standard deviation", value: y.std),
            ]
        )
    }
}

/// Built-in family-aware goodness-of-fit and residual-checking panel.
public struct AssessmentWorkbenchTool: WorkbenchTool {
    public let id = "model-assessment"
    public let title = "Model Assessment"
    public let detail = "Training-fit diagnostics appropriate to the response family."

    public init() {}

    public func run(on input: WorkbenchInput) async throws -> WorkbenchOutput {
        guard let assessment = ModelAssessment.make(from: input.loaded.model) else {
            return try WorkbenchOutput(
                id: id, title: title,
                summary: "No finite fitted/residual pairs are available for assessment."
            )
        }
        var metrics: [WorkbenchMetric] = [
            .init(id: "response-scale", label: "Response scale", text: assessment.responseScale.rawValue),
            .init(id: "rmse", label: "RMSE", value: assessment.rootMeanSquaredError),
            .init(id: "mae", label: "MAE", value: assessment.meanAbsoluteError),
            .init(id: "mean-residual", label: "Mean residual", value: assessment.meanResidual),
            .init(id: "large-residuals", label: "Large residuals", value: Double(assessment.largeResidualCount)),
        ]
        if let rSquared = assessment.rSquared {
            metrics.append(.init(id: "r-squared", label: "R²", value: rSquared))
        }
        if let explained = assessment.devianceExplained {
            metrics.append(.init(id: "deviance-explained", label: "Deviance explained", value: explained))
        }
        if let qq = assessment.qqCorrelation {
            metrics.append(.init(id: "qq-correlation", label: "QQ correlation", value: qq))
        }
        let summary = assessment.findings.isEmpty
            ? "No configured diagnostic thresholds were exceeded."
            : assessment.findings.map(\.message).joined(separator: " ")
        return try WorkbenchOutput(id: id, title: title, summary: summary, metrics: metrics)
    }
}

/// Built-in out-of-fold validation of the automatic statistical specification.
///
/// The held-out rows are never used for response-family routing or tuning: the
/// validation engine refits the automatic model in every training fold.
public struct ValidationWorkbenchTool: WorkbenchTool {
    public let id = "cross-validation"
    public let title = "Out-of-Fold Validation"
    public let detail = "Family-aware held-out validation of the configured automatic fit."
    public let maximumRows: Int

    public init(maximumRows: Int = 10) {
        self.maximumRows = max(1, maximumRows)
    }

    public func run(on input: WorkbenchInput) async throws -> WorkbenchOutput {
        let model = input.loaded.model
        guard let validation = CrossValidation.evaluate(
            trainX: model.rawX.map { [$0] }, trainY: model.rawY,
            configuration: input.validationConfiguration
        ) else {
            return try WorkbenchOutput(
                id: id, title: title,
                summary: "Validation could not produce finite held-out fits for this chart."
            )
        }
        let primaryLabel: String
        let primaryValue: Double
        switch validation.responseFamily {
        case .gaussian:
            primaryLabel = "Out-of-fold RMSE"
            primaryValue = validation.rootMeanSquaredError ?? .nan
        case .binomial, .poisson:
            primaryLabel = "Out-of-fold mean deviance"
            primaryValue = validation.meanDeviance ?? .nan
        }
        let rows = validation.predictions
            .sorted { abs($0.observed - $0.predicted) > abs($1.observed - $1.predicted) }
            .prefix(maximumRows)
            .map { prediction in
                let sourceRow = input.sourceRows?[prediction.id] ?? prediction.id
                return [
                    String(sourceRow), String(prediction.fold + 1), format(prediction.observed),
                    format(prediction.predicted), format(prediction.observed - prediction.predicted),
                ]
            }
        let table = try WorkbenchTable(
            columns: ["source_row", "fold", "observed", "held_out_fit", "error"], rows: rows
        )
        return try WorkbenchOutput(
            id: id, title: title,
            summary: "\(validation.configuration.foldCount)-fold \(validation.configuration.partitioning.rawValue) validation over \(validation.retainedObservationCount) retained observations.",
            metrics: [
                .init(id: "response-family", label: "Response family", text: validation.responseFamily.rawValue),
                .init(id: "fold-count", label: "Folds", value: Double(validation.folds.count)),
                .init(id: "primary-score", label: primaryLabel, value: primaryValue),
            ],
            table: table
        )
    }

    private func format(_ value: Double) -> String { String(format: "%.8g", value) }
}

/// Built-in table of the largest finite residuals for quick follow-up.
public struct ResidualReviewWorkbenchTool: WorkbenchTool {
    public let id = "residual-review"
    public let title = "Largest Residuals"
    public let detail = "The retained observations with the largest absolute residuals."
    public let maximumRows: Int

    public init(maximumRows: Int = 10) {
        self.maximumRows = max(1, maximumRows)
    }

    public func run(on input: WorkbenchInput) async throws -> WorkbenchOutput {
        let model = input.loaded.model
        let candidates = model.rawX.indices.compactMap { index -> (Int, Double, Double, Double, Double)? in
            guard model.rawY.indices.contains(index), model.fittedAtTraining.indices.contains(index),
                  model.residuals.indices.contains(index) else { return nil }
            let x = model.rawX[index]
            let observed = model.rawY[index]
            let fitted = model.fittedAtTraining[index]
            let residual = model.residuals[index]
            guard x.isFinite, observed.isFinite, fitted.isFinite, residual.isFinite else { return nil }
            return (index, x, observed, fitted, residual)
        }
        .sorted { abs($0.4) > abs($1.4) }
        let rows = candidates.prefix(maximumRows).map { candidate in
            let sourceRow = input.sourceRows?[candidate.0] ?? candidate.0
            return [
                String(sourceRow), format(candidate.1), format(candidate.2),
                format(candidate.3), format(candidate.4), format(abs(candidate.4)),
            ]
        }
        let table = try WorkbenchTable(
            columns: ["source_row", input.loaded.xName, input.loaded.yName, "fitted", "residual", "abs_residual"],
            rows: rows
        )
        return try WorkbenchOutput(
            id: id, title: title,
            summary: rows.isEmpty ? "No finite residuals are available." : "Top \(rows.count) finite residuals by absolute size.",
            metrics: [.init(id: "reviewed-residuals", label: "Reviewed residuals", value: Double(rows.count))],
            table: table
        )
    }

    private func format(_ value: Double) -> String { String(format: "%.8g", value) }
}

/// Codable mirror of `TuningBudget` used in saved workbench sessions.
///
/// `TuningBudget` intentionally stays lightweight and non-Codable; this
/// explicit mirror makes persistence a conscious public contract instead.
public struct WorkbenchTuning: Codable, Sendable, Hashable {
    public let degree: Int
    public let spans: [Double]?
    public let robustIterations: Int
    public let gridCount: Int
    public let fastAdaptivePrediction: Bool
    public let adaptiveContender: Bool
    public let smoothingPenalty: Double?

    public init(_ budget: TuningBudget) {
        degree = budget.degree
        spans = budget.spans
        robustIterations = budget.robustIterations
        gridCount = budget.gridCount
        fastAdaptivePrediction = budget.fastAdaptivePrediction
        adaptiveContender = budget.adaptiveContender
        smoothingPenalty = budget.smoothingPenalty
    }

    /// Restores a validated runtime budget from a decoded session.
    public var tuningBudget: TuningBudget {
        TuningBudget(
            degree: degree, spans: spans, robustIterations: robustIterations,
            gridCount: gridCount, fastAdaptivePrediction: fastAdaptivePrediction,
            adaptiveContender: adaptiveContender, smoothingPenalty: smoothingPenalty
        )
    }

    fileprivate var isValid: Bool {
        (0...2).contains(degree)
            && (spans == nil || (!(spans?.isEmpty ?? true) && spans!.allSatisfy { $0.isFinite && $0 > 0 }))
            && robustIterations >= 0 && gridCount > 0
            && (smoothingPenalty == nil || (smoothingPenalty!.isFinite && smoothingPenalty! >= 0))
    }
}

/// Errors for decoding or creating a replayable workbench session.
public enum WorkbenchSessionError: Error, Sendable, Hashable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case invalidConfiguration

    public var description: String {
        switch self {
        case .unsupportedSchema(let version): return "Unsupported workbench session schema: \(version)"
        case .invalidConfiguration: return "Invalid workbench session configuration."
        }
    }
}

/// Versioned, JSON-serializable user choices for replaying a workbench fit.
///
/// A session records configuration, not source data. Loading it must therefore
/// be followed by the host asking the user to select the intended input file.
public struct WorkbenchSession: Codable, Sendable, Hashable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let source: WorkbenchSource
    public let predictor: String
    public let response: String
    public let secondPredictor: String?
    public let smoother: String
    public let tuning: WorkbenchTuning
    /// Fold assignment and automatic-model configuration for validation.
    public let validationConfiguration: ValidationConfiguration
    public let activePlanesRawValue: Int
    public let enabledToolIDs: [String]

    /// The validated smoother selection, ready to hand to `loadController`.
    public var smootherChoice: SmootherChoice {
        // `validate()` admits only values from this enum before a session is exposed.
        SmootherChoice(rawValue: smoother)!
    }

    public init(
        source: WorkbenchSource, predictor: String, response: String,
        secondPredictor: String? = nil, smoother: SmootherChoice,
        budget: TuningBudget, activePlanesRawValue: Int, enabledToolIDs: [String],
        validationConfiguration: ValidationConfiguration? = nil
    ) throws {
        self.schemaVersion = Self.currentSchemaVersion
        self.source = source
        self.predictor = predictor
        self.response = response
        self.secondPredictor = secondPredictor
        self.smoother = smoother.rawValue
        self.tuning = WorkbenchTuning(budget)
        self.validationConfiguration = validationConfiguration
            ?? Self.defaultValidationConfiguration(for: budget)
        self.activePlanesRawValue = activePlanesRawValue
        self.enabledToolIDs = enabledToolIDs
        try validate()
    }

    /// Stable, readable JSON for copy/paste or a workspace sidecar.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decode and validate a session before a host uses any of its values.
    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: jsonData)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, source, predictor, response, secondPredictor, smoother, tuning
        case validationConfiguration
        case activePlanesRawValue, enabledToolIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        source = try values.decode(WorkbenchSource.self, forKey: .source)
        predictor = try values.decode(String.self, forKey: .predictor)
        response = try values.decode(String.self, forKey: .response)
        secondPredictor = try values.decodeIfPresent(String.self, forKey: .secondPredictor)
        smoother = try values.decode(String.self, forKey: .smoother)
        tuning = try values.decode(WorkbenchTuning.self, forKey: .tuning)
        validationConfiguration = try values.decodeIfPresent(
            ValidationConfiguration.self, forKey: .validationConfiguration
        ) ?? Self.defaultValidationConfiguration(for: tuning.tuningBudget)
        activePlanesRawValue = try values.decode(Int.self, forKey: .activePlanesRawValue)
        enabledToolIDs = try values.decode([String].self, forKey: .enabledToolIDs)
        try validate()
    }

    private func validate() throws {
        guard schemaVersion == 1 || schemaVersion == Self.currentSchemaVersion else {
            throw WorkbenchSessionError.unsupportedSchema(schemaVersion)
        }
        guard !predictor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.inputObservationCount >= 0,
              SmootherChoice(rawValue: smoother) != nil,
              tuning.isValid,
              activePlanesRawValue >= 0,
              enabledToolIDs.allSatisfy(WorkbenchCatalog.isValidIdentifier),
              Set(enabledToolIDs).count == enabledToolIDs.count else {
            throw WorkbenchSessionError.invalidConfiguration
        }
    }

    private static func defaultValidationConfiguration(for budget: TuningBudget) -> ValidationConfiguration {
        ValidationConfiguration(
            specification: StatisticalModelSpecification(
                degree: budget.degree, spans: budget.spans,
                robustIterations: budget.robustIterations,
                adaptiveContender: budget.adaptiveContender
            )
        )
    }
}
