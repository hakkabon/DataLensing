// LoadChart.swift
// DataLensing
//
// File → fit → chart in one call: the engine↔app contract behind a URL.
// The viewer (and any future UI) imports only DataLensing; DataTables
// and DataLens stay behind this seam.

import DataLens
import DataTables
import Foundation

/// Data-dependent failures of `loadChart(from:)` (thrown, never trapped).
public enum ChartLoadError: Error, Sendable, Hashable, CustomStringConvertible {
    /// No usable predictor/response pair: fewer than two numeric columns.
    case noNumericPair(available: [String])
    /// A requested column name is unknown or not numeric.
    case badColumn(String)
    /// The smoother found no fit (e.g. every row dropped as missing).
    case fitFailed
    /// The fit succeeded but no chart model could be built from it.
    case modelFailed

    public var description: String {
        switch self {
        case .noNumericPair(let available):
            return "Need two numeric columns, found: \(available.joined(separator: ", "))"
        case .badColumn(let name):
            return "Column '\(name)' is unknown or not numeric"
        case .fitFailed:
            return "No smoother could fit these columns"
        case .modelFailed:
            return "Fit succeeded but produced no drawable model"
        }
    }
}

/// A fitted file, ready to draw: the chart model, what the tuner chose,
/// which columns were used, and which subset positions survived.
///
/// `keptIndices` addresses the *fitted subset* (see
/// `FitController.windowBase`); `FitController.keptFileIndices` composes
/// both levels into file rows.
///
/// `summary` is present exactly when tuning competed (`.automatic`):
/// explicit choices skip the competition, so there is nothing to report
/// beyond `smootherName` — a nil summary is the honest record, not a gap.
public struct LoadedChart: Sendable {
    public let model: ChartModel
    public let summary: TuningSummary?
    public let smootherName: String
    public let xName: String
    public let yName: String
    public let keptIndices: [Int]

    public init(
        model: ChartModel, summary: TuningSummary?,
        smootherName: String, xName: String, yName: String, keptIndices: [Int]
    ) {
        self.model = model
        self.summary = summary
        self.smootherName = smootherName
        self.xName = xName
        self.yName = yName
        self.keptIndices = keptIndices
    }
}

/// A column preview for pickers: what `inspectColumns(from:)` reports
/// without fitting anything. Deliberately free of `DataTables` types so
/// UIs import only DataLensing.
public struct ColumnInfo: Sendable, Hashable {
    /// Header name (or `column_<i>` without a header).
    public let name: String
    /// Whether the column extracts to `[Double]` (integer or double).
    public let isNumeric: Bool

    public init(name: String, isNumeric: Bool) {
        self.name = name
        self.isNumeric = isNumeric
    }
}

/// List a file's columns (names + numeric flags) without fitting: the
/// cheap half behind column pickers. A second parse happens at fit
/// time (`loadController`); parse is milliseconds against seconds of
/// fit, so sharing one table isn't worth the retained memory.
public func inspectColumns(from url: URL) throws -> [ColumnInfo] {
    let table = try CSVTable.load(contentsOf: url)
    try Task.checkCancellation()
    return table.columns.map { ColumnInfo(name: $0.name, isNumeric: $0.doubles != nil) }
}

/// Load a CSV file, fit its two numeric columns, and build the chart.
///
/// Column choice: explicit names win; otherwise columns literally named
/// `x`/`y` win; otherwise the first two numeric columns. Missing values
/// flow through `droppingMissing`, so the model's points are the
/// surviving rows in file order.
///
/// The sync convenience over `loadController(from:)` + `FitController`
/// (which the viewer uses directly for background fits). Checks
/// cooperative cancellation between stages, so a pick-away can abort a
/// large fit without waiting for it.
public func loadChart(
    from url: URL, xColumn: String? = nil, yColumn: String? = nil,
    budget: TuningBudget = .full, smoother: SmootherChoice = .automatic
) throws -> LoadedChart {
    var controller = try loadController(
        from: url, xColumn: xColumn, yColumn: yColumn, budget: budget, smoother: smoother
    )
    return try controller.fit()
}

/// Resolve the predictor/response pair (first match wins on duplicates,
/// mirroring `CSVTable` lookups).
func pickColumns(in table: CSVTable, xColumn: String?, yColumn: String?) throws -> (String, String) {
    if let xColumn, let yColumn {
        guard table.doubles(forColumn: xColumn) != nil else { throw ChartLoadError.badColumn(xColumn) }
        guard table.doubles(forColumn: yColumn) != nil else { throw ChartLoadError.badColumn(yColumn) }
        return (xColumn, yColumn)
    }
    if let xs = table.doubles(forColumn: "x"), let ys = table.doubles(forColumn: "y"),
       !xs.isEmpty, !ys.isEmpty
    {
        return ("x", "y")
    }
    let numeric = table.columns.compactMap { $0.doubles == nil ? nil : $0.name }
    guard numeric.count >= 2 else {
        throw ChartLoadError.noNumericPair(available: table.columnNames)
    }
    return (numeric[0], numeric[1])
}
