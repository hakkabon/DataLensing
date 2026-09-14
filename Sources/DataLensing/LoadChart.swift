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
/// and which columns were used.
public struct LoadedChart: Sendable {
    public let model: ChartModel
    public let summary: TuningSummary
    public let xName: String
    public let yName: String

    public init(model: ChartModel, summary: TuningSummary, xName: String, yName: String) {
        self.model = model
        self.summary = summary
        self.xName = xName
        self.yName = yName
    }
}

/// Load a CSV file, fit its two numeric columns, and build the chart.
///
/// Column choice: explicit names win; otherwise columns literally named
/// `x`/`y` win; otherwise the first two numeric columns. Missing values
/// flow through `droppingMissing`, so the model's points are the
/// surviving rows in file order.
///
/// Checks cooperative cancellation between stages, so a pick-away can
/// abort a large fit without waiting for it.
public func loadChart(
    from url: URL, xColumn: String? = nil, yColumn: String? = nil, gridCount: Int = 200
) throws -> LoadedChart {
    let table = try CSVTable.load(contentsOf: url)
    try Task.checkCancellation()
    let (xName, yName) = try pickColumns(in: table, xColumn: xColumn, yColumn: yColumn)
    guard let trainX = table.numericMatrix(columns: [xName]),
          let trainY = table.doubles(forColumn: yName)
    else {
        throw ChartLoadError.badColumn("'\(xName)' / '\(yName)'")
    }
    guard let (fit, summary) = AutomaticSmoother.fit(
        trainX: trainX, trainY: trainY, droppingMissing: true
    ) else {
        throw ChartLoadError.fitFailed
    }
    try Task.checkCancellation()
    guard let model = ChartModel.make(trainX: trainX, trainY: trainY, fit: fit, gridCount: gridCount) else {
        throw ChartLoadError.modelFailed
    }
    return LoadedChart(model: model, summary: summary, xName: xName, yName: yName)
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
