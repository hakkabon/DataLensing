import DataLens
import DataTables
import Foundation

/// The result of explicitly replaying a one-dimensional document model.
///
/// It keeps the fitted chart, its controller, and original CSV-row provenance
/// together so a host cannot accidentally run diagnostics against a different
/// row ordering than the displayed figure.
public struct AnalysisDocumentFit: Sendable {
    public let modelBlockID: UUID
    public let controller: FitController
    public let loaded: LoadedChart
    /// Zero-based rows in the original CSV, parallel to `loaded.model.rawX`.
    public let sourceRows: [Int]
    /// Zero-based CSV rows entering the fit after deterministic scale selection.
    /// This lets a host retain correct provenance through later windowed fits.
    public let trainingSourceRows: [Int]
    /// Observed input, eligible, and selected counts for this fit.
    public let scaleSelection: StatisticalScaleSelection
    public let columns: [ColumnInfo]
    public let transformedObservationCount: Int

    public init(
        modelBlockID: UUID, controller: FitController, loaded: LoadedChart,
        sourceRows: [Int], trainingSourceRows: [Int], columns: [ColumnInfo],
        transformedObservationCount: Int, scaleSelection: StatisticalScaleSelection
    ) {
        self.modelBlockID = modelBlockID
        self.controller = controller
        self.loaded = loaded
        self.sourceRows = sourceRows
        self.trainingSourceRows = trainingSourceRows
        self.columns = columns
        self.transformedObservationCount = transformedObservationCount
        self.scaleSelection = scaleSelection
    }
}

/// A fitted unified GAM or multivariate model replayed from an analysis document.
public struct AdvancedAnalysisDocumentFit: Sendable {
    public let modelBlockID: UUID
    public let recipe: AnalysisDocument.AdvancedModelRecipe
    public let model: FittedStatisticalModel
    /// Original CSV rows, parallel to the model's retained training rows.
    public let sourceRows: [Int]
    /// Original CSV rows entering the fit after deterministic scale selection.
    public let trainingSourceRows: [Int]
    /// Observed input, eligible, and selected counts for this fit.
    public let scaleSelection: StatisticalScaleSelection
    /// The actual accepted multivariate solver, never inferred from preference.
    public let solverBackend: MultivariateSolverBackend?
    /// The saved numerical policy requested for a multivariate fit.
    public let requestedSolverPreference: MultivariateSolverPreference?
    /// CGLS dimensions, convergence, and residual retained only when native
    /// sparse execution supplied the accepted final update.
    public let sparseExecution: SparseExecutionEvidence?

    public init(
        modelBlockID: UUID, recipe: AnalysisDocument.AdvancedModelRecipe,
        model: FittedStatisticalModel, sourceRows: [Int], trainingSourceRows: [Int],
        solverBackend: MultivariateSolverBackend?,
        requestedSolverPreference: MultivariateSolverPreference?,
        sparseExecution: SparseExecutionEvidence?, scaleSelection: StatisticalScaleSelection
    ) {
        self.modelBlockID = modelBlockID
        self.recipe = recipe
        self.model = model
        self.sourceRows = sourceRows
        self.trainingSourceRows = trainingSourceRows
        self.solverBackend = solverBackend
        self.requestedSolverPreference = requestedSolverPreference
        self.sparseExecution = sparseExecution
        self.scaleSelection = scaleSelection
    }
}

