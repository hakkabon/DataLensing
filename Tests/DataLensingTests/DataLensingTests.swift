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

@Test func inspectColumnsReportsNamesAndNumeric() throws {
    let url = try scratchCSV("time,height,label\n0,1.0,a\n1,3.0,b\n")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try inspectColumns(from: url) == [
        ColumnInfo(name: "time", isNumeric: true),
        ColumnInfo(name: "height", isNumeric: true),
        ColumnInfo(name: "label", isNumeric: false),
    ])
}

@Test func interpolatedMeanIsExactOnGridAndLinearBetween() throws {
    let (trainX, trainY) = linearFixture(n: 25)
    guard let (fit, _) = AutomaticSmoother.fit(
        trainX: trainX, trainY: trainY, spans: [0.5], robustIterations: 0, droppingMissing: true
    ) else {
        Issue.record("fit returned nil")
        return
    }
    guard let model = ChartModel.make(trainX: trainX, trainY: trainY, fit: fit, gridCount: 25) else {
        Issue.record("model build returned nil")
        return
    }
    // On grid points the interpolation is the value itself.
    for (gx, gm) in zip(model.gridX, model.mean) {
        #expect(model.interpolatedMean(at: gx) == gm)
    }
    // Between points it is the linear blend (checked against hand math).
    let x = (model.gridX[7] + model.gridX[8]) / 2
    #expect(model.interpolatedMean(at: x) == (model.mean[7] + model.mean[8]) / 2)
    // Outside the hull: a gap, not an invention.
    #expect(model.interpolatedMean(at: model.gridX.first! - 1) == nil)
    #expect(model.interpolatedMean(at: model.gridX.last! + 1) == nil)
    #expect(model.interpolatedMean(at: .nan) == nil)
}

@Test func generationGateInvalidatesStaleCompletions() {
    var gate = GenerationGate()
    let first = gate.next()
    #expect(gate.isCurrent(first))
    let second = gate.next()
    #expect(!gate.isCurrent(first))
    #expect(gate.isCurrent(second))
    gate.invalidate()  // cancel
    #expect(!gate.isCurrent(second))
    let third = gate.next()
    #expect(gate.isCurrent(third))
}

@Test func chartWindowOpensOnlyForLargeSeries() {
    #expect(ChartWindow.initialVisibleLength(hull: 0.0...10.0, pointCount: 1000) == nil)
    #expect(ChartWindow.initialVisibleLength(hull: 0.0...10.0, pointCount: 4000) == nil)
    #expect(ChartWindow.initialVisibleLength(hull: 0.0...10.0, pointCount: 4001) == 2.0)
    #expect(ChartWindow.initialVisibleLength(hull: nil, pointCount: 100_000) == nil)
    #expect(ChartWindow.initialVisibleLength(hull: 5.0...5.0, pointCount: 100_000) == nil)
}

@Test func refitNarrowsToWindow() throws {
    // Linear truth, no missing: join-back is the identity on the subset.
    let (trainX, trainY) = linearFixture(n: 60)
    var controller = FitController(
        trainX: trainX, trainY: trainY, xName: "x", yName: "y", budget: .interactive
    )
    try controller.fit()
    #expect(controller.hull == 0.0...59.0)
    #expect(controller.keptFileIndices == Array(0..<60))

    #expect(!controller.needsRefit(covering: 20.0...30.0))
    // Covered windows are a no-op (same hull, same join-back).
    #expect(try controller.refit(covering: 20.0...30.0) == false)
    #expect(controller.hull == 0.0...59.0)

    // Escaping windows refit with 25% hysteresis: covering 50...80 gives
    // [42.5, 87.5] → rows 43...59 (data ends at 59).
    #expect(try controller.refit(covering: 50.0...80.0) == true)
    #expect(controller.hull == 43.0...59.0)
    #expect(controller.keptFileIndices == Array(43...59))
    #expect(!controller.needsRefit(covering: 50.0...60.0))
    #expect(controller.needsRefit(covering: 0.0...59.0))

    // Empty and degenerate windows keep the cached fit.
    #expect(try controller.refit(covering: 100.0...200.0) == false)
    #expect(controller.hull == 43.0...59.0)
    #expect(try controller.refit(covering: 52.0...52.0) == false)
    #expect(controller.hull == 43.0...59.0)
}

