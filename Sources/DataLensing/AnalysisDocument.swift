import DataLens
import DataTables
import Foundation

/// A portable, inspectable lab notebook for one numerical-statistics analysis.
///
/// An analysis document stores a source identity, ordered transformation/model/
/// evidence blocks, and dependency-based freshness. It deliberately stores no
/// absolute path or source bytes: hosts choose whether to retain an original
/// file separately. Blocks are structured statistical operations, not arbitrary
/// executable code, so the same document can be inspected and replayed on
/// macOS and iPadOS.
public struct AnalysisDocument: Codable, Sendable, Hashable, Identifiable {
    public static let currentSchemaVersion = 10

    public let id: UUID
    public let schemaVersion: Int
    public private(set) var title: String
    public private(set) var source: Source
    public let createdAt: Date
    public private(set) var updatedAt: Date
    /// Blocks appear in dependency order; an input can only name an earlier block.
    public private(set) var blocks: [Block]
    /// A review-oriented ordering of existing blocks. Composition never
    /// changes execution dependencies or freshness.
    public private(set) var composition: NotebookComposition
    /// Portable review state for file sharing and version-controlled handoff.
    /// It records comments and explicit readiness without claiming live identity,
    /// synchronization, or external approval.
    public private(set) var review: DocumentReview

    public init(
        id: UUID = UUID(), title: String, source: Source, blocks: [Block] = [],
        composition: NotebookComposition = NotebookComposition(),
        review: DocumentReview = DocumentReview(),
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) throws {
        self.id = id
        schemaVersion = Self.currentSchemaVersion
        self.title = title
        self.source = source
        self.blocks = blocks
        self.composition = composition
        self.review = review
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        try validate()
    }

    /// A privacy-preserving identity for source data selected by the host.
    public struct Source: Codable, Sendable, Hashable {
        public let displayName: String
        public let inputObservationCount: Int
        public let columns: [Column]
        /// Streaming FNV-1a fingerprint for change detection, not cryptographic security.
        public let fingerprint: String
        public let byteCount: Int64

        public init(
            displayName: String, inputObservationCount: Int, columns: [Column],
            fingerprint: String, byteCount: Int64
        ) throws {
            guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  inputObservationCount >= 0, byteCount >= 0,
                  !fingerprint.isEmpty, Set(columns.map(\.name)).count == columns.count,
                  columns.allSatisfy(\.isValid) else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            self.displayName = displayName
            self.inputObservationCount = inputObservationCount
            self.columns = columns
            self.fingerprint = fingerprint
            self.byteCount = byteCount
        }

        fileprivate var isValid: Bool {
            !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && inputObservationCount >= 0 && byteCount >= 0 && !fingerprint.isEmpty
                && Set(columns.map(\.name)).count == columns.count && columns.allSatisfy(\.isValid)
        }

        /// Create an identity without persisting `url` or its enclosing path.
        public static func make(from url: URL, table: CSVTable) throws -> Source {
            let fingerprint = try sourceFingerprint(at: url)
            let columns = table.columns.map { column in
                Column(name: column.name, kind: Column.Kind(column.inferredType))
            }
            return try Source(
                displayName: url.lastPathComponent, inputObservationCount: table.rowCount,
                columns: columns, fingerprint: fingerprint.value, byteCount: fingerprint.byteCount
            )
        }
    }

    /// A source column's persisted name and inferred import type.
    public struct Column: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable, Hashable {
            case integer, double, date, string

            fileprivate init(_ type: ColumnType) {
                switch type {
                case .integer: self = .integer
                case .double: self = .double
                case .date: self = .date
                case .string: self = .string
                }
            }
        }

        public let name: String
        public let kind: Kind

        public init(name: String, kind: Kind) {
            self.name = name
            self.kind = kind
        }

