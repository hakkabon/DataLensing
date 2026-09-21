import DataTables
import Foundation

/// A replayed table with source-row provenance retained through every operation.
///
/// This is an execution value, not a second CSV format. Numeric missing values
/// remain `.nan`; text missing values remain `nil`. `sourceRowIndices` always
/// addresses the original source-table rows, enabling later fitted values,
/// validation predictions, and evidence to join back to the import.
public struct ReplayedTable: Sendable {
    public enum Column: Sendable {
        case numeric(name: String, values: [Double])
        case text(name: String, values: [String?])

        public var name: String {
            switch self {
            case .numeric(let name, _), .text(let name, _): return name
            }
        }

        public var count: Int {
            switch self {
            case .numeric(_, let values): return values.count
            case .text(_, let values): return values.count
            }
        }
    }

    public private(set) var columns: [Column]
    public private(set) var sourceRowIndices: [Int]

    /// Names in replay order, including derived columns.
    public var columnNames: [String] { columns.map(\.name) }
    public var rowCount: Int { sourceRowIndices.count }

    public init(table: CSVTable) throws {
        let columns = table.columns.map { column -> Column in
            if let values = column.doubles { return .numeric(name: column.name, values: values) }
            return .text(name: column.name, values: column.strings ?? [])
        }
        try self.init(columns: columns, sourceRowIndices: Array(0..<table.rowCount))
    }

    public init(columns: [Column], sourceRowIndices: [Int]) throws {
        guard !columns.isEmpty, Set(columns.map(\.name)).count == columns.count,
              columns.allSatisfy({ $0.count == sourceRowIndices.count }),
              sourceRowIndices.allSatisfy({ $0 >= 0 }) else {
            throw AnalysisTransformationError.invalidTable
        }
        self.columns = columns
        self.sourceRowIndices = sourceRowIndices
    }

    /// Numeric values for a retained or derived column, or `nil` for text/unknown columns.
    public func numericValues(forColumn name: String) -> [Double]? {
        guard let column = columns.first(where: { $0.name == name }) else { return nil }
        if case .numeric(_, let values) = column { return values }
        return nil
    }

    /// Text values for a retained column, or `nil` for numeric/unknown columns.
    public func textValues(forColumn name: String) -> [String?]? {
        guard let column = columns.first(where: { $0.name == name }) else { return nil }
        if case .text(_, let values) = column { return values }
        return nil
    }

    fileprivate mutating func apply(_ transformation: AnalysisDocument.Transformation) throws {
        switch transformation {
        case .selectColumns(let names):
            guard names.allSatisfy({ columnIndex(named: $0) != nil }) else {
                throw AnalysisTransformationError.unknownColumn
            }
            columns = try names.map { name in
                guard let index = columnIndex(named: name) else {
                    throw AnalysisTransformationError.unknownColumn
                }
                return columns[index]
            }
        case .dropMissing(let names):
            let selected = try names.map(columnIndexOrThrow)
            retainRows(indices: (0..<rowCount).filter { row in
                selected.allSatisfy { columns[$0].isPresent(at: row) }
            })
        case .filterNumeric(let name, let comparison, let value):
            guard let values = numericValues(forColumn: name) else {
                throw columns.contains(where: { $0.name == name })
                    ? AnalysisTransformationError.nonNumericColumn(name)
                    : AnalysisTransformationError.unknownColumn
            }
            retainRows(indices: values.indices.filter { values[$0].isFinite && comparison.matches(values[$0], value) })
        case .naturalLog(let source, let destination):
            guard columnIndex(named: destination) == nil else {
                throw AnalysisTransformationError.duplicateColumn(destination)
            }
            guard let values = numericValues(forColumn: source) else {
                throw columns.contains(where: { $0.name == source })
                    ? AnalysisTransformationError.nonNumericColumn(source)
                    : AnalysisTransformationError.unknownColumn
            }
            retainRows(indices: values.indices.filter { values[$0].isFinite && values[$0] > 0 })
            guard let retained = numericValues(forColumn: source) else {
                throw AnalysisTransformationError.unknownColumn
            }
            columns.append(.numeric(name: destination, values: retained.map(log)))
        }
    }

    private func columnIndex(named name: String) -> Int? {
        columns.firstIndex(where: { $0.name == name })
    }