/// Executes the saved, declarative portion of an analysis document.
///
/// This is deliberately separate from a SwiftUI host. Replaying and fitting
/// here gives macOS, iPadOS, batch tools, and future document hosts identical
/// source-fingerprint and row-provenance semantics.
public enum AnalysisDocumentExecutor {
    /// Replay transformation ancestors and fit the selected one-dimensional
    /// model. Two-dimensional recipes remain a host capability until their
    /// surface workflow has an equally portable evidence contract.
    public static func fit(
        document: AnalysisDocument, sourceURL: URL, modelBlockID: UUID
    ) async throws -> AnalysisDocumentFit {
        guard let block = document.blocks.first(where: { $0.id == modelBlockID }),
              case .model(let recipe) = block.payload else {
            throw AnalysisDocumentExecutionError.unknownModelBlock(modelBlockID)
        }
        guard recipe.secondPredictor == nil else {
            throw AnalysisDocumentExecutionError.multivariateModelUnsupported
        }
        guard let smoother = recipe.smootherChoice else {
            throw AnalysisDocumentExecutionError.invalidModelRecipe
        }

        let replay = try AnalysisTransformationExecutor.replay(
            document: document, sourceURL: sourceURL, through: modelBlockID
        )
        guard let xs = replay.table.numericValues(forColumn: recipe.predictor) else {
            throw AnalysisDocumentExecutionError.missingNumericColumn(recipe.predictor)
        }
        guard let ys = replay.table.numericValues(forColumn: recipe.response) else {
            throw AnalysisDocumentExecutionError.missingNumericColumn(recipe.response)
        }
        try Task.checkCancellation()
        let predictors = xs.map { [$0] }
        let selection = try recipe.effectiveScalePolicy.select(
            predictors: predictors, response: ys
        )
        let selectedPredictors = selection.selectedIndices.map { predictors[$0] }
        let selectedResponse = selection.selectedIndices.map { ys[$0] }
        let selectedSourceRows = try selection.selectedIndices.map { index -> Int in
            guard replay.table.sourceRowIndices.indices.contains(index) else {
                throw AnalysisDocumentExecutionError.invalidProvenance
            }
            return replay.table.sourceRowIndices[index]
        }
        var controller = FitController(
            trainX: selectedPredictors, trainY: selectedResponse, xName: recipe.predictor,
            yName: recipe.response, budget: recipe.tuning.tuningBudget, smoother: smoother
        )
        let loaded = try await controller.fitConcurrently()
        try Task.checkCancellation()
        let sourceRows = try loaded.keptIndices.map { index -> Int in
            guard selectedSourceRows.indices.contains(index) else {
                throw AnalysisDocumentExecutionError.invalidProvenance
            }
            return selectedSourceRows[index]
        }
        let columns = replay.table.columns.map { column in
            let isNumeric: Bool
            switch column {
            case .numeric: isNumeric = true
            case .text: isNumeric = false
            }
            let isDate = document.source.columns.first(where: { $0.name == column.name })?.kind == .date
            return ColumnInfo(name: column.name, isNumeric: isNumeric, isDate: isDate)
        }
        return AnalysisDocumentFit(
            modelBlockID: modelBlockID, controller: controller, loaded: loaded,
            sourceRows: sourceRows, trainingSourceRows: selectedSourceRows, columns: columns,
            transformedObservationCount: replay.table.rowCount, scaleSelection: selection
        )
    }