@Test func refitJoinBackSkipsMissing() throws {
    // NA responses at rows 20–22; NA coordinate at row 40.
    var lines = ["x,y"]
    for i in 0..<60 {
        if 20...22 ~= i {
            lines.append("\(i),NA")
        } else if i == 40 {
            lines.append("NA,\(2 * i)")
        } else {
            lines.append("\(i),\(2 * i + 1)")
        }
    }
    let url = try scratchCSV(lines.joined(separator: "\n") + "\n")
    defer { try? FileManager.default.removeItem(at: url) }
    var controller = try loadController(from: url, budget: .interactive)
    try controller.fit()
    // Full-data join-back skips all four missing rows.
    #expect(controller.keptFileIndices == (0..<60).filter { ![20, 21, 22, 40].contains($0) })

    // Escaping window [45, 80] ± 25% margin → rows 37...59, minus the
    // NA rows inside (row 40 already drops on its NA x).
    #expect(try controller.refit(covering: 45.0...80.0) == true)
    #expect(controller.keptFileIndices == Array(37...39) + Array(41...59))
    #expect(controller.hull == 37.0...59.0)
}

@Test func refitConcurrentMatchesSync() async throws {
    let (trainX, trainY) = linearFixture(n: 60)
    var sync = FitController(
        trainX: trainX, trainY: trainY, xName: "x", yName: "y", budget: .interactive
    )
    try sync.fit()
    _ = try sync.refit(covering: 50.0...80.0)
    var concurrent = FitController(
        trainX: trainX, trainY: trainY, xName: "x", yName: "y", budget: .interactive
    )
    _ = try await concurrent.fitConcurrently()
    _ = try await concurrent.refitConcurrently(covering: 50.0...80.0)
    #expect(concurrent.hull == sync.hull)
    #expect(concurrent.keptFileIndices == sync.keptFileIndices)
    #expect(concurrent.loaded?.model.mean == sync.loaded?.model.mean)
}

@Test func budgetPresetsCarryFastFlag() {
    #expect(TuningBudget.interactive.fastAdaptivePrediction)
    #expect(!TuningBudget.full.fastAdaptivePrediction)
    #expect(!TuningBudget.interactive.adaptiveContender)
    #expect(TuningBudget.full.adaptiveContender)
}

@Test func kernelChoiceTracksSineApex() throws {
    // Reported flattening: a Loess-scale span (0.5) averages half the
    // data under every kernel window, drawing a straight line under the
    // peak. GCV-selected narrow spans must reach near it.
    let n = 60
    let xs = (0..<n).map { [10.0 * Double($0) / Double(n - 1)] }
    let ys = xs.map { sin($0[0]) }
    var controller = FitController(
        trainX: xs, trainY: ys, xName: "x", yName: "y",
        budget: .interactive, smoother: .kernel
    )
    let loaded = try controller.fit()
    #expect(loaded.smootherName == "NadarayaWatson")
    let apex = zip(loaded.model.gridX, loaded.model.mean).filter {
        abs($0.0 - Double.pi / 2) < 0.5
    }.map(\.1)
    #expect(!apex.isEmpty)
    #expect(apex.max()! > 0.8)
    let rmse = sqrt(zip(loaded.model.gridX, loaded.model.mean).reduce(0.0) { acc, pair in
        acc + pow(pair.1 - sin(pair.0), 2)
    } / Double(loaded.model.mean.count))
    #expect(rmse < 0.2)
}

@Test func explicitSmootherChoiceSkipsTuningSummary() throws {
    let (trainX, trainY) = linearFixture()
    let expectations: [(SmootherChoice, String)] = [
        (.loess, "Loess"), (.adaptive, "AdaptiveLoess"), (.kernel, "NadarayaWatson"),
        (.whittaker, "WhittakerEilers"), (.totalVariation, "TotalVariation"),
    ]
    for (choice, name) in expectations {
        var controller = FitController(
            trainX: trainX, trainY: trainY, xName: "x", yName: "y",
            budget: .interactive, smoother: choice
        )
        let loaded = try controller.fit()
        #expect(loaded.summary == nil)
        #expect(loaded.smootherName == name)
        #expect(controller.keptFileIndices == Array(0..<25))
        #expect(loaded.model.mean.allSatisfy { $0.isFinite })
    }
    // Automatic keeps its summary.
    var auto = FitController(
        trainX: trainX, trainY: trainY, xName: "x", yName: "y", budget: .interactive
    )
    #expect(try auto.fit().summary != nil)
}