        fileprivate var isValid: Bool {
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// A persisted, declarative transformation. Execution is intentionally a
    /// later host capability; recording it now prevents a visual operation from
    /// becoming undocumented state.
    public enum Transformation: Codable, Sendable, Hashable {
        /// Retain this ordered subset of source columns.
        case selectColumns([String])
        /// Exclude rows missing any named source column.
        case dropMissing(columns: [String])
        /// Keep rows whose finite numeric value meets a scalar predicate.
        case filterNumeric(column: String, comparison: NumericComparison, value: Double)
        /// Save a derived natural-log column; non-positive values are excluded by the executor.
        case naturalLog(source: String, destination: String)
    }

    public enum NumericComparison: String, Codable, Sendable, Hashable {
        case lessThan
        case lessThanOrEqual
        case equal
        case greaterThanOrEqual
        case greaterThan
    }

    /// A reusable, declarative validation policy for one or more model blocks.
    ///
    /// The plan carries only the choices that should remain comparable across
    /// models: fold construction, deterministic seed, optional bootstrap
    /// policy, and an optional comparison cohort. A model recipe stores the
    /// plan's *resolved* configuration with its exact statistical
    /// specification, so a replay does not depend on mutable notebook state.
    public struct ValidationPlan: Codable, Sendable, Hashable {
        public enum IntendedUse: String, Codable, Sendable, Hashable {
            /// Independently exchangeable observations use shuffled folds.
            case exchangeable
            /// Ordered source rows use contiguous blocked folds, for example
            /// after an explicit temporal or spatial ordering transformation.
            case orderedOrSpatial
            /// Binary outcomes use stratified folds to preserve both classes.
            case binaryClassification
        }

        /// Optional deterministic bootstrap policy for stability evidence.
        public struct BootstrapPolicy: Codable, Sendable, Hashable {
            public let replicateCount: Int
            public let minimumSuccessFraction: Double
            public let confidenceLevel: Double
            public let seed: UInt64

            public init(
                replicateCount: Int = 50, minimumSuccessFraction: Double = 0.8,
                confidenceLevel: Double = 0.95, seed: UInt64 = 0
            ) throws {
                guard replicateCount >= 2,
                      (0...1).contains(minimumSuccessFraction),
                      confidenceLevel > 0, confidenceLevel < 1 else {
                    throw AnalysisDocumentError.invalidConfiguration
                }
                self.replicateCount = replicateCount
                self.minimumSuccessFraction = minimumSuccessFraction
                self.confidenceLevel = confidenceLevel
                self.seed = seed
            }

            fileprivate var isValid: Bool {
                replicateCount >= 2 && (0...1).contains(minimumSuccessFraction)
                    && confidenceLevel > 0 && confidenceLevel < 1
            }

            fileprivate func configuration(
                for specification: StatisticalModelSpecification
            ) -> BootstrapConfiguration {
                BootstrapConfiguration(
                    replicateCount: replicateCount,
                    minimumSuccessFraction: minimumSuccessFraction,
                    confidenceLevel: confidenceLevel, seed: seed,
                    specification: specification
                )
            }
        }

        public let intendedUse: IntendedUse
        public let foldCount: Int
        public let partitioning: ValidationPartitioning
        public let seed: UInt64
        public let bootstrap: BootstrapPolicy?
        /// A human-chosen label for models deliberately assessed on the same
        /// folds. It is provenance, not a claim that a comparison is valid.
        public let comparisonCohort: String?

        public init(
            intendedUse: IntendedUse, foldCount: Int = 5,
            partitioning: ValidationPartitioning, seed: UInt64 = 0,
            bootstrap: BootstrapPolicy? = nil, comparisonCohort: String? = nil
        ) throws {
            let normalizedCohort = comparisonCohort?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard foldCount >= 2, Self.accepts(partitioning, for: intendedUse),
                  normalizedCohort?.isEmpty != true else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            self.intendedUse = intendedUse
            self.foldCount = foldCount
            self.partitioning = partitioning
            self.seed = seed
            self.bootstrap = bootstrap
            self.comparisonCohort = normalizedCohort
        }

        /// Resolve the reusable policy for the exact model being fitted.
        public func validationConfiguration(
            for specification: StatisticalModelSpecification
        ) -> ValidationConfiguration {
            ValidationConfiguration(
                foldCount: foldCount, partitioning: partitioning, seed: seed,
                specification: specification
            )
        }

        /// Resolve a stability policy for the exact model being fitted.
        public func bootstrapConfiguration(
            for specification: StatisticalModelSpecification
        ) -> BootstrapConfiguration? {
            bootstrap?.configuration(for: specification)
        }

        /// Plans are comparable only when explicitly placed in one cohort and
        /// use the same partition construction and seed.
        public func isComparable(to other: ValidationPlan) -> Bool {
            comparisonCohort != nil && comparisonCohort == other.comparisonCohort
                && foldCount == other.foldCount && partitioning == other.partitioning
                && seed == other.seed
        }

        /// Binary-stratified plans may only validate binomial specifications.
        /// Other plan intents constrain fold construction, not model family.
        public func supports(_ specification: StatisticalModelSpecification) -> Bool {
            guard intendedUse == .binaryClassification else { return true }
            switch specification.strategy {
            case .additiveBinomial, .multivariateBinomial: return true
            default: return false
            }
        }

        fileprivate var isValid: Bool {
            foldCount >= 2 && Self.accepts(partitioning, for: intendedUse)
                && bootstrap?.isValid != false
                && comparisonCohort?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
        }

        private static func accepts(
            _ partitioning: ValidationPartitioning, for intendedUse: IntendedUse
        ) -> Bool {
            switch intendedUse {
            case .exchangeable: return partitioning == .shuffled
            case .orderedOrSpatial: return partitioning == .blocked
            case .binaryClassification: return partitioning == .stratifiedBinary
            }
        }
    }

    /// A persisted chart-model recipe derived from a replayable workbench session.
    public struct ModelRecipe: Codable, Sendable, Hashable {
        public let predictor: String
        public let response: String
        public let secondPredictor: String?
        /// Raw value retained for forward-compatible decoding and validation.
        public let smoother: String
        public let tuning: WorkbenchTuning
        public let validationConfiguration: ValidationConfiguration
        /// Explicit full-data or bounded-fit policy. `nil` decodes legacy
        /// documents and is interpreted as `.fullData`.
        public let scalePolicy: StatisticalScalePolicy?
        /// The first-class plan from which this exact configuration was resolved.
        public let validationPlanBlockID: UUID?

        public init(
            predictor: String, response: String, secondPredictor: String? = nil,
            smoother: SmootherChoice, tuning: WorkbenchTuning,
            validationConfiguration: ValidationConfiguration,
            scalePolicy: StatisticalScalePolicy = .fullData,
            validationPlanBlockID: UUID? = nil
        ) throws {
            guard Self.isValidColumnName(predictor), Self.isValidColumnName(response),
                  predictor != response,
                  secondPredictor.map(Self.isValidColumnName) ?? true,
                  secondPredictor != predictor, secondPredictor != response,
                  tuning.isValid, scalePolicy.isValid else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            self.predictor = predictor
            self.response = response
            self.secondPredictor = secondPredictor
            self.smoother = smoother.rawValue
            self.tuning = tuning
            self.validationConfiguration = validationConfiguration
            self.scalePolicy = scalePolicy
            self.validationPlanBlockID = validationPlanBlockID
        }

        public init(session: WorkbenchSession) throws {
            try self.init(
                predictor: session.predictor, response: session.response,
                secondPredictor: session.secondPredictor, smoother: session.smootherChoice,
                tuning: session.tuning, validationConfiguration: session.validationConfiguration
            )
        }

        public var smootherChoice: SmootherChoice? { SmootherChoice(rawValue: smoother) }
        public var effectiveScalePolicy: StatisticalScalePolicy { scalePolicy ?? .fullData }

        fileprivate var isValid: Bool {
            Self.isValidColumnName(predictor) && Self.isValidColumnName(response)
                && predictor != response && secondPredictor.map(Self.isValidColumnName) != false
                && secondPredictor != predictor && secondPredictor != response
                && smootherChoice != nil && tuning.isValid && (scalePolicy?.isValid ?? true)
        }

        private static func isValidColumnName(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// A replayable unified model recipe for GAMs and multivariate models.
    ///
    /// Column names belong to the document rather than a view, while the
    /// `StatisticalModelSpecification` retains family, terms, penalties, and
    /// numerical-solver preference. Validation and bootstrap configurations
    /// repeat that specification so an evidence run cannot silently validate a
    /// different statistical model.
    public struct AdvancedModelRecipe: Codable, Sendable, Hashable {
        public let predictorColumns: [String]
        public let responseColumn: String
        public let specification: StatisticalModelSpecification
        public let validationConfiguration: ValidationConfiguration
        /// Explicit full-data or bounded-fit policy. `nil` decodes legacy
        /// documents and is interpreted as `.fullData`.
        public let scalePolicy: StatisticalScalePolicy?
        /// The first-class plan from which validation/bootstrap policy was resolved.
        public let validationPlanBlockID: UUID?
        /// `nil` means stability resampling was intentionally not requested.
        public let bootstrapConfiguration: BootstrapConfiguration?
        /// Prediction rows for bootstrap stability intervals, in predictor order.
        public let stabilityQueries: [[Double]]

        public init(
            predictorColumns: [String], responseColumn: String,
            specification: StatisticalModelSpecification,
            validationConfiguration: ValidationConfiguration,
            scalePolicy: StatisticalScalePolicy = .fullData,
            bootstrapConfiguration: BootstrapConfiguration? = nil,
            stabilityQueries: [[Double]] = [], validationPlanBlockID: UUID? = nil
        ) throws {
            guard !predictorColumns.isEmpty,
                  Set(predictorColumns).count == predictorColumns.count,
                  predictorColumns.allSatisfy(Self.isValidColumnName),
                  Self.isValidColumnName(responseColumn),
                  !predictorColumns.contains(responseColumn),
                  validationConfiguration.specification == specification,
                  scalePolicy.isValid,
                  bootstrapConfiguration?.specification == specification || bootstrapConfiguration == nil,
                  stabilityQueries.allSatisfy({
                      $0.count == predictorColumns.count && $0.allSatisfy(\.isFinite)
                  }),
                  bootstrapConfiguration == nil || !stabilityQueries.isEmpty else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            self.predictorColumns = predictorColumns
            self.responseColumn = responseColumn
            self.specification = specification
            self.validationConfiguration = validationConfiguration
            self.scalePolicy = scalePolicy
            self.validationPlanBlockID = validationPlanBlockID
            self.bootstrapConfiguration = bootstrapConfiguration
            self.stabilityQueries = stabilityQueries
        }

        fileprivate var isValid: Bool {
            !predictorColumns.isEmpty && Set(predictorColumns).count == predictorColumns.count
                && predictorColumns.allSatisfy(Self.isValidColumnName)
                && Self.isValidColumnName(responseColumn) && !predictorColumns.contains(responseColumn)
                && validationConfiguration.specification == specification
                && (scalePolicy?.isValid ?? true)
                && (bootstrapConfiguration == nil || bootstrapConfiguration?.specification == specification)
                && stabilityQueries.allSatisfy {
                    $0.count == predictorColumns.count && $0.allSatisfy(\.isFinite)
                }
                && (bootstrapConfiguration == nil || !stabilityQueries.isEmpty)
        }

        public var effectiveScalePolicy: StatisticalScalePolicy { scalePolicy ?? .fullData }

        private static func isValidColumnName(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Frozen diagnostic and validation evidence. A later replay must create a
    /// new snapshot rather than silently overwrite this result.
    public struct EvidenceSnapshot: Codable, Sendable, Hashable {
        public let capturedAt: Date
        public let sourceFingerprint: String
        public let report: AnalysisReport
        public let workbenchOutputs: [WorkbenchOutput]

        public init(
            capturedAt: Date = Date(), sourceFingerprint: String, report: AnalysisReport,
            workbenchOutputs: [WorkbenchOutput]
        ) throws {
            guard !sourceFingerprint.isEmpty,
                  Set(workbenchOutputs.map(\.id)).count == workbenchOutputs.count else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            self.capturedAt = capturedAt
            self.sourceFingerprint = sourceFingerprint
            self.report = report
            self.workbenchOutputs = workbenchOutputs
        }

        fileprivate var isValid: Bool {
            !sourceFingerprint.isEmpty && Set(workbenchOutputs.map(\.id)).count == workbenchOutputs.count
        }
    }

    /// Frozen evidence for a unified GAM or multivariate statistical model.
    ///
    /// Calibration is derived solely from held-out predictions, and bootstrap
    /// output retains failed-replicate accounting. Numerical provenance records
    /// the requested policy separately from the backend actually accepted.
    public struct AdvancedModelEvidence: Codable, Sendable, Hashable {
        public let capturedAt: Date
        public let sourceFingerprint: String
        public let modelKind: StatisticalModelKind
        public let diagnostics: FitDiagnostics
        /// Requested policy from the saved multivariate specification.
        /// `nil` means the fitted model did not use a multivariate numerical solve.
        public let requestedSolverPreference: MultivariateSolverPreference?
        /// The final accepted backend. This must never be inferred from the
        /// requested policy, because automatic sparse dispatch may fall back.
        public let solverBackend: MultivariateSolverBackend?
        /// Immutable Rust-NumericCore CGLS evidence for an accepted native CSR
        /// final update. It is absent for dense execution and older documents.
        public let sparseExecution: SparseExecutionEvidence?
        public let validation: ModelValidation?
        public let calibration: BinomialCalibration?
        public let bootstrap: BootstrapResult?

        public init(
            capturedAt: Date = Date(), sourceFingerprint: String,
            modelKind: StatisticalModelKind, diagnostics: FitDiagnostics,
            requestedSolverPreference: MultivariateSolverPreference? = nil,
            solverBackend: MultivariateSolverBackend? = nil,
            sparseExecution: SparseExecutionEvidence? = nil,
            validation: ModelValidation? = nil, calibration: BinomialCalibration? = nil,
            bootstrap: BootstrapResult? = nil
        ) throws {
            guard !sourceFingerprint.isEmpty,
                  calibration.map({ calibration in
                      validation?.responseFamily == .binomial
                          && calibration.observationCount == validation?.retainedObservationCount
                  }) ?? true,
                  bootstrap.map({ $0.configuration.specification == validation?.configuration.specification
                      || validation == nil }) ?? true,
                  sparseExecution.map({ execution in
                      requestedSolverPreference != nil && solverBackend == .sparseCGLS
                          && execution.converged && execution.designRows > 0
                          && execution.designColumns > 1 && execution.nonZeroCount >= execution.designRows
                          && execution.iterations > 0 && execution.normalResidualNorm.isFinite
                          && execution.weightedResidualSumOfSquares.isFinite
                          && execution.penaltyContribution.isFinite
                  }) ?? true else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            self.capturedAt = capturedAt
            self.sourceFingerprint = sourceFingerprint
            self.modelKind = modelKind
            self.diagnostics = diagnostics
            self.requestedSolverPreference = requestedSolverPreference
            self.solverBackend = solverBackend
            self.sparseExecution = sparseExecution
            self.validation = validation
            self.calibration = calibration
            self.bootstrap = bootstrap
        }

        fileprivate var isValid: Bool {
            !sourceFingerprint.isEmpty
                && (calibration.map {
                    validation?.responseFamily == .binomial
                        && $0.observationCount == validation?.retainedObservationCount
                } ?? true)
                && (bootstrap.map { $0.configuration.specification == validation?.configuration.specification
                    || validation == nil } ?? true)
                && (sparseExecution.map { execution in
                    requestedSolverPreference != nil && solverBackend == .sparseCGLS
                        && execution.converged && execution.designRows > 0
                        && execution.designColumns > 1 && execution.nonZeroCount >= execution.designRows
                        && execution.iterations > 0 && execution.normalResidualNorm.isFinite
                        && execution.weightedResidualSumOfSquares.isFinite
                        && execution.penaltyContribution.isFinite
                } ?? true)
        }
    }

    /// A compact, frozen summary of a paired held-out comparison. Individual
    /// predictions remain in the two referenced validation snapshots, avoiding
    /// a second full copy for large analyses.
    public struct ComparativeEvidence: Codable, Sendable, Hashable {
        public enum Verdict: String, Codable, Sendable, Hashable {
            case comparable
            case sourceFingerprintMismatch
            case transformationLineageMismatch
            case scaleSelectionMismatch
            case validationConfigurationMismatch
            case validationUnavailable
            case responseFamilyMismatch
            case heldOutObservationsMismatch
            case foldAssignmentMismatch
        }

        public let capturedAt: Date
        public let baselineRunBlockID: UUID
        public let candidateRunBlockID: UUID
        public let baselineEvidenceBlockID: UUID
        public let candidateEvidenceBlockID: UUID
        public let sourceFingerprint: String
        public let verdict: Verdict
        public let responseFamily: ResponseFamily?
        public let baselinePrimaryScore: Double?
        public let candidatePrimaryScore: Double?
        /// Candidate-minus-baseline held-out loss. Negative favors the candidate.
        public let meanLossDifference: Double?
        public let candidateWinCount: Int
        public let baselineWinCount: Int
        public let tieCount: Int
        public let pairedObservationCount: Int

        fileprivate init(
            capturedAt: Date, baselineRunBlockID: UUID, candidateRunBlockID: UUID,
            baselineEvidenceBlockID: UUID, candidateEvidenceBlockID: UUID,
            sourceFingerprint: String, verdict: Verdict,
            responseFamily: ResponseFamily? = nil, baselinePrimaryScore: Double? = nil,
            candidatePrimaryScore: Double? = nil, meanLossDifference: Double? = nil,
            candidateWinCount: Int = 0, baselineWinCount: Int = 0, tieCount: Int = 0,
            pairedObservationCount: Int = 0
        ) throws {
            let ids = [baselineRunBlockID, candidateRunBlockID, baselineEvidenceBlockID, candidateEvidenceBlockID]
            let comparableValues = responseFamily != nil && baselinePrimaryScore?.isFinite == true
                && candidatePrimaryScore?.isFinite == true && meanLossDifference?.isFinite == true
                && pairedObservationCount > 0
                && candidateWinCount + baselineWinCount + tieCount == pairedObservationCount
            let unavailableValues = responseFamily == nil && baselinePrimaryScore == nil
                && candidatePrimaryScore == nil && meanLossDifference == nil
                && candidateWinCount == 0 && baselineWinCount == 0 && tieCount == 0
                && pairedObservationCount == 0
            guard !sourceFingerprint.isEmpty, Set(ids).count == ids.count,
                  (verdict == .comparable ? comparableValues : unavailableValues) else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            self.capturedAt = capturedAt
            self.baselineRunBlockID = baselineRunBlockID
            self.candidateRunBlockID = candidateRunBlockID
            self.baselineEvidenceBlockID = baselineEvidenceBlockID
            self.candidateEvidenceBlockID = candidateEvidenceBlockID
            self.sourceFingerprint = sourceFingerprint
            self.verdict = verdict
            self.responseFamily = responseFamily
            self.baselinePrimaryScore = baselinePrimaryScore
            self.candidatePrimaryScore = candidatePrimaryScore
            self.meanLossDifference = meanLossDifference
            self.candidateWinCount = candidateWinCount
            self.baselineWinCount = baselineWinCount
            self.tieCount = tieCount
            self.pairedObservationCount = pairedObservationCount
        }

        fileprivate var isValid: Bool {
            (try? Self(
                capturedAt: capturedAt, baselineRunBlockID: baselineRunBlockID,
                candidateRunBlockID: candidateRunBlockID,
                baselineEvidenceBlockID: baselineEvidenceBlockID,
                candidateEvidenceBlockID: candidateEvidenceBlockID,
                sourceFingerprint: sourceFingerprint, verdict: verdict,
                responseFamily: responseFamily, baselinePrimaryScore: baselinePrimaryScore,
                candidatePrimaryScore: candidatePrimaryScore, meanLossDifference: meanLossDifference,
                candidateWinCount: candidateWinCount, baselineWinCount: baselineWinCount,
                tieCount: tieCount, pairedObservationCount: pairedObservationCount
            )) != nil
        }
    }

    /// The immutable outcome of one explicit analysis execution.
    public enum AnalysisRunStatus: String, Codable, Sendable, Hashable {
        case completed
        case failed
    }

    /// A recipe snapshot attached to a run rather than inferred from a model
    /// block at review time. This protects an analysis record from a later
    /// model-block edit or from ambiguity about which validation plan ran.
    public enum AnalysisRunRecipe: Codable, Sendable, Hashable {
        case model(ModelRecipe)
        case advancedModel(AdvancedModelRecipe)

        fileprivate var validationSeed: UInt64 {
            switch self {
            case .model(let recipe): recipe.validationConfiguration.seed
            case .advancedModel(let recipe): recipe.validationConfiguration.seed
            }
        }

        fileprivate var validationConfiguration: ValidationConfiguration {
            switch self {
            case .model(let recipe): return recipe.validationConfiguration
            case .advancedModel(let recipe): return recipe.validationConfiguration
            }
        }

        fileprivate var bootstrapSeed: UInt64? {
            guard case .advancedModel(let recipe) = self else { return nil }
            return recipe.bootstrapConfiguration?.seed
        }

        fileprivate var requestedSolverPreference: MultivariateSolverPreference? {
            guard case .advancedModel(let recipe) = self else { return nil }
            return recipe.specification.multivariate?.solverPreference
        }

        fileprivate var scalePolicy: StatisticalScalePolicy {
            switch self {
            case .model(let recipe): return recipe.effectiveScalePolicy
            case .advancedModel(let recipe): return recipe.effectiveScalePolicy
            }
        }
    }

    /// A reproducible, immutable analysis run.
    ///
    /// A run has one direct model dependency and snapshots all execution
    /// inputs: source fingerprint, transformation lineage, recipe, validation
    /// and bootstrap seeds, and numerical policy. Result figures and evidence
    /// depend on the run, never on a mutable notion of “latest result”.
    public struct AnalysisRun: Codable, Sendable, Hashable {
        public let sourceFingerprint: String
        public let modelBlockID: UUID
        /// Ordered transformation ancestors actually replayed for this model.
        public let transformationBlockIDs: [UUID]
        public let recipe: AnalysisRunRecipe
        public let validationSeed: UInt64
        public let bootstrapSeed: UInt64?
        public let requestedSolverPreference: MultivariateSolverPreference?
        /// Observed scale selection. `nil` remains readable for older runs.
        public let scaleSelection: StatisticalScaleSelection?
        public let startedAt: Date
        public let completedAt: Date
        public let status: AnalysisRunStatus
        /// Retained rows for a completed fit; `nil` for a failed run.
        public let retainedObservationCount: Int?
        /// Human-readable terminal failure reason; absent for completed runs.
        public let failureDescription: String?

        public init(
            sourceFingerprint: String, modelBlockID: UUID,
            transformationBlockIDs: [UUID], recipe: AnalysisRunRecipe,
            startedAt: Date, completedAt: Date, status: AnalysisRunStatus,
            retainedObservationCount: Int? = nil, failureDescription: String? = nil,
            scaleSelection: StatisticalScaleSelection? = nil
        ) throws {
            let validFailure: Bool
            switch status {
            case .completed:
                validFailure = retainedObservationCount != nil && retainedObservationCount! >= 0
                    && failureDescription == nil
            case .failed:
                validFailure = retainedObservationCount == nil
                    && !(failureDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
            guard !sourceFingerprint.isEmpty,
                  Set(transformationBlockIDs).count == transformationBlockIDs.count,
                  !transformationBlockIDs.contains(modelBlockID),
                  completedAt >= startedAt, validFailure else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            self.sourceFingerprint = sourceFingerprint
            self.modelBlockID = modelBlockID
            self.transformationBlockIDs = transformationBlockIDs
            self.recipe = recipe
            validationSeed = recipe.validationSeed
            bootstrapSeed = recipe.bootstrapSeed
            requestedSolverPreference = recipe.requestedSolverPreference
            self.scaleSelection = scaleSelection
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.status = status
            self.retainedObservationCount = retainedObservationCount
            self.failureDescription = failureDescription
        }

        fileprivate var isValid: Bool {
            guard !sourceFingerprint.isEmpty,
                  Set(transformationBlockIDs).count == transformationBlockIDs.count,
                  !transformationBlockIDs.contains(modelBlockID), completedAt >= startedAt,
                  validationSeed == recipe.validationSeed,
                  bootstrapSeed == recipe.bootstrapSeed,
                  requestedSolverPreference == recipe.requestedSolverPreference,
                  scaleSelection?.isValid ?? true,
                  scaleSelection.map({ $0.policy == recipe.scalePolicy }) ?? true else { return false }
            switch status {
            case .completed:
                return retainedObservationCount.map { $0 >= 0 } ?? false
                    && failureDescription == nil
            case .failed:
                return retainedObservationCount == nil
                    && !(failureDescription?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            }
        }

        /// Capture a successful fit as a self-contained run snapshot.
        public static func completed(
            in document: AnalysisDocument, modelBlockID: UUID,
            retainedObservationCount: Int, startedAt: Date, completedAt: Date = Date(),
            scaleSelection: StatisticalScaleSelection? = nil
        ) throws -> AnalysisRun {
            try make(
                in: document, modelBlockID: modelBlockID, startedAt: startedAt,
                completedAt: completedAt, status: .completed,
                retainedObservationCount: retainedObservationCount, failureDescription: nil,
                scaleSelection: scaleSelection
            )
        }

        /// Capture a terminal failure without disguising it as an absent run.
        public static func failed(
            in document: AnalysisDocument, modelBlockID: UUID, description: String,
            startedAt: Date, completedAt: Date = Date()
        ) throws -> AnalysisRun {
            try make(
                in: document, modelBlockID: modelBlockID, startedAt: startedAt,
                completedAt: completedAt, status: .failed,
                retainedObservationCount: nil, failureDescription: description,
                scaleSelection: nil
            )
        }

        private static func make(
            in document: AnalysisDocument, modelBlockID: UUID,
            startedAt: Date, completedAt: Date, status: AnalysisRunStatus,
            retainedObservationCount: Int?, failureDescription: String?,
            scaleSelection: StatisticalScaleSelection?
        ) throws -> AnalysisRun {
            guard let recipe = document.runRecipe(for: modelBlockID) else {
                throw AnalysisDocumentError.invalidDependency(modelBlockID)
            }
            return try AnalysisRun(
                sourceFingerprint: document.source.fingerprint, modelBlockID: modelBlockID,
                transformationBlockIDs: document.transformationAncestors(of: modelBlockID),
                recipe: recipe, startedAt: startedAt, completedAt: completedAt,
                status: status, retainedObservationCount: retainedObservationCount,
                failureDescription: failureDescription, scaleSelection: scaleSelection
            )
        }
    }

    /// A captioned statistical figure recorded by a host. The rendered pixels
    /// intentionally do not live in the document: a host can redraw the figure
    /// from its model recipe, while the annotation remains searchable and
    /// reviewable in a small portable file.
    public struct FigureAnnotation: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable, Hashable {
            case fittedCurve
            case residuals
            case qqPlot
            case gradient
            case surface
        }

        public let kind: Kind
        public let caption: String

        public init(kind: Kind, caption: String) throws {
            guard !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            self.kind = kind
            self.caption = caption
        }

        fileprivate var isValid: Bool {
            !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public enum BlockPayload: Codable, Sendable, Hashable {
        case transformation(Transformation)
        case validationPlan(ValidationPlan)
        case model(ModelRecipe)
        case advancedModel(AdvancedModelRecipe)
        case run(AnalysisRun)
        case evidence(EvidenceSnapshot)
        case advancedEvidence(AdvancedModelEvidence)
        case comparison(ComparativeEvidence)
        case figure(FigureAnnotation)
        case note(String)
    }

    public enum BlockState: String, Codable, Sendable, Hashable {
        /// Inputs have not been edited since this block was created or refreshed.
        case current
        /// An upstream source, transformation, or model changed; recomputation is explicit.
        case stale
    }

    /// One ordered notebook block and its upstream dependencies.
    public struct Block: Codable, Sendable, Hashable, Identifiable {
        public let id: UUID
        public let title: String
        public let upstreamBlockIDs: [UUID]
        public let payload: BlockPayload
        public fileprivate(set) var state: BlockState
        public let createdAt: Date
        public fileprivate(set) var updatedAt: Date

        public init(
            id: UUID = UUID(), title: String, upstreamBlockIDs: [UUID] = [],
            payload: BlockPayload, state: BlockState = .current,
            createdAt: Date = Date(), updatedAt: Date = Date()
        ) throws {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Set(upstreamBlockIDs).count == upstreamBlockIDs.count,
                  !upstreamBlockIDs.contains(id), Self.isValid(payload) else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            self.id = id
            self.title = title
            self.upstreamBlockIDs = upstreamBlockIDs
            self.payload = payload
            self.state = state
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        fileprivate mutating func markStale(at date: Date) {
            guard state != .stale else { return }
            state = .stale
            updatedAt = date
        }

        fileprivate mutating func markCurrent(at date: Date) {
            state = .current
            updatedAt = date
        }

        fileprivate static func isValid(_ payload: BlockPayload) -> Bool {
            switch payload {
            case .transformation(let transformation): return transformation.isValid
            case .validationPlan(let plan): return plan.isValid
            case .model(let recipe): return recipe.isValid
            case .advancedModel(let recipe): return recipe.isValid
            case .run(let run): return run.isValid
            case .evidence(let evidence): return evidence.isValid
            case .advancedEvidence(let evidence): return evidence.isValid
            case .comparison(let comparison): return comparison.isValid
            case .figure(let figure): return figure.isValid
            case .note(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    /// A portable, review-oriented arrangement of notebook blocks.
    ///
    /// Sections contain prose and references only. They intentionally cannot
    /// introduce executable code, duplicate a block, or modify a block's
    /// dependency graph. This keeps a polished narrative separate from the
    /// analysis record that it explains.
    public struct NotebookComposition: Codable, Sendable, Hashable {
        public struct Section: Codable, Sendable, Hashable, Identifiable {
            public let id: UUID
            public let title: String
            /// Short human interpretation or review context; empty is allowed
            /// while a section is being assembled.
            public let narrative: String
            /// Existing notebook blocks, in the intended reader order.
            public let blockIDs: [UUID]

            public init(
                id: UUID = UUID(), title: String, narrative: String = "",
                blockIDs: [UUID] = []
            ) throws {
                let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedTitle.isEmpty,
                      Set(blockIDs).count == blockIDs.count else {
                    throw AnalysisDocumentError.invalidConfiguration
                }
                self.id = id
                self.title = normalizedTitle
                self.narrative = narrative.trimmingCharacters(in: .whitespacesAndNewlines)
                self.blockIDs = blockIDs
            }

            fileprivate var isValid: Bool {
                !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && Set(blockIDs).count == blockIDs.count
            }
        }

        public private(set) var sections: [Section]

        public init() {
            sections = []
        }

        public init(sections: [Section]) throws {
            guard Self.isValid(sections) else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            self.sections = sections
        }

        /// References in their presentation order.
        public var blockIDs: [UUID] { sections.flatMap(\.blockIDs) }

        public mutating func appendSection(
            title: String, narrative: String = ""
        ) throws -> UUID {
            let section = try Section(title: title, narrative: narrative)
            sections.append(section)
            return section.id
        }

        public mutating func updateSection(
            id: UUID, title: String, narrative: String
        ) throws {
            guard let index = sections.firstIndex(where: { $0.id == id }) else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            sections[index] = try Section(
                id: id, title: title, narrative: narrative,
                blockIDs: sections[index].blockIDs
            )
        }

        public mutating func moveSection(id: UUID, to destinationIndex: Int) throws {
            guard let index = sections.firstIndex(where: { $0.id == id }),
                  sections.indices.contains(destinationIndex) else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            let section = sections.remove(at: index)
            sections.insert(section, at: destinationIndex)
        }

        fileprivate mutating func assign(blockID: UUID, to sectionID: UUID) throws {
            guard !blockIDs.contains(blockID),
                  let index = sections.firstIndex(where: { $0.id == sectionID }) else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            let section = sections[index]
            sections[index] = try Section(
                id: section.id, title: section.title, narrative: section.narrative,
                blockIDs: section.blockIDs + [blockID]
            )
        }

        fileprivate static func initialOutline(for blocks: [Block]) throws -> NotebookComposition {
            var preparation: [UUID] = []
            var methods: [UUID] = []
            var evidence: [UUID] = []
            for block in blocks {
                switch block.payload {
                case .transformation:
                    preparation.append(block.id)
                case .validationPlan, .model, .advancedModel:
                    methods.append(block.id)
                case .run, .evidence, .advancedEvidence, .comparison, .figure, .note:
                    evidence.append(block.id)
                }
            }
            var sections: [Section] = []
            if !preparation.isEmpty {
                sections.append(try Section(
                    title: "Data & preparation",
                    narrative: "Source selection and replayable preparation.", blockIDs: preparation
                ))
            }
            if !methods.isEmpty {
                sections.append(try Section(
                    title: "Models & validation",
                    narrative: "Model specifications and the validation policies used to assess them.",
                    blockIDs: methods
                ))
            }
            if !evidence.isEmpty {
                sections.append(try Section(
                    title: "Results & interpretation",
                    narrative: "Frozen runs, diagnostics, figures, and review notes.", blockIDs: evidence
                ))
            }
            return try NotebookComposition(sections: sections)
        }

        fileprivate var isValid: Bool { Self.isValid(sections) }

        private static func isValid(_ sections: [Section]) -> Bool {
            Set(sections.map(\.id)).count == sections.count
                && sections.allSatisfy(\.isValid)
                && Set(sections.flatMap(\.blockIDs)).count == sections.flatMap(\.blockIDs).count
        }
    }

    /// A structured, portable review record for a statistical document.
    ///
    /// Review authors are display labels supplied by the person using the
    /// document. They are provenance for a shared file, not authenticated
    /// identities or a live-collaboration protocol.
    public struct DocumentReview: Codable, Sendable, Hashable {
        public enum Readiness: String, Codable, Sendable, Hashable {
            case draft
            case readyForReview
            case accepted
        }

        public struct Finding: Codable, Sendable, Hashable, Identifiable {
            public enum Severity: String, Codable, Sendable, Hashable, CaseIterable {
                case note
                case concern
                case blocker
            }

            public enum Status: String, Codable, Sendable, Hashable {
                case open
                case resolved
                case dismissed
            }

            public let id: UUID
            /// A non-empty, user-entered display label; not an authenticated identity.
            public let author: String
            public let body: String
            /// Nil denotes a document-level finding; a value names one saved block.
            public let targetBlockID: UUID?
            public let severity: Severity
            public let createdAt: Date
            public private(set) var status: Status
            public private(set) var resolution: String?
            public private(set) var resolvedAt: Date?

            public init(
                id: UUID = UUID(), author: String, body: String, targetBlockID: UUID? = nil,
                severity: Severity = .concern, createdAt: Date = Date(),
                status: Status = .open, resolution: String? = nil, resolvedAt: Date? = nil
            ) throws {
                let normalizedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedResolution = resolution?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalizedAuthor.isEmpty, !normalizedBody.isEmpty,
                      normalizedResolution?.isEmpty != true,
                      Self.hasValidClosure(
                        status: status, resolution: normalizedResolution, resolvedAt: resolvedAt,
                        createdAt: createdAt
                      ) else {
                    throw AnalysisDocumentError.invalidConfiguration
                }
                self.id = id
                self.author = normalizedAuthor
                self.body = normalizedBody
                self.targetBlockID = targetBlockID
                self.severity = severity
                self.createdAt = createdAt
                self.status = status
                self.resolution = normalizedResolution
                self.resolvedAt = resolvedAt
            }

            fileprivate mutating func close(
                as status: Status, resolution: String, at date: Date
            ) throws {
                let normalized = resolution.trimmingCharacters(in: .whitespacesAndNewlines)
                guard self.status == .open, status != .open, !normalized.isEmpty, date >= createdAt else {
                    throw AnalysisDocumentError.invalidConfiguration
                }
                self.status = status
                self.resolution = normalized
                resolvedAt = date
            }

            fileprivate var isValid: Bool {
                !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && resolution?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != true
                    && Self.hasValidClosure(
                        status: status, resolution: resolution, resolvedAt: resolvedAt,
                        createdAt: createdAt
                    )
            }

            private static func hasValidClosure(
                status: Status, resolution: String?, resolvedAt: Date?, createdAt: Date
            ) -> Bool {
                switch status {
                case .open: return resolution == nil && resolvedAt == nil
                case .resolved, .dismissed:
                    return resolution != nil && resolvedAt.map { $0 >= createdAt } == true
                }
            }
        }

        public private(set) var readiness: Readiness
        public private(set) var findings: [Finding]

        public init() {
            readiness = .draft
            findings = []
        }

        public init(readiness: Readiness, findings: [Finding]) throws {
            guard Self.isValid(findings) else { throw AnalysisDocumentError.invalidConfiguration }
            self.readiness = readiness
            self.findings = findings
        }

        public var openFindings: [Finding] { findings.filter { $0.status == .open } }
        public var openBlockerCount: Int {
            openFindings.filter { $0.severity == .blocker }.count
        }

        fileprivate mutating func append(_ finding: Finding) throws {
            guard !findings.contains(where: { $0.id == finding.id }) else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            findings.append(finding)
            readiness = .draft
        }

        fileprivate mutating func close(
            findingID: UUID, as status: Finding.Status, resolution: String, at date: Date
        ) throws {
            guard let index = findings.firstIndex(where: { $0.id == findingID }) else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            try findings[index].close(as: status, resolution: resolution, at: date)
            readiness = .draft
        }

        fileprivate mutating func setReadiness(_ readiness: Readiness) {
            self.readiness = readiness
        }

        fileprivate mutating func resetReadiness() {
            if readiness != .draft { readiness = .draft }
        }

        fileprivate var isValid: Bool { Self.isValid(findings) }

        private static func isValid(_ findings: [Finding]) -> Bool {
            Set(findings.map(\.id)).count == findings.count && findings.allSatisfy(\.isValid)
        }
    }

    /// A computed audit summary. It does not silently promote a document's
    /// readiness: callers must explicitly set the corresponding review state.
    public struct ReviewSummary: Sendable, Hashable {
        public let readiness: DocumentReview.Readiness
        public let staleBlockCount: Int
        public let openFindingCount: Int
        public let openBlockerCount: Int
        public let hasAnalysisBlocks: Bool

        public var canMarkReady: Bool {
            hasAnalysisBlocks && staleBlockCount == 0 && openBlockerCount == 0
        }

        public var canAccept: Bool { canMarkReady && openFindingCount == 0 }
    }

    /// Append a block after its dependencies. No result is recomputed implicitly.
    public mutating func append(_ block: Block, at date: Date = Date()) throws {
        let previousReview = review
        let previousUpdatedAt = updatedAt
        blocks.append(block)
        review.resetReadiness()
        updatedAt = date
        do {
            try validate()
        } catch {
            blocks.removeLast()
            review = previousReview
            updatedAt = previousUpdatedAt
            throw error
        }
    }

    /// Replace one structured operation, mark all of its downstream results
    /// stale, and return the affected block IDs for UI invalidation.
    @discardableResult
    public mutating func update(
        blockID: UUID, payload: BlockPayload, at date: Date = Date()
    ) throws -> Set<UUID> {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }), Block.isValid(payload) else {
            throw AnalysisDocumentError.invalidConfiguration
        }
        blocks[index] = try Block(
            id: blocks[index].id, title: blocks[index].title,
            upstreamBlockIDs: blocks[index].upstreamBlockIDs, payload: payload,
            state: .current, createdAt: blocks[index].createdAt, updatedAt: date
        )
        let stale = markDownstreamStale(of: blockID, at: date)
        review.resetReadiness()
        updatedAt = date
        try validate()
        return stale
    }

    /// Record that a user selected changed source content. Every derived block
    /// becomes stale; the source itself is the new current baseline.
    @discardableResult
    public mutating func updateSource(_ source: Source, at date: Date = Date()) throws -> Set<UUID> {
        self.source = source
        let stale = Set(blocks.map(\.id))
        for index in blocks.indices { blocks[index].markStale(at: date) }
        review.resetReadiness()
        updatedAt = date
        try validate()
        return stale
    }

    /// Mark a replayed block and every input it actually used as current.
    ///
    /// Hosts call this only after their explicit replay/fit operation has
    /// completed successfully. It never revives descendants such as a prior
    /// diagnostic snapshot, which keeps historical evidence honest.
    @discardableResult
    public mutating func markCurrent(
        through targetBlockID: UUID, at date: Date = Date()
    ) throws -> Set<UUID> {
        guard blocks.contains(where: { $0.id == targetBlockID }) else {
            throw AnalysisDocumentError.invalidDependency(targetBlockID)
        }
        var current: Set<UUID> = [targetBlockID]
        for block in blocks.reversed() where current.contains(block.id) {
            current.formUnion(block.upstreamBlockIDs)
        }
        for index in blocks.indices where current.contains(blocks[index].id) {
            blocks[index].markCurrent(at: date)
        }
        updatedAt = date
        try validate()
        return current
    }

    /// The most recent model recipe, convenient for hosts offering one active
    /// chart/document workbench at a time.
    public var latestModelBlockID: UUID? {
        blocks.last { block in
            if case .model = block.payload { return true }
            return false
        }?.id
    }

    /// Most recent unified-GAM or multivariate model recipe.
    public var latestAdvancedModelBlockID: UUID? {
        blocks.last { block in
            if case .advancedModel = block.payload { return true }
            return false
        }?.id
    }

    /// Validation-plan blocks in notebook order, suitable for a host picker.
    public var validationPlanBlocks: [Block] {
        blocks.filter {
            if case .validationPlan = $0.payload { return true }
            return false
        }
    }

    /// Find a reusable validation plan by its stable notebook-block identity.
    public func validationPlan(blockID: UUID) -> ValidationPlan? {
        guard let block = blocks.first(where: { $0.id == blockID }),
              case .validationPlan(let plan) = block.payload else { return nil }
        return plan
    }

    /// Blocks not yet placed in a reader-facing notebook section.
    public var uncomposedBlocks: [Block] {
        let assigned = Set(composition.blockIDs)
        return blocks.filter { !assigned.contains($0.id) }
    }

    /// Completed advanced runs that carry frozen held-out validation evidence.
    /// These are the only runs eligible for a paired comparison block.
    public var comparisonCandidateRunBlocks: [Block] {
        blocks.filter { block in
            guard block.state == .current, case .run(let run) = block.payload,
                  run.status == .completed, case .advancedModel = run.recipe else { return false }
            return advancedEvidenceBlock(forRunBlockID: block.id) != nil
        }
    }

    /// Add one immutable comparison block. The block retains both runs and
    /// evidence blocks as direct inputs, so later upstream edits make the
    /// comparison visibly stale rather than silently reusing it.
    @discardableResult
    public mutating func recordComparativeEvidence(
        baselineRunBlockID: UUID, candidateRunBlockID: UUID, at date: Date = Date()
    ) throws -> UUID {
        guard baselineRunBlockID != candidateRunBlockID,
              let baselineRunBlock = blocks.first(where: { $0.id == baselineRunBlockID }),
              let candidateRunBlock = blocks.first(where: { $0.id == candidateRunBlockID }),
              baselineRunBlock.state == .current, candidateRunBlock.state == .current,
              case .run(let baselineRun) = baselineRunBlock.payload,
              case .run(let candidateRun) = candidateRunBlock.payload,
              baselineRun.status == .completed, candidateRun.status == .completed,
              case .advancedModel = baselineRun.recipe, case .advancedModel = candidateRun.recipe,
              let baselineEvidenceBlock = advancedEvidenceBlock(forRunBlockID: baselineRunBlockID),
              let candidateEvidenceBlock = advancedEvidenceBlock(forRunBlockID: candidateRunBlockID),
              baselineEvidenceBlock.state == .current, candidateEvidenceBlock.state == .current,
              case .advancedEvidence(let baselineEvidence) = baselineEvidenceBlock.payload,
              case .advancedEvidence(let candidateEvidence) = candidateEvidenceBlock.payload else {
            throw AnalysisDocumentError.invalidConfiguration
        }
        let comparison = try makeComparativeEvidence(
            baselineRun: baselineRun, candidateRun: candidateRun,
            baselineEvidence: baselineEvidence, candidateEvidence: candidateEvidence,
            baselineRunBlockID: baselineRunBlockID, candidateRunBlockID: candidateRunBlockID,
            baselineEvidenceBlockID: baselineEvidenceBlock.id,
            candidateEvidenceBlockID: candidateEvidenceBlock.id, at: date
        )
        let title = comparison.verdict == .comparable
            ? "Paired model comparison" : "Non-comparable model comparison"
        let block = try Block(
            title: title,
            upstreamBlockIDs: [
                baselineRunBlockID, candidateRunBlockID,
                baselineEvidenceBlock.id, candidateEvidenceBlock.id,
            ],
            payload: .comparison(comparison), createdAt: date, updatedAt: date
        )
        try append(block, at: date)
        return block.id
    }

    /// Review status is deliberately separate from execution freshness. This
    /// summary exposes both so a visual "ready" badge cannot hide stale work
    /// or an unresolved blocker.
    public var reviewSummary: ReviewSummary {
        let staleBlockCount = blocks.filter { $0.state == .stale }.count
        return ReviewSummary(
            readiness: review.readiness, staleBlockCount: staleBlockCount,
            openFindingCount: review.openFindings.count,
            openBlockerCount: review.openBlockerCount,
            hasAnalysisBlocks: !blocks.isEmpty
        )
    }

    /// Add a portable review finding. A finding may be document-level or
    /// attached to one stable notebook block; it cannot target an unknown ID.
    @discardableResult
    public mutating func addReviewFinding(
        author: String, body: String, targetBlockID: UUID? = nil,
        severity: DocumentReview.Finding.Severity = .concern, at date: Date = Date()
    ) throws -> UUID {
        guard targetBlockID.map({ id in blocks.contains(where: { $0.id == id }) }) ?? true else {
            throw AnalysisDocumentError.invalidDependency(targetBlockID!)
        }
        let finding = try DocumentReview.Finding(
            author: author, body: body, targetBlockID: targetBlockID,
            severity: severity, createdAt: date
        )
        let previousReview = review
        let previousUpdatedAt = updatedAt
        do {
            try review.append(finding)
            updatedAt = date
            try validate()
            return finding.id
        } catch {
            review = previousReview
            updatedAt = previousUpdatedAt
            throw error
        }
    }

    /// Close one finding with an explicit, durable explanation. Resolving and
    /// dismissing are intentionally distinct audit outcomes.
    public mutating func closeReviewFinding(
        id: UUID, as status: DocumentReview.Finding.Status, resolution: String,
        at date: Date = Date()
    ) throws {
        let previousReview = review
        let previousUpdatedAt = updatedAt
        do {
            try review.close(findingID: id, as: status, resolution: resolution, at: date)
            updatedAt = date
            try validate()
        } catch {
            review = previousReview
            updatedAt = previousUpdatedAt
            throw error
        }
    }

    /// Explicitly state the document's review milestone. A ready document has
    /// no stale blocks or open blockers; acceptance additionally requires all
    /// findings to have a recorded terminal outcome.
    public mutating func setReviewReadiness(
        _ readiness: DocumentReview.Readiness, at date: Date = Date()
    ) throws {
        let previousReview = review
        let previousUpdatedAt = updatedAt
        review.setReadiness(readiness)
        updatedAt = date
        do {
            try validate()
        } catch {
            review = previousReview
            updatedAt = previousUpdatedAt
            throw error
        }
    }

    /// Generate a conservative, review-ready outline from current block kinds.
    /// Existing custom composition is never overwritten implicitly.
    public mutating func createInitialComposition(at date: Date = Date()) throws {
        guard composition.sections.isEmpty else { throw AnalysisDocumentError.invalidConfiguration }
        composition = try NotebookComposition.initialOutline(for: blocks)
        review.resetReadiness()
        updatedAt = date
        try validate()
    }

    @discardableResult
    public mutating func appendCompositionSection(
        title: String, narrative: String = "", at date: Date = Date()
    ) throws -> UUID {
        let sectionID = try composition.appendSection(title: title, narrative: narrative)
        review.resetReadiness()
        updatedAt = date
        try validate()
        return sectionID
    }

    public mutating func updateCompositionSection(
        id: UUID, title: String, narrative: String, at date: Date = Date()
    ) throws {
        try composition.updateSection(id: id, title: title, narrative: narrative)
        review.resetReadiness()
        updatedAt = date
        try validate()
    }

    public mutating func moveCompositionSection(
        id: UUID, to destinationIndex: Int, at date: Date = Date()
    ) throws {
        try composition.moveSection(id: id, to: destinationIndex)
        review.resetReadiness()
        updatedAt = date
        try validate()
    }

    /// Place one currently uncomposed block at the end of a composition section.
    public mutating func assignToComposition(
        blockID: UUID, sectionID: UUID, at date: Date = Date()
    ) throws {
        guard blocks.contains(where: { $0.id == blockID }) else {
            throw AnalysisDocumentError.invalidDependency(blockID)
        }
        try composition.assign(blockID: blockID, to: sectionID)
        review.resetReadiness()
        updatedAt = date
        try validate()
    }

    private func runRecipe(for modelBlockID: UUID) -> AnalysisRunRecipe? {
        guard let block = blocks.first(where: { $0.id == modelBlockID }) else { return nil }
        switch block.payload {
        case .model(let recipe): return .model(recipe)
        case .advancedModel(let recipe): return .advancedModel(recipe)
        default: return nil
        }
    }

    private func advancedEvidenceBlock(forRunBlockID runBlockID: UUID) -> Block? {
        blocks.first { block in
            block.upstreamBlockIDs == [runBlockID]
                && ({ if case .advancedEvidence = block.payload { return true }; return false }())
        }
    }

    private func makeComparativeEvidence(
        baselineRun: AnalysisRun, candidateRun: AnalysisRun,
        baselineEvidence: AdvancedModelEvidence, candidateEvidence: AdvancedModelEvidence,
        baselineRunBlockID: UUID, candidateRunBlockID: UUID,
        baselineEvidenceBlockID: UUID, candidateEvidenceBlockID: UUID, at date: Date
    ) throws -> ComparativeEvidence {
        func unavailable(_ verdict: ComparativeEvidence.Verdict) throws -> ComparativeEvidence {
            try ComparativeEvidence(
                capturedAt: date, baselineRunBlockID: baselineRunBlockID,
                candidateRunBlockID: candidateRunBlockID,
                baselineEvidenceBlockID: baselineEvidenceBlockID,
                candidateEvidenceBlockID: candidateEvidenceBlockID,
                sourceFingerprint: source.fingerprint, verdict: verdict
            )
        }
        guard baselineRun.sourceFingerprint == candidateRun.sourceFingerprint,
              baselineEvidence.sourceFingerprint == candidateEvidence.sourceFingerprint,
              baselineRun.sourceFingerprint == baselineEvidence.sourceFingerprint else {
            return try unavailable(.sourceFingerprintMismatch)
        }
        guard baselineRun.transformationBlockIDs == candidateRun.transformationBlockIDs else {
            return try unavailable(.transformationLineageMismatch)
        }
        guard baselineRun.scaleSelection == candidateRun.scaleSelection else {
            return try unavailable(.scaleSelectionMismatch)
        }
        let baselineConfiguration = baselineRun.recipe.validationConfiguration
        let candidateConfiguration = candidateRun.recipe.validationConfiguration
        guard baselineConfiguration.foldCount == candidateConfiguration.foldCount,
              baselineConfiguration.partitioning == candidateConfiguration.partitioning,
              baselineConfiguration.seed == candidateConfiguration.seed else {
            return try unavailable(.validationConfigurationMismatch)
        }
        guard let baselineValidation = baselineEvidence.validation,
              let candidateValidation = candidateEvidence.validation else {
            return try unavailable(.validationUnavailable)
        }
        let paired = ModelComparison.compare(baseline: baselineValidation, candidate: candidateValidation)
        let verdict: ComparativeEvidence.Verdict
        switch paired.status {
        case .comparable: verdict = .comparable
        case .responseFamilyMismatch: verdict = .responseFamilyMismatch
        case .heldOutObservationsMismatch: verdict = .heldOutObservationsMismatch
        case .foldAssignmentMismatch: verdict = .foldAssignmentMismatch
        }
        guard verdict == .comparable else { return try unavailable(verdict) }
        return try ComparativeEvidence(
            capturedAt: date, baselineRunBlockID: baselineRunBlockID,
            candidateRunBlockID: candidateRunBlockID,
            baselineEvidenceBlockID: baselineEvidenceBlockID,
            candidateEvidenceBlockID: candidateEvidenceBlockID,
            sourceFingerprint: source.fingerprint, verdict: .comparable,
            responseFamily: paired.responseFamily,
            baselinePrimaryScore: paired.baselinePrimaryScore,
            candidatePrimaryScore: paired.candidatePrimaryScore,
            meanLossDifference: paired.meanLossDifference,
            candidateWinCount: paired.candidateWinCount,
            baselineWinCount: paired.baselineWinCount, tieCount: paired.tieCount,
            pairedObservationCount: paired.pairedLosses.count
        )
    }

    /// Transformations are retained in document order, which is the replay
    /// order. Non-transformation ancestors (such as the chart model a unified
    /// model descends from) deliberately do not enter the snapshot.
    private func transformationAncestors(of blockID: UUID) -> [UUID] {
        var pending = [blockID]
        var visited = Set<UUID>()
        while let current = pending.popLast(),
              visited.insert(current).inserted,
              let block = blocks.first(where: { $0.id == current }) {
            pending.append(contentsOf: block.upstreamBlockIDs)
        }
        return blocks.compactMap { block in
            guard visited.contains(block.id), case .transformation = block.payload else { return nil }
            return block.id
        }
    }

    /// Stable JSON intended for project files or clipboard/export transfer.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Decode and validate before a host renders or replays document contents.
    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(Self.self, from: jsonData)
    }

    private enum CodingKeys: String, CodingKey {
        case id, schemaVersion, title, source, createdAt, updatedAt, blocks, composition, review
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        let decodedSchemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        title = try values.decode(String.self, forKey: .title)
        source = try values.decode(Source.self, forKey: .source)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        blocks = try values.decode([Block].self, forKey: .blocks)
        composition = try values.decodeIfPresent(NotebookComposition.self, forKey: .composition)
            ?? NotebookComposition()
        review = try values.decodeIfPresent(DocumentReview.self, forKey: .review)
            ?? DocumentReview()
        guard (1...Self.currentSchemaVersion).contains(decodedSchemaVersion) else {
            throw AnalysisDocumentError.unsupportedSchema(decodedSchemaVersion)
        }
        // Versions 1 and 2 predate advanced model/evidence blocks; version 3
        // predates native sparse-execution evidence; version 4 predates
        // explicit immutable run records; version 5 predates reusable
        // validation-plan blocks and optional model-plan links; version 6
        // predates composition sections; version 7 predates explicit scaled
        // fit policy and observed scale selection; version 8 predates portable
        // review findings and explicit readiness; version 9 predates frozen
        // comparative evidence. Existing representation is unchanged, so
        // normalize on open and write the upgraded schema only when the host
        // later saves.
        schemaVersion = Self.currentSchemaVersion
        try validate()
    }

    private mutating func markDownstreamStale(of id: UUID, at date: Date) -> Set<UUID> {
        var stale: Set<UUID> = []
        var pending: Set<UUID> = [id]
        while !pending.isEmpty {
            let current = pending.removeFirst()
            for index in blocks.indices where blocks[index].upstreamBlockIDs.contains(current) {
                let downstream = blocks[index].id
                if stale.insert(downstream).inserted {
                    blocks[index].markStale(at: date)
                    pending.insert(downstream)
                }
            }
        }
        return stale
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              source.isValid,
              Set(blocks.map(\.id)).count == blocks.count,
              composition.isValid,
              Set(composition.blockIDs).isSubset(of: Set(blocks.map(\.id))),
              review.isValid,
              Set(review.findings.compactMap(\.targetBlockID)).isSubset(of: Set(blocks.map(\.id))) else {
            throw AnalysisDocumentError.invalidConfiguration
        }
        let summary = reviewSummary
        switch review.readiness {
        case .draft:
            break
        case .readyForReview:
            guard summary.canMarkReady else {
                throw AnalysisDocumentError.invalidConfiguration
            }
        case .accepted:
            guard summary.canAccept else {
                throw AnalysisDocumentError.invalidConfiguration
            }
        }
        var preceding = Set<UUID>()
        for block in blocks {
            guard Set(block.upstreamBlockIDs).count == block.upstreamBlockIDs.count,
                  Set(block.upstreamBlockIDs).isSubset(of: preceding),
                  Block.isValid(block.payload) else {
                throw AnalysisDocumentError.invalidDependency(block.id)
            }
            if case .evidence(let evidence) = block.payload {
                guard (block.state == .stale || evidence.sourceFingerprint == source.fingerprint),
                      (hasDirectModelDependency(block) || hasDirectCompletedRunDependency(block)) else {
                    throw AnalysisDocumentError.invalidEvidence(block.id)
                }
            }
            if case .advancedEvidence(let evidence) = block.payload {
                guard (block.state == .stale || evidence.sourceFingerprint == source.fingerprint),
                      (hasDirectAdvancedModelDependency(block) || hasDirectCompletedAdvancedRunDependency(block)) else {
                    throw AnalysisDocumentError.invalidEvidence(block.id)
                }
            }
            if case .comparison(let comparison) = block.payload,
               !isValidComparisonDependency(block, comparison: comparison) {
                throw AnalysisDocumentError.invalidEvidence(block.id)
            }
            if case .model(let recipe) = block.payload,
               !hasValidValidationPlanDependency(
                block, planBlockID: recipe.validationPlanBlockID,
                validation: recipe.validationConfiguration, bootstrap: nil
               ) {
                throw AnalysisDocumentError.invalidDependency(block.id)
            }
            if case .advancedModel(let recipe) = block.payload,
               !hasValidValidationPlanDependency(
                block, planBlockID: recipe.validationPlanBlockID,
                validation: recipe.validationConfiguration,
                bootstrap: recipe.bootstrapConfiguration
               ) {
                throw AnalysisDocumentError.invalidDependency(block.id)
            }
            if case .run(let run) = block.payload,
               !isValidRunDependency(block, run: run) {
                throw AnalysisDocumentError.invalidDependency(block.id)
            }
            if case .figure = block.payload,
               !(hasDirectModelDependency(block) || hasDirectCompletedRunDependency(block)) {
                throw AnalysisDocumentError.invalidDependency(block.id)
            }
            preceding.insert(block.id)
        }
    }

    /// A plan reference is intentionally a direct model input. Current models
    /// must exactly equal the resolved plan; stale historical models remain
    /// readable after a plan has been edited, like evidence after a source edit.
    private func hasValidValidationPlanDependency(
        _ block: Block, planBlockID: UUID?, validation: ValidationConfiguration,
        bootstrap: BootstrapConfiguration?
    ) -> Bool {
        guard let planBlockID else { return true }
        guard block.upstreamBlockIDs.contains(planBlockID),
              let plan = validationPlan(blockID: planBlockID) else { return false }
        guard block.state == .stale else {
            return plan.supports(validation.specification)
                && plan.validationConfiguration(for: validation.specification) == validation
                && plan.bootstrapConfiguration(for: validation.specification) == bootstrap
        }
        return true
    }

    private func hasDirectModelDependency(_ block: Block) -> Bool {
        block.upstreamBlockIDs.contains { id in
            blocks.first(where: { $0.id == id }).map { candidate in
                switch candidate.payload {
                case .model, .advancedModel: return true
                default: return false
                }
            } ?? false
        }
    }

    private func hasDirectAdvancedModelDependency(_ block: Block) -> Bool {
        block.upstreamBlockIDs.contains { id in
            blocks.first(where: { $0.id == id }).map { candidate in
                if case .advancedModel = candidate.payload { return true }
                return false
            } ?? false
        }
    }

    private func isValidRunDependency(_ block: Block, run: AnalysisRun) -> Bool {
        guard (block.state == .stale || run.sourceFingerprint == source.fingerprint),
              block.upstreamBlockIDs == [run.modelBlockID],
              runRecipe(for: run.modelBlockID) != nil,
              transformationAncestors(of: run.modelBlockID) == run.transformationBlockIDs else {
            return false
        }
        return true
    }

    private func isValidComparisonDependency(_ block: Block, comparison: ComparativeEvidence) -> Bool {
        let expectedInputs = [
            comparison.baselineRunBlockID, comparison.candidateRunBlockID,
            comparison.baselineEvidenceBlockID, comparison.candidateEvidenceBlockID,
        ]
        guard block.upstreamBlockIDs == expectedInputs,
              let baselineRunBlock = blocks.first(where: { $0.id == comparison.baselineRunBlockID }),
              let candidateRunBlock = blocks.first(where: { $0.id == comparison.candidateRunBlockID }),
              let baselineEvidenceBlock = blocks.first(where: { $0.id == comparison.baselineEvidenceBlockID }),
              let candidateEvidenceBlock = blocks.first(where: { $0.id == comparison.candidateEvidenceBlockID }),
              case .run(let baselineRun) = baselineRunBlock.payload,
              case .run(let candidateRun) = candidateRunBlock.payload,
              baselineRun.status == .completed, candidateRun.status == .completed,
              case .advancedModel = baselineRun.recipe, case .advancedModel = candidateRun.recipe,
              baselineEvidenceBlock.upstreamBlockIDs == [baselineRunBlock.id],
              candidateEvidenceBlock.upstreamBlockIDs == [candidateRunBlock.id],
              case .advancedEvidence(let baselineEvidence) = baselineEvidenceBlock.payload,
              case .advancedEvidence(let candidateEvidence) = candidateEvidenceBlock.payload else {
            return false
        }
        // Historical comparisons remain readable after upstream edits. Current
        // comparisons must still exactly reflect the preserved inputs.
        guard block.state == .current else { return true }
        guard comparison.sourceFingerprint == source.fingerprint else { return false }
        guard let expected = try? makeComparativeEvidence(
            baselineRun: baselineRun, candidateRun: candidateRun,
            baselineEvidence: baselineEvidence, candidateEvidence: candidateEvidence,
            baselineRunBlockID: baselineRunBlock.id, candidateRunBlockID: candidateRunBlock.id,
            baselineEvidenceBlockID: baselineEvidenceBlock.id,
            candidateEvidenceBlockID: candidateEvidenceBlock.id, at: comparison.capturedAt
        ) else { return false }
        return expected == comparison
    }

    private func hasDirectCompletedRunDependency(_ block: Block) -> Bool {
        block.upstreamBlockIDs.contains { id in
            blocks.first(where: { $0.id == id }).map { candidate in
                guard case .run(let run) = candidate.payload else { return false }
                return run.status == .completed
            } ?? false
        }
    }

    private func hasDirectCompletedAdvancedRunDependency(_ block: Block) -> Bool {
        block.upstreamBlockIDs.contains { id in
            blocks.first(where: { $0.id == id }).map { candidate in
                guard case .run(let run) = candidate.payload,
                      run.status == .completed,
                      case .advancedModel = run.recipe else { return false }
                return true
            } ?? false
        }
    }
}

/// Data-dependent errors when creating or loading a notebook document.
public enum AnalysisDocumentError: Error, Sendable, Hashable, CustomStringConvertible {
    case unsupportedSchema(Int)
    case invalidConfiguration
    case invalidDependency(UUID)
    case invalidEvidence(UUID)

    public var description: String {
        switch self {
        case .unsupportedSchema(let version): return "Unsupported analysis-document schema: \(version)"
        case .invalidConfiguration: return "Invalid analysis-document configuration."
        case .invalidDependency(let id): return "Invalid dependencies for analysis block \(id.uuidString)."
        case .invalidEvidence(let id): return "Invalid evidence snapshot for analysis block \(id.uuidString)."
        }
    }
}

extension AnalysisDocument.Transformation {
    var isValid: Bool {
        func validColumns(_ columns: [String]) -> Bool {
            !columns.isEmpty && Set(columns).count == columns.count
                && columns.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        switch self {
        case .selectColumns(let columns), .dropMissing(let columns): return validColumns(columns)
        case .filterNumeric(let column, _, let value):
            return !column.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.isFinite
        case .naturalLog(let source, let destination):
            return !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && source != destination
        }
    }
}

private func sourceFingerprint(at url: URL) throws -> (value: String, byteCount: Int64) {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash: UInt64 = 14_695_981_039_346_656_037
    var byteCount: Int64 = 0
    while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
        for byte in chunk {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        byteCount += Int64(chunk.count)
    }
    let text = String(hash, radix: 16)
    return (String(repeating: "0", count: max(0, 16 - text.count)) + text, byteCount)
}