    /// Replay and fit a saved unified GAM or multivariate specification.
    ///
    /// The multivariate path is intentionally fitted directly here so the
    /// accepted sparse/dense backend is retained as provenance instead of being
    /// hidden behind the unified model wrapper.
    public static func fitAdvanced(
        document: AnalysisDocument, sourceURL: URL, modelBlockID: UUID
    ) throws -> AdvancedAnalysisDocumentFit {
        guard let block = document.blocks.first(where: { $0.id == modelBlockID }),
              case .advancedModel(let recipe) = block.payload else {
            throw AnalysisDocumentExecutionError.unknownAdvancedModelBlock(modelBlockID)
        }
        let replay = try AnalysisTransformationExecutor.replay(
            document: document, sourceURL: sourceURL, through: modelBlockID
        )
        let predictorColumns = try recipe.predictorColumns.map { name -> [Double] in
            guard let values = replay.table.numericValues(forColumn: name) else {
                throw AnalysisDocumentExecutionError.missingNumericColumn(name)
            }
            return values
        }
        guard let response = replay.table.numericValues(forColumn: recipe.responseColumn) else {
            throw AnalysisDocumentExecutionError.missingNumericColumn(recipe.responseColumn)
        }
        guard predictorColumns.allSatisfy({ $0.count == response.count }) else {
            throw AnalysisDocumentExecutionError.invalidProvenance
        }
        let predictors = response.indices.map { row in predictorColumns.map { $0[row] } }
        let selection = try recipe.effectiveScalePolicy.select(
            predictors: predictors, response: response
        )
        let selectedPredictors = selection.selectedIndices.map { predictors[$0] }
        let selectedResponse = selection.selectedIndices.map { response[$0] }
        let selectedSourceRows = try selection.selectedIndices.map { index -> Int in
            guard replay.table.sourceRowIndices.indices.contains(index) else {
                throw AnalysisDocumentExecutionError.invalidProvenance
            }
            return replay.table.sourceRowIndices[index]
        }

        let fitted: FittedStatisticalModel
        let solverBackend: MultivariateSolverBackend?
        let requestedSolverPreference: MultivariateSolverPreference?
        let sparseExecution: SparseExecutionEvidence?
        switch recipe.specification.strategy {
        case .multivariateGaussian, .multivariateBinomial, .multivariatePoisson:
            let family: MultivariateResponseFamily
            switch recipe.specification.strategy {
            case .multivariateGaussian: family = .gaussian
            case .multivariateBinomial: family = .binomial
            case .multivariatePoisson: family = .poisson
            default: preconditionFailure("Covered by the enclosing switch")
            }
            guard let multivariate = MultivariateModel.fit(
                trainX: selectedPredictors, trainY: selectedResponse, family: family,
                specification: recipe.specification.multivariate ?? MultivariateModelSpecification(),
                droppingMissing: true
            ).model else {
                throw AnalysisDocumentExecutionError.fitFailed
            }
            fitted = FittedStatisticalModel(
                multivariate: multivariate, specification: recipe.specification
            )
            solverBackend = multivariate.solverBackend
            requestedSolverPreference = recipe.specification.multivariate?.solverPreference ?? .automatic
            sparseExecution = multivariate.sparseExecution
        default:
            guard let model = FittedStatisticalModel.fit(
                trainX: selectedPredictors, trainY: selectedResponse, specification: recipe.specification
            ) else {
                throw AnalysisDocumentExecutionError.fitFailed
            }
            fitted = model
            solverBackend = nil
            requestedSolverPreference = nil
            sparseExecution = nil
        }
        let sourceRows = try fitted.keptIndices.map { index -> Int in
            guard selectedSourceRows.indices.contains(index) else {
                throw AnalysisDocumentExecutionError.invalidProvenance
            }
            return selectedSourceRows[index]
        }
        return AdvancedAnalysisDocumentFit(
            modelBlockID: modelBlockID, recipe: recipe, model: fitted,
            sourceRows: sourceRows, trainingSourceRows: selectedSourceRows,
            solverBackend: solverBackend,
            requestedSolverPreference: requestedSolverPreference,
            sparseExecution: sparseExecution, scaleSelection: selection
        )
    }

    /// Start a document from a chart that the user has already deliberately
    /// fitted. The initial evidence makes that existing result auditable; later
    /// changes are always represented as new blocks or explicit recomputations.
    public static func createDocument(
        title: String, sourceURL: URL, loaded: LoadedChart, sourceRows: [Int]? = nil,
        model: AnalysisDocument.ModelRecipe, figure: AnalysisDocument.FigureAnnotation,
        createdAt: Date = Date()
    ) throws -> AnalysisDocument {
        let table = try CSVTable.load(contentsOf: sourceURL)
        let source = try AnalysisDocument.Source.make(from: sourceURL, table: table)
        let modelBlock = try AnalysisDocument.Block(
            title: "Model: \(model.predictor) → \(model.response)", payload: .model(model),
            createdAt: createdAt, updatedAt: createdAt
        )
        let figureBlock = try AnalysisDocument.Block(
            title: "Figure: \(figure.kind.rawValue)", upstreamBlockIDs: [modelBlock.id],
            payload: .figure(figure), createdAt: createdAt, updatedAt: createdAt
        )
        let report = AnalysisReport.make(
            from: loaded, sourceURL: sourceURL, inputObservationCount: source.inputObservationCount,
            sourceRows: sourceRows, createdAt: createdAt
        )
        let evidenceBlock = try AnalysisDocument.Block(
            title: "Initial fitted evidence", upstreamBlockIDs: [modelBlock.id],
            payload: .evidence(try AnalysisDocument.EvidenceSnapshot(
                capturedAt: createdAt, sourceFingerprint: source.fingerprint,
                report: report, workbenchOutputs: []
            )), createdAt: createdAt, updatedAt: createdAt
        )
        return try AnalysisDocument(
            title: title, source: source, blocks: [modelBlock, figureBlock, evidenceBlock],
            createdAt: createdAt, updatedAt: createdAt
        )
    }

