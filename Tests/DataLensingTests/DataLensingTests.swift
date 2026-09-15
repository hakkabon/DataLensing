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

@Test func coveragePolicyIsPureHullMargin() throws {
    let policy = CoveragePolicy(marginFraction: 0.25)
    let hull = 0.0...10.0  // margined: -2.5...12.5
    #expect(!policy.needsRefit(hull: hull, visible: 2.0...8.0))
    #expect(!policy.needsRefit(hull: hull, visible: -2.5...12.5))
    #expect(policy.needsRefit(hull: hull, visible: -2.6...8.0))
    #expect(policy.needsRefit(hull: hull, visible: 2.0...12.6))
    #expect(policy.needsRefit(hull: hull, visible: 20.0...30.0))
    // Degenerate hulls always refit rather than divide by zero.
    #expect(policy.needsRefit(hull: 5.0...5.0, visible: 5.0...5.0))
}

/// Tiny deterministic fixture: y = 2x + 0.5, no missing.
private func linearFixture(n: Int = 25) -> (trainX: [[Double]], trainY: [Double]) {
    let xs = (0..<n).map { [Double($0)] }
    let ys = (0..<n).map { 2 * Double($0) + 0.5 }
    return (xs, ys)
}

@Test func fitControllerCachesAndCovers() throws {
    let (trainX, trainY) = linearFixture()
    var controller = FitController(trainX: trainX, trainY: trainY, xName: "x", yName: "y", budget: .interactive)
    #expect(controller.loaded == nil)
    #expect(controller.needsRefit(covering: 0.0...24.0))  // nothing cached yet
    let loaded = try controller.fit()
    #expect(controller.hull == 0.0...24.0)
    #expect(!controller.needsRefit(covering: 2.0...20.0))
    #expect(!controller.needsRefit(covering: -6.0...30.0))  // inside 25% margin
    #expect(controller.needsRefit(covering: -7.0...20.0))
    #expect(controller.needsRefit(covering: 50.0...60.0))
    #expect(loaded.model.gridX.count == TuningBudget.interactive.gridCount)
}

@Test func concurrentModelMatchesSync() async throws {
    let (trainX, trainY) = linearFixture()
    guard let (fit, _) = AutomaticSmoother.fit(
        trainX: trainX, trainY: trainY, spans: [0.5], robustIterations: 1, droppingMissing: true
    ) else {
        Issue.record("fit returned nil")
        return
    }
    guard let sync = ChartModel.make(trainX: trainX, trainY: trainY, fit: fit, gridCount: 50),
          let concurrent = try await ChartModel.makeConcurrently(trainX: trainX, trainY: trainY, fit: fit, gridCount: 50)
    else {
        Issue.record("model build returned nil")
        return
    }
    #expect(sync.gridX == concurrent.gridX)
    #expect(sync.mean == concurrent.mean)
    #expect(sync.lower == concurrent.lower)
    #expect(sync.upper == concurrent.upper)
}

@Test func budgetPresetsCarryFastFlag() {
    #expect(TuningBudget.interactive.fastAdaptivePrediction)
    #expect(!TuningBudget.full.fastAdaptivePrediction)
}

@Test func fastAdaptiveModelAgreesWithExact() throws {
    let (trainX, trainY) = linearFixture()
    guard let adaptive = AdaptiveLoess.fit(trainX: trainX, trainY: trainY, degree: 2, robustIterations: 1) else {
        Issue.record("adaptive fit returned nil")
        return
    }
    let fit = FittedSmoother.adaptive(adaptive)
    guard let exact = ChartModel.make(trainX: trainX, trainY: trainY, fit: fit, gridCount: 50),
          let fast = ChartModel.make(
              trainX: trainX, trainY: trainY, fit: fit, gridCount: 50, fastAdaptivePrediction: true
          )
    else {
        Issue.record("model build returned nil")
        return
    }
    #expect(exact.gridX == fast.gridX)
    for (a, b) in zip(exact.mean, fast.mean) {
        #expect(abs(a - b) <= 1e-9)
    }
    for (a, b) in zip(exact.lower, fast.lower) {
        #expect(abs(a - b) <= 1e-9)
    }
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
