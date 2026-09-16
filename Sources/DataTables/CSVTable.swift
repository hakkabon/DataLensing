// CSVTable.swift
// DataTables
//
// Streaming CSV → typed columns → the `[[Double]]` shape DataLens eats.
//

import Foundation

/// Per-column inferred type.
///
/// Numeric inference downgrades sticky downward: `integer` → `double`.
/// Dates form a parallel track: a column is `.date` exactly when every
/// present value parses as a date and none parses as numeric — any mix
/// of text, numbers, and dates is `.string`. A column with only missing
/// values infers as `.double` (all `.nan`), so it stays fittable
/// downstream.
public enum ColumnType: Sendable, Hashable {
    /// Every present value parses as `Int`.
    case integer
    /// Every present value parses as `Double` (but some fail `Int`).
    case double
    /// Every present value parses as a date (but none as numeric).
    case date
    /// Anything else (text, or a mix of the above).
    case string
}

/// One parsed column: numeric and date columns carry `doubles`, string
/// columns carry `strings`, never both.
public struct CSVColumn: Sendable {
    /// Column name from the header, or `column_<i>` when `hasHeader` is false.
    public let name: String
    /// Type inferred from the present values.
    public let inferredType: ColumnType
    /// One entry per row; missing values are `.nan`. Date columns carry
    /// UTC epoch seconds here (fittable as-is; format via `isDate`).
    /// Non-`nil` exactly when `inferredType` is `.integer`, `.double`,
    /// or `.date`.
    public let doubles: [Double]?
    /// One entry per row; missing values are `nil`, quoted fields verbatim.
    /// Non-`nil` exactly when `inferredType` is `.string`.
    public let strings: [String?]?

    /// Row count (both payloads, when present, share it).
    public var count: Int {
        doubles?.count ?? strings?.count ?? 0
    }
}

/// A parsed CSV table: names plus one typed column per field.
///
/// Queries are name- or index-based; index lookup is positional, name
/// lookup resolves to the *first* column with that name (duplicate header
/// names are kept as parsed, never trapped on).
///
/// Memory note: parsing streams the input (constant-size buffer, never a
/// whole-file `String`), but the parsed table itself is retained — raw
/// cells for string columns, packed `Double`s elsewhere.
public struct CSVTable: Sendable {
    /// Columns in file order.
    public let columns: [CSVColumn]

    /// Column names in file order.
    public var columnNames: [String] {
        columns.map(\.name)
    }

    /// Inferred types in file order.
    public var inferredTypes: [ColumnType] {
        columns.map(\.inferredType)
    }

    /// Number of data rows (header excluded).
    public var rowCount: Int {
        columns.first?.count ?? 0
    }

    // MARK: - Entry points

    /// Parse CSV text (convenience for small inputs and tests).
    ///
    /// The text is still fed through the streaming parser, so results are
    /// identical to `load(contentsOf:)` byte for byte.
    public static func parse(_ content: String, options: CSVOptions = CSVOptions()) throws -> CSVTable {
        let data = Data(content.utf8)
        let stream = InputStream(data: data)
        return try parse(stream: stream, options: options)
    }

    /// Stream a CSV file (the large-dataset path: constant-memory read).
    public static func load(contentsOf url: URL, options: CSVOptions = CSVOptions()) throws -> CSVTable {
        guard let stream = InputStream(url: url) else {
            throw CSVError.emptyInput
        }
        return try parse(stream: stream, options: options)
    }

    // MARK: - Queries

    /// Positional index of the first column with `name`, or `nil`.
    public func columnIndex(of name: String) -> Int? {
        columns.firstIndex(where: { $0.name == name })
    }

    /// Column by name (first match) or position, or `nil` when absent.
    public func column(_ name: String) -> CSVColumn? {
        guard let i = columnIndex(of: name) else { return nil }
        return columns[i]
    }

    /// Column by position, or `nil` when out of range.
    public func column(_ index: Int) -> CSVColumn? {
        guard columns.indices.contains(index) else { return nil }
        return columns[index]
    }

    /// Numeric values for one column (missing → `.nan`), or `nil` when the
    /// column is absent or string-typed.
    public func doubles(forColumn name: String) -> [Double]? {
        column(name)?.doubles
    }

    /// Numeric values for one column by position (missing → `.nan`), or
    /// `nil` when out of range or string-typed.
    public func doubles(forColumn index: Int) -> [Double]? {
        column(index)?.doubles
    }

    /// Raw values for one string column (missing → `nil`), or `nil` when
    /// the column is absent or numeric.
    public func strings(forColumn name: String) -> [String?]? {
        column(name)?.strings
    }