    /// Build immutable fitted/validation evidence for an explicit run.
    public static func evidenceSnapshot(
        document: AnalysisDocument, fit: AnalysisDocumentFit, sourceURL: URL,
        workbenchOutputs: [WorkbenchOutput], capturedAt: Date = Date()
    ) throws -> AnalysisDocument.EvidenceSnapshot {
        let report = AnalysisReport.make(
            from: fit.loaded, sourceURL: sourceURL,
            inputObservationCount: document.source.inputObservationCount,
            sourceRows: fit.sourceRows, createdAt: capturedAt
        )
        return try AnalysisDocument.EvidenceSnapshot(
            capturedAt: capturedAt, sourceFingerprint: document.source.fingerprint,
            report: report, workbenchOutputs: workbenchOutputs
        )
    }

    /// Evaluate held-out calibration and optional deterministic bootstrap
    /// stability using the exact advanced recipe retained by the document.
    public static func advancedEvidenceSnapshot(
        document: AnalysisDocument, fit: AdvancedAnalysisDocumentFit,
        capturedAt: Date = Date()
    ) throws -> AnalysisDocument.AdvancedModelEvidence {
        // `ModelValidation` keeps its own retained-row ordering. The parallel
        // `fit.sourceRows` remains the document's original-CSV provenance map.
        let validation = CrossValidation.evaluate(
            trainX: fit.model.trainingPredictors, trainY: fit.model.trainingResponses,
            configuration: fit.recipe.validationConfiguration
        )
        let calibration = validation?.binomialCalibration()
        let bootstrap = fit.recipe.bootstrapConfiguration.map { configuration in
            ModelResampling.bootstrap(
                trainX: fit.model.trainingPredictors, trainY: fit.model.trainingResponses,
                queryPoints: fit.recipe.stabilityQueries, configuration: configuration
            )
        }
        return try AnalysisDocument.AdvancedModelEvidence(
            capturedAt: capturedAt, sourceFingerprint: document.source.fingerprint,
            modelKind: fit.model.kind, diagnostics: fit.model.diagnostics,
            requestedSolverPreference: fit.requestedSolverPreference,
            solverBackend: fit.solverBackend, sparseExecution: fit.sparseExecution,
            validation: validation,
            calibration: calibration, bootstrap: bootstrap
        )
    }

    /// Statistical tools consume exactly the rows used by the document fit.
    public static func workbenchInput(
        document: AnalysisDocument, fit: AnalysisDocumentFit
    ) throws -> WorkbenchInput {
        try WorkbenchInput(
            loaded: fit.loaded,
            source: WorkbenchSource(
                displayName: document.source.displayName,
                inputObservationCount: document.source.inputObservationCount
            ),
            sourceRows: fit.sourceRows,
            validationConfiguration: modelRecipe(in: document, blockID: fit.modelBlockID)
                .validationConfiguration
        )
    }

    private static func modelRecipe(
        in document: AnalysisDocument, blockID: UUID
    ) -> AnalysisDocument.ModelRecipe {
        // `fit` admits this exact model block before exposing an
        // `AnalysisDocumentFit`; a fallback is therefore unreachable.
        guard let block = document.blocks.first(where: { $0.id == blockID }),
              case .model(let recipe) = block.payload else {
            preconditionFailure("AnalysisDocumentFit must name a document model block")
        }
        return recipe
    }

}

/// Errors a host can present without treating saved document content as code.
public enum AnalysisDocumentExecutionError: Error, Sendable, Hashable, CustomStringConvertible {
    case unknownModelBlock(UUID)
    case unknownAdvancedModelBlock(UUID)
    case invalidModelRecipe
    case multivariateModelUnsupported
    case missingNumericColumn(String)
    case fitFailed
    case invalidProvenance

    public var description: String {
        switch self {
        case .unknownModelBlock(let id): return "Unknown document model block \(id.uuidString)."
        case .unknownAdvancedModelBlock(let id):
            return "Unknown advanced document model block \(id.uuidString)."
        case .invalidModelRecipe: return "The saved model recipe is not supported."
        case .multivariateModelUnsupported:
            return "Document recomputation currently supports one predictor."
        case .missingNumericColumn(let name):
            return "The saved model requires numeric column '\(name)'."
        case .fitFailed: return "The saved advanced model did not produce a converged fit."
        case .invalidProvenance: return "The replayed model returned invalid row provenance."
        }
    }
}
