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
    public static let currentSchemaVersion = 1

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

    public enum BlockPayload: Codable, Sendable, Hashable {
        case transformation(Transformation)
        case model(ModelRecipe)
        case evidence(EvidenceSnapshot)
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
            case .evidence(let evidence): return evidence.isValid
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
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        title = try values.decode(String.self, forKey: .title)
        source = try values.decode(Source.self, forKey: .source)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        blocks = try values.decode([Block].self, forKey: .blocks)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw AnalysisDocumentError.unsupportedSchema(schemaVersion)
        }
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
                guard evidence.sourceFingerprint == source.fingerprint,
                      block.upstreamBlockIDs.contains(where: { id in
                          blocks.first(where: { $0.id == id }).map { block in
                              if case .model = block.payload { return true }
                              return false
                          } ?? false
                      }) else {
                    throw AnalysisDocumentError.invalidEvidence(block.id)
                }
            }
            preceding.insert(block.id)
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

private extension AnalysisDocument.Transformation {
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
