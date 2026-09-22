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
    public static let currentSchemaVersion = 5

    public let id: UUID
    public let schemaVersion: Int
    public private(set) var title: String
    public private(set) var source: Source
    public let createdAt: Date
    public private(set) var updatedAt: Date
    /// Blocks appear in dependency order; an input can only name an earlier block.
    public private(set) var blocks: [Block]

    public init(
        id: UUID = UUID(), title: String, source: Source, blocks: [Block] = [],
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) throws {
        self.id = id
        schemaVersion = Self.currentSchemaVersion
        self.title = title
        self.source = source
        self.blocks = blocks
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

    /// A persisted chart-model recipe derived from a replayable workbench session.
    public struct ModelRecipe: Codable, Sendable, Hashable {
        public let predictor: String
        public let response: String
        public let secondPredictor: String?
        /// Raw value retained for forward-compatible decoding and validation.
        public let smoother: String
        public let tuning: WorkbenchTuning
        public let validationConfiguration: ValidationConfiguration

        public init(
            predictor: String, response: String, secondPredictor: String? = nil,
            smoother: SmootherChoice, tuning: WorkbenchTuning,
            validationConfiguration: ValidationConfiguration
        ) throws {
            guard Self.isValidColumnName(predictor), Self.isValidColumnName(response),
                  predictor != response,
                  secondPredictor.map(Self.isValidColumnName) ?? true,
                  secondPredictor != predictor, secondPredictor != response,
                  tuning.isValid else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            self.predictor = predictor
            self.response = response
            self.secondPredictor = secondPredictor
            self.smoother = smoother.rawValue
            self.tuning = tuning
            self.validationConfiguration = validationConfiguration
        }

        public init(session: WorkbenchSession) throws {
            try self.init(
                predictor: session.predictor, response: session.response,
                secondPredictor: session.secondPredictor, smoother: session.smootherChoice,
                tuning: session.tuning, validationConfiguration: session.validationConfiguration
            )
        }

        public var smootherChoice: SmootherChoice? { SmootherChoice(rawValue: smoother) }

        fileprivate var isValid: Bool {
            Self.isValidColumnName(predictor) && Self.isValidColumnName(response)
                && predictor != response && secondPredictor.map(Self.isValidColumnName) != false
                && secondPredictor != predictor && secondPredictor != response
                && smootherChoice != nil && tuning.isValid
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
        /// `nil` means stability resampling was intentionally not requested.
        public let bootstrapConfiguration: BootstrapConfiguration?
        /// Prediction rows for bootstrap stability intervals, in predictor order.
        public let stabilityQueries: [[Double]]

        public init(
            predictorColumns: [String], responseColumn: String,
            specification: StatisticalModelSpecification,
            validationConfiguration: ValidationConfiguration,
            bootstrapConfiguration: BootstrapConfiguration? = nil,
            stabilityQueries: [[Double]] = []
        ) throws {
            guard !predictorColumns.isEmpty,
                  Set(predictorColumns).count == predictorColumns.count,
                  predictorColumns.allSatisfy(Self.isValidColumnName),
                  Self.isValidColumnName(responseColumn),
                  !predictorColumns.contains(responseColumn),
                  validationConfiguration.specification == specification,
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
            self.bootstrapConfiguration = bootstrapConfiguration
            self.stabilityQueries = stabilityQueries
        }

        fileprivate var isValid: Bool {
            !predictorColumns.isEmpty && Set(predictorColumns).count == predictorColumns.count
                && predictorColumns.allSatisfy(Self.isValidColumnName)
                && Self.isValidColumnName(responseColumn) && !predictorColumns.contains(responseColumn)
                && validationConfiguration.specification == specification
                && (bootstrapConfiguration == nil || bootstrapConfiguration?.specification == specification)
                && stabilityQueries.allSatisfy {
                    $0.count == predictorColumns.count && $0.allSatisfy(\.isFinite)
                }
                && (bootstrapConfiguration == nil || !stabilityQueries.isEmpty)
        }

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

        fileprivate var bootstrapSeed: UInt64? {
            guard case .advancedModel(let recipe) = self else { return nil }
            return recipe.bootstrapConfiguration?.seed
        }

        fileprivate var requestedSolverPreference: MultivariateSolverPreference? {
            guard case .advancedModel(let recipe) = self else { return nil }
            return recipe.specification.multivariate?.solverPreference
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
            retainedObservationCount: Int? = nil, failureDescription: String? = nil
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
                  requestedSolverPreference == recipe.requestedSolverPreference else { return false }
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
            retainedObservationCount: Int, startedAt: Date, completedAt: Date = Date()
        ) throws -> AnalysisRun {
            try make(
                in: document, modelBlockID: modelBlockID, startedAt: startedAt,
                completedAt: completedAt, status: .completed,
                retainedObservationCount: retainedObservationCount, failureDescription: nil
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
                retainedObservationCount: nil, failureDescription: description
            )
        }

        private static func make(
            in document: AnalysisDocument, modelBlockID: UUID,
            startedAt: Date, completedAt: Date, status: AnalysisRunStatus,
            retainedObservationCount: Int?, failureDescription: String?
        ) throws -> AnalysisRun {
            guard let recipe = document.runRecipe(for: modelBlockID) else {
                throw AnalysisDocumentError.invalidDependency(modelBlockID)
            }
            return try AnalysisRun(
                sourceFingerprint: document.source.fingerprint, modelBlockID: modelBlockID,
                transformationBlockIDs: document.transformationAncestors(of: modelBlockID),
                recipe: recipe, startedAt: startedAt, completedAt: completedAt,
                status: status, retainedObservationCount: retainedObservationCount,
                failureDescription: failureDescription
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
        case model(ModelRecipe)
        case advancedModel(AdvancedModelRecipe)
        case run(AnalysisRun)
        case evidence(EvidenceSnapshot)
        case advancedEvidence(AdvancedModelEvidence)
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
            case .model(let recipe): return recipe.isValid
            case .advancedModel(let recipe): return recipe.isValid
            case .run(let run): return run.isValid
            case .evidence(let evidence): return evidence.isValid
            case .advancedEvidence(let evidence): return evidence.isValid
            case .figure(let figure): return figure.isValid
            case .note(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    /// Append a block after its dependencies. No result is recomputed implicitly.
    public mutating func append(_ block: Block, at date: Date = Date()) throws {
        blocks.append(block)
        updatedAt = date
        do {
            try validate()
        } catch {
            blocks.removeLast()
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

    private func runRecipe(for modelBlockID: UUID) -> AnalysisRunRecipe? {
        guard let block = blocks.first(where: { $0.id == modelBlockID }) else { return nil }
        switch block.payload {
        case .model(let recipe): return .model(recipe)
        case .advancedModel(let recipe): return .advancedModel(recipe)
        default: return nil
        }
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
        case id, schemaVersion, title, source, createdAt, updatedAt, blocks
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
        guard (1...Self.currentSchemaVersion).contains(decodedSchemaVersion) else {
            throw AnalysisDocumentError.unsupportedSchema(decodedSchemaVersion)
        }
        // Versions 1 and 2 predate advanced model/evidence blocks; version 3
        // predates native sparse-execution evidence; version 4 predates
        // explicit immutable run records. Their
        // existing representation is unchanged, so normalize on open and
        // write the upgraded schema only when the host later saves.
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
              Set(blocks.map(\.id)).count == blocks.count else {
            throw AnalysisDocumentError.invalidConfiguration
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
