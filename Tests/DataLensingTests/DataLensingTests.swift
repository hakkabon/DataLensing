import Foundation
import Testing

import DataLens
import DataTables
@testable import DataLensing

@Test func example() async throws {
    // Write your test here and use APIs like `#expect(...)` to check expected conditions.
}

/// The engine↔app contract: CSV missing markers surface as `.nan`,
/// `droppingMissing` drops those rows, and `keptIndices` joins the fit
/// back to the original table rows.
@Test func csvMissingHandsOffToDroppingMissing() throws {
    var lines = ["x,y"]
    for i in 0..<25 {
        let x = Double(i)
        let y = 2 * x + 0.5
        switch i {
        case 5: lines.append("\(i),NA")  // missing response
        case 17: lines.append("NA,\(y)")  // missing coordinate
        default: lines.append("\(i),\(y)")
        }
    }
    let table = try CSVTable.parse(lines.joined(separator: "\n") + "\n")
    let trainX = table.numericMatrix(columns: ["x"])
    let trainY = table.doubles(forColumn: "y")
    guard let trainX, let trainY else {
        Issue.record("numeric extraction returned nil")
        return
    }
    guard let (fit, _) = AutomaticSmoother.fit(
        trainX: trainX, trainY: trainY, degree: 1, droppingMissing: true
    ) else {
        Issue.record("AutomaticSmoother.fit returned nil")
        return
    }
    let expected = (0..<25).filter { $0 != 5 && $0 != 17 }
    #expect(fit.keptIndices == expected)
    // The surviving fit evaluates on a fresh grid (the scrolling-view path).
    let grid = stride(from: 0.0, through: 24.0, by: 2.0).map { [$0] }
    let predictions = fit.predict(grid)
    #expect(predictions.count == grid.count)
    #expect(predictions.allSatisfy { $0.isFinite })
}

/// Writes `content` to a scratch CSV file for `loadChart(from:)` tests.
private func scratchCSV(_ content: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("datalensing-\(UUID().uuidString).csv")
    try content.write(to: url, atomically: true, encoding: .utf8)
    return url
}

@Test func loadChartPrefersXYThenFallsBack() throws {
    let xy = try scratchCSV("x,y\n0,0.5\n1,2.5\n2,4.5\n3,6.5\n4,8.5\n")
    defer { try? FileManager.default.removeItem(at: xy) }
    let first = try loadChart(from: xy)
    #expect(first.xName == "x")
    #expect(first.yName == "y")
    #expect(first.model.rawX.count == 5)

    let other = try scratchCSV("time,height,label\n0,1.0,a\n1,3.0,b\n2,5.0,c\n3,7.0,d\n4,9.0,e\n")
    defer { try? FileManager.default.removeItem(at: other) }
    let second = try loadChart(from: other)
    #expect(second.xName == "time")
    #expect(second.yName == "height")

    let explicit = try loadChart(from: other, xColumn: "height", yColumn: "time")
    #expect(explicit.xName == "height")
    #expect(explicit.yName == "time")
}

@Test func loadChartRejectsNonNumeric() throws {
    let url = try scratchCSV("a,b\nx,y\np,q\n")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(throws: ChartLoadError.noNumericPair(available: ["a", "b"])) {
        try loadChart(from: url)
    }
    let numeric = try scratchCSV("x,y\n0,1\n1,3\n")
    defer { try? FileManager.default.removeItem(at: numeric) }
    #expect(throws: ChartLoadError.badColumn("nope")) {
        try loadChart(from: numeric, xColumn: "x", yColumn: "nope")
    }
}