    private func columnIndexOrThrow(_ name: String) throws -> Int {
        guard let index = columnIndex(named: name) else { throw AnalysisTransformationError.unknownColumn }
        return index
    }

    private mutating func retainRows(indices: [Int]) {
        sourceRowIndices = indices.map { sourceRowIndices[$0] }
        columns = columns.map { column in
            switch column {
            case .numeric(let name, let values):
                return .numeric(name: name, values: indices.map { values[$0] })
            case .text(let name, let values):
                return .text(name: name, values: indices.map { values[$0] })
            }
        }
    }
}

/// Applies saved notebook transformations to a parsed CSV source.
public enum AnalysisTransformationExecutor {
    public struct ReplayResult: Sendable {
        public let table: ReplayedTable
        /// Transformation block IDs actually traversed to reach the target.
        public let appliedBlockIDs: [UUID]
    }

    /// Replay a known ordered sequence of transformations against an already parsed table.
    public static func replay(
        _ transformations: [AnalysisDocument.Transformation], on table: CSVTable
    ) throws -> ReplayedTable {
        var replayed = try ReplayedTable(table: table)
        for transformation in transformations {
            guard transformation.isValid else { throw AnalysisTransformationError.invalidTransformation }
            try replayed.apply(transformation)
        }
        return replayed
    }

    /// Replay only the transformation ancestors of `targetBlockID`.
    ///
    /// The source file is parsed and fingerprinted before any transformation is
    /// applied. A changed source must be acknowledged with
    /// ``AnalysisDocument/updateSource(_:at:)`` rather than silently producing
    /// evidence for a different file under an old document identity.
    public static func replay(
        document: AnalysisDocument, sourceURL: URL, through targetBlockID: UUID
    ) throws -> ReplayResult {
        guard document.blocks.contains(where: { $0.id == targetBlockID }) else {
            throw AnalysisTransformationError.unknownBlock(targetBlockID)
        }
        let sourceTable = try CSVTable.load(contentsOf: sourceURL)
        let actualSource = try AnalysisDocument.Source.make(from: sourceURL, table: sourceTable)
        guard actualSource.fingerprint == document.source.fingerprint else {
            throw AnalysisTransformationError.sourceChanged
        }

        var needed: Set<UUID> = [targetBlockID]
        for block in document.blocks.reversed() where needed.contains(block.id) {
            needed.formUnion(block.upstreamBlockIDs)
        }
        let transforms = document.blocks.compactMap { block -> (UUID, AnalysisDocument.Transformation)? in
            guard needed.contains(block.id), case .transformation(let transformation) = block.payload else {
                return nil
            }
            return (block.id, transformation)
        }
        let replayed = try replay(transforms.map(\.1), on: sourceTable)
        return ReplayResult(table: replayed, appliedBlockIDs: transforms.map(\.0))
    }
}

/// Data-dependent replay errors presented without exposing parser internals.
public enum AnalysisTransformationError: Error, Sendable, Hashable, CustomStringConvertible {
    case invalidTable
    case invalidTransformation
    case unknownColumn
    case nonNumericColumn(String)
    case duplicateColumn(String)
    case unknownBlock(UUID)
    case sourceChanged

    public var description: String {
        switch self {
        case .invalidTable: return "Invalid replayed table."
        case .invalidTransformation: return "Invalid saved transformation."
        case .unknownColumn: return "A saved transformation names an unknown column."
        case .nonNumericColumn(let name): return "Transformation requires numeric column '\(name)'."
        case .duplicateColumn(let name): return "Derived column '\(name)' already exists."
        case .unknownBlock(let id): return "Unknown analysis block \(id.uuidString)."
        case .sourceChanged: return "The selected source data differs from the analysis document."
        }
    }
}

private extension ReplayedTable.Column {
    func isPresent(at index: Int) -> Bool {
        switch self {
        case .numeric(_, let values): return values[index].isFinite
        case .text(_, let values): return values[index] != nil
        }
    }
}

private extension AnalysisDocument.NumericComparison {
    func matches(_ lhs: Double, _ rhs: Double) -> Bool {
        switch self {
        case .lessThan: return lhs < rhs
        case .lessThanOrEqual: return lhs <= rhs
        case .equal: return lhs == rhs
        case .greaterThanOrEqual: return lhs >= rhs
        case .greaterThan: return lhs > rhs
        }
    }
}