@Test func whittakerExplicitPenaltySkipsSelection() throws {
    // An explicit penalty fits directly (no GCV grid spent).
    let (trainX, trainY) = linearFixture()
    var budget = TuningBudget.interactive
    budget.smoothingPenalty = 100
    var controller = FitController(
        trainX: trainX, trainY: trainY, xName: "x", yName: "y",
        budget: budget, smoother: .whittaker
    )
    let loaded = try controller.fit()
    #expect(loaded.smootherName == "WhittakerEilers")
    #expect(loaded.model.mean.allSatisfy { $0.isFinite })
}

@Test func interactiveBudgetSkipsAdaptiveContender() throws {
    let (trainX, trainY) = linearFixture()
    var controller = FitController(
        trainX: trainX, trainY: trainY, xName: "x", yName: "y", budget: .interactive
    )
    let loaded = try controller.fit()
    #expect(loaded.smootherName == "Loess")
    #expect(loaded.summary?.smoother == "Loess")
    #expect(loaded.summary?.reason.contains("adaptive contender disabled") == true)
}

@Test func decimationBoundsCountAndKeepsEnvelope() {
    // Dense sine: 10k points into 300 buckets.
    let n = 10_000
    let xs = (0..<n).map { Double($0) / Double(n) * 10 }
    let ys = xs.map { sin($0) + 0.5 * sin(3.7 * $0) }
    let decimated = Decimation.decimate(x: xs, y: ys, buckets: 300)
    #expect(decimated.x.count <= 600)
    #expect(decimated.x.count > 300)  // most buckets hold two extremes
    // Ordered by x.
    #expect(zip(decimated.x, decimated.x.dropFirst()).allSatisfy { $0 <= $1 })
    // Global extremes survive (they are some bucket's extremes).
    #expect(decimated.y.contains(ys.min()!))
    #expect(decimated.y.contains(ys.max()!))
    // Per-bucket extremes survive: recompute independently and check membership.
    let lo = xs.min()!
    let width = xs.max()! - lo
    for b in [0, 7, 150, 299] {
        let inBucket = zip(xs, ys).filter {
            var bb = Int(($0.0 - lo) / width * 300)
            if bb >= 300 { bb = 299 }
            return bb == b
        }.map(\.1)
        guard let bMin = inBucket.min(), let bMax = inBucket.max() else { continue }
        #expect(decimated.y.contains(bMin))
        #expect(decimated.y.contains(bMax))
    }
}

@Test func decimationRespectsVisibleWindowAndEdges() {
    let xs = [0.0, 1.0, 2.0, 3.0, 4.0]
    let ys = [0.0, 10.0, 0.0, 10.0, 0.0]
    let windowed = Decimation.decimate(x: xs, y: ys, visible: 1.0...3.0, buckets: 10)
    #expect(windowed.x.allSatisfy { (1.0...3.0).contains($0) })
    #expect(windowed.y.contains(10.0))
    #expect(Decimation.decimate(x: xs, y: ys, visible: 20.0...30.0, buckets: 10).x.isEmpty)
    #expect(Decimation.decimate(x: [], y: [], buckets: 10).x.isEmpty)
    // Unsorted input and vertical stacks are data, not traps.
    let unsorted = Decimation.decimate(x: [3.0, 1.0, 2.0], y: [0.0, 5.0, -5.0], buckets: 2)
    #expect(unsorted.y.contains(5.0) && unsorted.y.contains(-5.0))
    let stacked = Decimation.decimate(x: [1.0, 1.0, 1.0], y: [2.0, 9.0, 5.0], buckets: 4)
    #expect(stacked.y.contains(2.0) && stacked.y.contains(9.0))
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
