import Foundation

/// A frozen, portable publication package derived from an accepted analysis
/// document.
///
/// A publication is deliberately not another mutable notebook state. It
/// copies the reader-facing conclusions, terminal experiment checkpoints,
/// review outcomes, and observed numerical environments into a small Codable
/// value that can be shared independently of the source file. It contains no
/// source rows, absolute paths, credentials, rendered pixels, or executable
/// code. Editing its source document therefore cannot silently revise an
/// already exported publication.
public struct AnalysisPublication: Codable, Sendable, Hashable, Identifiable {
    public static let currentSchemaVersion = 1

    public enum Error: Swift.Error, Sendable, Equatable, LocalizedError {
        /// Publication is an explicit closure step, not a substitute for the
        /// document review workflow.
        case documentIsNotAccepted
        /// A publication must contain an accountable conclusion or a terminal
        /// experiment record; raw model output alone is not a publication.
        case noPublishableEvidence
        case invalidConfiguration
        case unsupportedSchemaVersion(Int)

        public var errorDescription: String? {
            switch self {
            case .documentIsNotAccepted:
                return "Accept the current document before creating a publication snapshot."
            case .noPublishableEvidence:
                return "Record a current evidence synthesis or a completed/stopped experiment checkpoint before publishing."
            case .invalidConfiguration:
                return "The publication snapshot is incomplete or invalid."
            case .unsupportedSchemaVersion(let version):
                return "Publication schema version \(version) is not supported."
            }
        }
    }

    /// One terminal review outcome retained with the publication. Author
    /// labels remain unauthenticated display text, just as in the notebook.
    public struct ReviewFinding: Codable, Sendable, Hashable, Identifiable {
        public let id: UUID
        public let author: String
        public let body: String
        public let targetBlockID: UUID?
        public let severity: AnalysisDocument.DocumentReview.Finding.Severity
        public let status: AnalysisDocument.DocumentReview.Finding.Status
        public let resolution: String
        public let createdAt: Date
        public let resolvedAt: Date

        fileprivate init(_ finding: AnalysisDocument.DocumentReview.Finding) throws {
            guard finding.status != .open,
                  let resolution = finding.resolution,
                  let resolvedAt = finding.resolvedAt else {
                throw Error.invalidConfiguration
            }
            id = finding.id
            author = finding.author
            body = finding.body
            targetBlockID = finding.targetBlockID
            severity = finding.severity
            status = finding.status
            self.resolution = resolution
            createdAt = finding.createdAt
            self.resolvedAt = resolvedAt
        }

        fileprivate var isValid: Bool {
            !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !resolution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && status != .open && resolvedAt >= createdAt
        }
    }

    /// A current analyst conclusion, copied with its direct evidence keys.
    public struct Synthesis: Codable, Sendable, Hashable, Identifiable {
        public let id: UUID
        public let title: String
        public let capturedAt: Date
        public let question: String
        public let conclusion: String
        public let assessment: AnalysisDocument.EvidenceSynthesis.Assessment
        public let caveats: [String]
        /// Stable source-document keys, retained for an audit trail rather
        /// than as a promise that the recipient owns the notebook file.
        public let evidenceBlockIDs: [UUID]

        fileprivate init(block: AnalysisDocument.Block, value: AnalysisDocument.EvidenceSynthesis) {
            id = block.id
            title = block.title
            capturedAt = value.capturedAt
            question = value.question
            conclusion = value.conclusion
            assessment = value.assessment
            caveats = value.caveats
            evidenceBlockIDs = value.evidenceBlockIDs
        }

        fileprivate var isValid: Bool {
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !conclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !caveats.isEmpty && caveats.allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                && !evidenceBlockIDs.isEmpty && Set(evidenceBlockIDs).count == evidenceBlockIDs.count
        }
    }

    /// A copied terminal protocol checkpoint. A checkpoint is shown as a
    /// record of what happened, never as a claim that a stopped study supports
    /// the same inference as a completed one.
    public struct Experiment: Codable, Sendable, Hashable, Identifiable {
        public let id: UUID
        public let title: String
        public let capturedAt: Date
        public let protocolBlockID: UUID
        public let protocolTitle: String
        public let question: String
        public let primaryEndpoint: String
        public let decisionRule: String
        public let armLabels: [String]
        public let status: AnalysisDocument.ExperimentCheckpoint.Status
        public let armRunCount: Int
        public let synthesisBlockID: UUID?
        public let deviationNote: String?
        public let nextStep: String

