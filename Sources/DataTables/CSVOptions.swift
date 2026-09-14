// CSVOptions.swift
// DataTables
//
// Dial knobs for the streaming CSV reader. Foundation-only.

import Foundation

/// Dial knobs for the streaming CSV reader.
///
/// All settings are performance- or format-level: none of them changes
/// the "shape" contract (header → names, missing → `.nan`, numeric
/// columns → `[Double]`).
public struct CSVOptions: Sendable, Hashable {
    /// Field separator. Must be ASCII and must not be `"`, `\r`, or `\n`.
    public var delimiter: Character
    /// When true, the first non-blank row supplies `columnNames`.
    /// When false, names are generated as `column_1`, `column_2`, ….
    public var hasHeader: Bool
    /// Field texts that count as missing (compared after optional
    /// trimming, exact case-sensitive match). Missing values surface as
    /// `nil` raw cells and as `.nan` in numeric columns — the value
    /// DataLens `droppingMissing` drops while `keptIndices` stays
    /// joinable.
    public var missingMarkers: Set<String>
    /// Trim leading/trailing whitespace of *unquoted* fields before
    /// missing-marker comparison and numeric parsing. Quoted fields are
    /// always preserved verbatim.
    public var trimsWhitespace: Bool
    /// Stream buffer size in bytes. Affects read chunking only — never
    /// parse results. Exposed so tests can pin tiny buffers and prove
    /// split-boundary independence.
    public var chunkSize: Int

    /// Create CSV options, validating programmer-level invariants.
    public init(
        delimiter: Character = ",",
        hasHeader: Bool = true,
        missingMarkers: Set<String> = ["", "NA", "NaN"],
        trimsWhitespace: Bool = true,
        chunkSize: Int = 64 * 1024
    ) {
        precondition(delimiter.isASCII, "CSV delimiter must be ASCII")
        precondition(
            delimiter != "\"" && delimiter != "\r" && delimiter != "\n",
            "CSV delimiter must not be a quote or line break"
        )
        precondition(chunkSize > 0, "CSV chunkSize must be positive")
        self.delimiter = delimiter
        self.hasHeader = hasHeader
        self.missingMarkers = missingMarkers
        self.trimsWhitespace = trimsWhitespace
        self.chunkSize = chunkSize
    }
}

/// Data-dependent CSV failures. Thrown (never trapped): ragged rows,
/// broken quoting, and empty input are properties of the file, not the
/// program.
public enum CSVError: Error, Sendable, Hashable, CustomStringConvertible {
    /// No rows at all (empty file, or only blank lines).
    case emptyInput
    /// A row whose field count differs from the first row/header.
    case raggedRow(line: Int, expected: Int, found: Int)
    /// End of input inside a quoted field.
    case unterminatedQuote(line: Int)
    /// A non-delimiter, non-line-break character right after a closing quote.
    case unexpectedCharacterAfterQuote(line: Int)
    /// Field bytes that are not valid UTF-8.
    case invalidUTF8(line: Int)

    public var description: String {
        switch self {
        case .emptyInput:
            return "CSV has no rows"
        case .raggedRow(let line, let expected, let found):
            return "CSV line \(line): expected \(expected) fields, found \(found)"
        case .unterminatedQuote(let line):
            return "CSV line \(line): unterminated quoted field"
        case .unexpectedCharacterAfterQuote(let line):
            return "CSV line \(line): expected delimiter or line break after closing quote"
        case .invalidUTF8(let line):
            return "CSV line \(line): field is not valid UTF-8"
        }
    }
}