    /// Row-major matrix for the requested columns — the exact shape
    /// DataLens fits take as `trainX` (each inner array is one row).
    ///
    /// Returns `nil` when any name is unknown or names a string column
    /// (data-dependent failure, never a trap).
    public func numericMatrix(columns names: [String]) -> [[Double]]? {
        var indices: [Int] = []
        indices.reserveCapacity(names.count)
        for name in names {
            guard let i = columnIndex(of: name) else { return nil }
            indices.append(i)
        }
        return numericMatrix(columnIndices: indices)
    }

    /// Row-major matrix for the requested positional columns.
    ///
    /// Returns `nil` when any index is out of range or names a string
    /// column.
    public func numericMatrix(columnIndices indices: [Int]) -> [[Double]]? {
        var picked: [[Double]] = []
        picked.reserveCapacity(indices.count)
        for i in indices {
            guard let values = column(i)?.doubles else { return nil }
            picked.append(values)
        }
        let n = picked.first?.count ?? 0
        var rows: [[Double]] = []
        rows.reserveCapacity(n)
        for r in 0..<n {
            var row: [Double] = []
            row.reserveCapacity(picked.count)
            for c in picked {
                row.append(c[r])
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - Driver (internal)

    static func parse(stream: InputStream, options: CSVOptions) throws -> CSVTable {
        let feeder = ByteFeeder(stream: stream, chunkSize: options.chunkSize)
        var parser = CSVRecordParser(
            feeder: feeder, delimiter: options.delimiter,
            trimsWhitespace: options.trimsWhitespace
        )
        defer { parser.close() }
        guard let first = try parser.nextRow() else {
            throw CSVError.emptyInput
        }
        let firstLine = parser.lastRecordLine
        let names: [String]
        let width = first.count
        var pendingDataRow: [String]?
        if options.hasHeader {
            names = first
        } else {
            names = (1...width).map { "column_\($0)" }
            pendingDataRow = first
        }
        var raws = [[String?]](repeating: [], count: width)
        var kinds = [ColumnType](repeating: .integer, count: width)
        // Tracks "no numeric value seen yet" per column: a date votes
        // `.date` only on a numerics-free column; any mix falls to `.string`.
        var sawNumeric = [Bool](repeating: false, count: width)

        func ingest(_ record: [String], line: Int) throws {
            guard record.count == width else {
                throw CSVError.raggedRow(line: line, expected: width, found: record.count)
            }
            for (i, text) in record.enumerated() {
                if options.missingMarkers.contains(text) {
                    raws[i].append(nil)
                    continue
                }
                raws[i].append(text)
                if kinds[i] == .string {
                    continue
                } else if Int(text) != nil {
                    if kinds[i] == .date { kinds[i] = .string; continue }
                    sawNumeric[i] = true
                    continue  // still integer-or-better
                } else if Double(text) != nil {
                    if kinds[i] == .date { kinds[i] = .string; continue }
                    sawNumeric[i] = true
                    kinds[i] = .double
                } else if CSVDate.epochSeconds(text) != nil, !sawNumeric[i] {
                    kinds[i] = .date
                } else {
                    kinds[i] = .string
                }
            }
        }

        if let firstData = pendingDataRow {
            try ingest(firstData, line: firstLine)
        }
        while let record = try parser.nextRow() {
            try ingest(record, line: parser.lastRecordLine)
        }

        var built: [CSVColumn] = []
        built.reserveCapacity(width)
        for i in 0..<width {
            // No present value ever voted: report `.double` (all `.nan`)
            // so the column stays fittable downstream.
            if kinds[i] == .integer, raws[i].allSatisfy({ $0 == nil }) {
                kinds[i] = .double
            }
            switch kinds[i] {
            case .integer, .double:
                let values = raws[i].map { cell -> Double in
                    guard let cell else { return .nan }
                    return Double(cell) ?? .nan
                }
                built.append(CSVColumn(name: names[i], inferredType: kinds[i], doubles: values, strings: nil))
            case .date:
                let values = raws[i].map { cell -> Double in
                    guard let cell, let epoch = CSVDate.epochSeconds(cell) else { return .nan }
                    return epoch
                }
                built.append(CSVColumn(name: names[i], inferredType: .date, doubles: values, strings: nil))
            case .string:
                built.append(CSVColumn(name: names[i], inferredType: .string, doubles: nil, strings: raws[i]))
            }
        }
        return CSVTable(columns: built)
    }
}