        fileprivate init(
            block: AnalysisDocument.Block, checkpoint: AnalysisDocument.ExperimentCheckpoint,
            protocolBlock: AnalysisDocument.Block, protocolValue: AnalysisDocument.ExperimentProtocol
        ) {
            id = block.id
            title = block.title
            capturedAt = checkpoint.capturedAt
            protocolBlockID = checkpoint.protocolBlockID
            protocolTitle = protocolBlock.title
            question = protocolValue.question
            primaryEndpoint = protocolValue.primaryEndpoint
            decisionRule = protocolValue.decisionRule
            armLabels = protocolValue.arms.map(\.label)
            status = checkpoint.status
            armRunCount = checkpoint.armRuns.count
            synthesisBlockID = checkpoint.synthesisBlockID
            deviationNote = checkpoint.deviationNote
            nextStep = checkpoint.nextStep
        }

        fileprivate var isValid: Bool {
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !protocolTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !primaryEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !decisionRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && armLabels.count >= 2
                && armLabels.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                && Set(armLabels).count == armLabels.count
                && armRunCount > 0
                && !nextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (status != .stopped || deviationNote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        }
    }

    public let id: UUID
    public let schemaVersion: Int
    public let title: String
    /// Optional publication-specific editorial context. It is not evidence and
    /// does not change the included statistical conclusions.
    public let abstract: String
    public let publishedAt: Date
    public let sourceDocumentID: UUID
    public let sourceDocumentTitle: String
    public let sourceDocumentUpdatedAt: Date
    /// The source record is privacy-preserving and contains no path or rows.
    public let source: AnalysisDocument.Source
    public let reviewFindings: [ReviewFinding]
    public let syntheses: [Synthesis]
    public let experiments: [Experiment]
    /// Distinct environments in source-document run order. An empty list is
    /// honest: it means this publication has no captured run environment.
    public let numericalEnvironments: [AnalysisDocument.ExecutionEnvironment]

    private init(
        id: UUID = UUID(), title: String, abstract: String, publishedAt: Date,
        sourceDocumentID: UUID, sourceDocumentTitle: String, sourceDocumentUpdatedAt: Date,
        source: AnalysisDocument.Source, reviewFindings: [ReviewFinding], syntheses: [Synthesis],
        experiments: [Experiment], numericalEnvironments: [AnalysisDocument.ExecutionEnvironment]
    ) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let abstract = abstract.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              !sourceDocumentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(reviewFindings.map(\.id)).count == reviewFindings.count,
              reviewFindings.allSatisfy(\.isValid),
              Set(syntheses.map(\.id)).count == syntheses.count,
              syntheses.allSatisfy(\.isValid),
              Set(experiments.map(\.id)).count == experiments.count,
              experiments.allSatisfy(\.isValid),
              numericalEnvironments.allSatisfy(Self.environmentIsValid),
              !syntheses.isEmpty || !experiments.isEmpty else {
            throw Error.invalidConfiguration
        }
        self.id = id
        schemaVersion = Self.currentSchemaVersion
        self.title = title
        self.abstract = abstract
        self.publishedAt = publishedAt
        self.sourceDocumentID = sourceDocumentID
        self.sourceDocumentTitle = sourceDocumentTitle
        self.sourceDocumentUpdatedAt = sourceDocumentUpdatedAt
        self.source = source
        self.reviewFindings = reviewFindings
        self.syntheses = syntheses
        self.experiments = experiments
        self.numericalEnvironments = numericalEnvironments
    }

    /// Freeze an accepted, fully current notebook into a portable package.
    /// This operation never mutates the document and has no network side
    /// effects; a host chooses whether and where to export the result.
    public static func make(
        from document: AnalysisDocument, title: String? = nil, abstract: String = "",
        publishedAt: Date = Date()
    ) throws -> AnalysisPublication {
        let summary = document.reviewSummary
        guard summary.readiness == .accepted, summary.canAccept else {
            throw Error.documentIsNotAccepted
        }

        let syntheses = document.blocks.compactMap { block -> Synthesis? in
            guard block.state == .current, case .synthesis(let value) = block.payload else { return nil }
            return Synthesis(block: block, value: value)
        }
        let protocols: [UUID: (AnalysisDocument.Block, AnalysisDocument.ExperimentProtocol)] = Dictionary(
            uniqueKeysWithValues: document.blocks.compactMap { block in
            guard case .experimentProtocol(let value) = block.payload else { return nil }
            return (block.id, (block, value))
        })
        let experiments = document.blocks.compactMap { block -> Experiment? in
            guard block.state == .current,
                  case .experimentCheckpoint(let checkpoint) = block.payload,
                  checkpoint.status != .inProgress,
                  let protocolRecord = protocols[checkpoint.protocolBlockID] else { return nil }
            return Experiment(
                block: block, checkpoint: checkpoint, protocolBlock: protocolRecord.0,
                protocolValue: protocolRecord.1
            )
        }
        guard !syntheses.isEmpty || !experiments.isEmpty else {
            throw Error.noPublishableEvidence
        }

        var environments: [AnalysisDocument.ExecutionEnvironment] = []
        for block in document.blocks {
            guard block.state == .current, case .run(let run) = block.payload,
                  let environment = run.executionEnvironment,
                  !environments.contains(environment) else { continue }
            environments.append(environment)
        }
        return try AnalysisPublication(
            title: title ?? document.title, abstract: abstract, publishedAt: publishedAt,
            sourceDocumentID: document.id, sourceDocumentTitle: document.title,
            sourceDocumentUpdatedAt: document.updatedAt, source: document.source,
            reviewFindings: try document.review.findings.map(ReviewFinding.init),
            syntheses: syntheses, experiments: experiments, numericalEnvironments: environments
        )
    }

    /// Encodes a deterministic JSON package suitable for version control,
    /// review attachments, and future importers.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Decode a publication package while rejecting a future representation
    /// that this version cannot interpret safely.
    public init(jsonData: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(AnalysisPublication.self, from: jsonData)
        guard value.schemaVersion == Self.currentSchemaVersion else {
            throw Error.unsupportedSchemaVersion(value.schemaVersion)
        }
        try Self.validate(value)
        self = value
    }

    private static func validate(_ value: AnalysisPublication) throws {
        guard !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.sourceDocumentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(value.reviewFindings.map(\.id)).count == value.reviewFindings.count,
              value.reviewFindings.allSatisfy(\.isValid),
              Set(value.syntheses.map(\.id)).count == value.syntheses.count,
              value.syntheses.allSatisfy(\.isValid),
              Set(value.experiments.map(\.id)).count == value.experiments.count,
              value.experiments.allSatisfy(\.isValid),
              value.numericalEnvironments.allSatisfy(Self.environmentIsValid),
              !value.syntheses.isEmpty || !value.experiments.isEmpty else {
            throw Error.invalidConfiguration
        }
    }

    private static func environmentIsValid(_ environment: AnalysisDocument.ExecutionEnvironment) -> Bool {
        [
            environment.hostBuildIdentifier, environment.swiftLanguageVersion, environment.platform,
            environment.architecture, environment.swiftDataLensVersion,
            environment.swiftNumericCoreVersion, environment.rustNumericCoreVersion,
            environment.resolverFingerprint,
        ].allSatisfy { !$0.isEmpty }
    }

    /// A dependency-free reader summary. Markdown is intentionally generated
    /// from the frozen package rather than the live notebook.
    public func markdown() -> String {
        var lines = ["# \(title)", "", "Published: \(Self.timestamp(publishedAt))"]
        if !abstract.isEmpty {
            lines += ["", abstract]
        }
        lines += [
            "", "## Review", "",
            "Accepted source notebook: \(sourceDocumentTitle)",
            "- Source: \(source.displayName) (\(source.inputObservationCount) observations)",
            "- Source fingerprint: `\(source.fingerprint)`",
            "- Closed review findings: \(reviewFindings.count)"
        ]
        if !reviewFindings.isEmpty {
            lines += ["", "### Review outcomes"]
            for finding in reviewFindings {
                lines += [
                    "", "- **\(finding.severity.rawValue.capitalized), \(finding.status.rawValue):** \(finding.body)",
                    "  - \(finding.author), \(Self.timestamp(finding.resolvedAt)): \(finding.resolution)"
                ]
            }
        }
        if !syntheses.isEmpty {
            lines += ["", "## Evidence syntheses"]
            for synthesis in syntheses {
                lines += [
                    "", "### \(synthesis.title)", "",
                    "**Question:** \(synthesis.question)", "",
                    "**Conclusion:** \(synthesis.conclusion)", "",
                    "**Assessment:** \(synthesis.assessment.rawValue.capitalized)", "",
                    "**Caveats:**"
                ]
                lines += synthesis.caveats.map { "- \($0)" }
            }
        }
        if !experiments.isEmpty {
            lines += ["", "## Experiment checkpoints"]
            for experiment in experiments {
                lines += [
                    "", "### \(experiment.protocolTitle) — \(experiment.status.rawValue)", "",
                    "**Question:** \(experiment.question)", "",
                    "**Primary endpoint:** \(experiment.primaryEndpoint)", "",
                    "**Arms:** \(experiment.armLabels.joined(separator: ", "))",
                    "",
                    "**Next step:** \(experiment.nextStep)"
                ]
                if let deviation = experiment.deviationNote {
                    lines += ["", "**Deviation:** \(deviation)"]
                }
            }
        }
        lines += ["", "## Numerical provenance"]
        if numericalEnvironments.isEmpty {
            lines += ["", "No execution environment was captured in a current run."]
        } else {
            for environment in numericalEnvironments {
                lines += [
                    "", "- \(environment.platform) / \(environment.architecture): DataLens \(environment.swiftDataLensVersion), NumericCore \(environment.swiftNumericCoreVersion), Rust-NumericCore \(environment.rustNumericCoreVersion)"
                ]
            }
        }
        lines += [
            "", "## Publication scope", "",
            "This is a frozen export of an accepted numerical-statistics notebook. It contains no source rows or executable code; source-document block identifiers are retained only for audit."
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}
