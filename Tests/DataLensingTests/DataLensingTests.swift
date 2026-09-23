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
    #expect(sync.gradient == concurrent.gradient)
    #expect(sync.residuals == concurrent.residuals)
}

@Test func chartModelCarriesGradientAndRawResiduals() throws {
    let (trainX, trainY) = linearFixture()
    let fit = Loess.fit(trainX: trainX, trainY: trainY, span: 0.5,
                        degree: 1, robustIterations: 0)!
    let model = ChartModel.make(trainX: trainX, trainY: trainY,
                                fit: .loess(fit), gridCount: 25)!
    #expect(model.responseScale == .continuous)
    #expect(model.residualKind == .raw)
    #expect(model.gradient.count == 25)
    #expect(model.gradient.filter(\.isFinite).allSatisfy { abs($0 - 2) < 1e-8 })
    #expect(model.residuals.count == trainY.count)
    #expect(model.residuals.allSatisfy { abs($0) < 1e-8 })
    #expect(model.residualQQ.observed.count == trainY.count)
}

@Test func localLikelihoodUsesProbabilityAndPearsonResiduals() throws {
    let xs = (0..<30).map { [Double($0) / 29] }
    let ys = (0..<30).map { $0 < 15 ? 0.0 : 1.0 }
    let fit = LocalLikelihood.fit(trainX: xs, trainY: ys, degree: 1,
                                  family: .binomial, span: 0.7)!
    let model = ChartModel.make(trainX: xs, trainY: ys,
                                fit: .likelihood(fit), gridCount: 20)!
    #expect(model.responseScale == .probability)
    #expect(model.residualKind == .pearson)
    #expect(model.mean.allSatisfy { $0 >= 0 && $0 <= 1 })
}

@Test func twoDimensionalSurfaceRecoversPlaneGradient() throws {
    var xs: [[Double]] = []
    var ys: [Double] = []
    for y in 0..<6 {
        for x in 0..<6 {
            xs.append([Double(x), Double(y)])
            ys.append(2 * Double(x) - 3 * Double(y) + 4)
        }
    }
    let fit = Loess.fit(trainX: xs, trainY: ys, span: 0.75,
                        degree: 1, robustIterations: 0)!
    let surface = SurfaceModel.make(trainX: xs, fit: .loess(fit),
                                    xCount: 12, yCount: 10)!
    #expect(surface.mean.count == 120)
    #expect(surface.gradientX.filter(\.isFinite).allSatisfy { abs($0 - 2) < 1e-7 })
    #expect(surface.gradientY.filter(\.isFinite).allSatisfy { abs($0 + 3) < 1e-7 })
    #expect(surface.valueRange != nil)
}

@Test func decimationHandlesHalfMillionPointsWithinInteractiveBudget() {
    let count = 500_000
    let xs = (0..<count).map(Double.init)
    let ys = xs.map { sin($0 * 0.001) }
    let clock = ContinuousClock()
    let start = clock.now
    let result = Decimation.decimate(x: xs, y: ys, buckets: 2_000)
    let elapsed = start.duration(to: clock.now)
    #expect(result.x.count <= 4_000)
    // This guards accidental super-linear regressions, not a 120-fps promise:
    // the scan occurs only when the viewport key changes and is cached afterward.
    #expect(elapsed < .seconds(2))
}

@Test func decimationIndexMatchesBucketEnvelopesAndQueriesWindows() {
    // Deliberately unsorted with repeated x values: the index must sort once
    // but still preserve each bucket's extrema and visible-window boundary.
    let x = [2.0, 0.0, 1.0, 1.0, 3.0, 4.0, .nan]
    let y = [8.0, 4.0, -3.0, 7.0, 2.0, 9.0, 1.0]
    let index = DecimationIndex(x: x, y: y)
    #expect(!index.isEmpty)
    let full = index.decimate(buckets: 4)
    #expect(full.x.count <= 8)
    #expect(zip(full.x, full.y).contains { $0.0 == 1 && $0.1 == -3 })
    #expect(zip(full.x, full.y).contains { $0.0 == 1 && $0.1 == 7 })

    let window = index.decimate(visible: 0.5...2.5, buckets: 8)
    #expect(window.x.allSatisfy { $0 >= 0.5 && $0 <= 2.5 })
    #expect(zip(window.x, window.y).contains { $0.0 == 1 && $0.1 == -3 })
    #expect(index.decimate(visible: 10...20, buckets: 8).x.isEmpty)
}

@Test func decimationIndexMakesDenseViewportQueriesBounded() {
    let count = 500_000
    let x = (0..<count).map(Double.init)
    let y = x.map { sin($0 * 0.001) }
    let clock = ContinuousClock()
    let start = clock.now
    let index = DecimationIndex(x: x, y: y)
    let built = start.duration(to: clock.now)
    let queryStart = clock.now
    let visible = index.decimate(visible: 120_000...120_800, buckets: 1_000)
    let queried = queryStart.duration(to: clock.now)
    #expect(visible.x.count <= 2_000)
    // Building happens once off the main rendering path. Repeated viewport
    // queries must stay comfortably inside an interactive-frame budget.
    #expect(built < .seconds(4))
    #expect(queried < .milliseconds(100))
}

@Test func chartModelRawFingerprintInvalidatesEqualShapeData() {
    let first = ChartModel(rawX: [0, 1, 2], rawY: [1, 2, 3],
                           gridX: [0, 2], mean: [1, 3])
    let changedInterior = ChartModel(rawX: [0, 1, 2], rawY: [1, 20, 3],
                                     gridX: [0, 2], mean: [1, 3])
    #expect(first.rawPointFingerprint != changedInterior.rawPointFingerprint)
}

@Test func inspectColumnsReportsNamesAndNumeric() throws {
    let url = try scratchCSV("time,height,label,day\n0,1.0,a,2024-01-01\n1,3.0,b,2024-01-02\n")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try inspectColumns(from: url) == [
        ColumnInfo(name: "time", isNumeric: true),
        ColumnInfo(name: "height", isNumeric: true),
        ColumnInfo(name: "label", isNumeric: false),
        ColumnInfo(name: "day", isNumeric: true, isDate: true),
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

@Test func interpolatedBandReturnsMeanAndConfidenceInterval() {
    let rawX = [0.0, 1.0, 2.0]
    let rawY = [0.0, 2.0, 4.0]
    let gridX = [0.0, 1.0, 2.0]
    let mean = [0.0, 2.0, 4.0]
    let lower = [-0.5, 1.5, 3.5]
    let upper = [0.5, 2.5, 4.5]

    let model = ChartModel(
        rawX: rawX, rawY: rawY,
        gridX: gridX, mean: mean, lower: lower, upper: upper
    )
    #expect(model.hasBand)

    // Exact grid points
    let band0 = model.interpolatedBand(at: 0.0)
    #expect(band0?.mean == 0.0)
    #expect(band0?.lower == -0.5)
    #expect(band0?.upper == 0.5)

    // Midpoint interpolation
    let bandMid = model.interpolatedBand(at: 0.5)
    #expect(bandMid != nil)
    #expect(abs(bandMid!.mean - 1.0) < 1e-9)
    #expect(abs(bandMid!.lower - 0.5) < 1e-9)
    #expect(abs(bandMid!.upper - 1.5) < 1e-9)

    // Out of bounds returns nil
    #expect(model.interpolatedBand(at: -0.1) == nil)
    #expect(model.interpolatedBand(at: 2.1) == nil)
}

@Test func chartModelGracefulDegradationWithoutBand() {
    let rawX = [0.0, 1.0]
    let rawY = [1.0, 2.0]
    let gridX = [0.0, 0.5, 1.0]
    let mean = [1.0, 1.5, 2.0]

    let model = ChartModel(
        rawX: rawX, rawY: rawY,
        gridX: gridX, mean: mean
    )
    #expect(!model.hasBand)
    #expect(model.lower.isEmpty)
    #expect(model.upper.isEmpty)

    // Interpolation works and returns mean for lower and upper when no band is present
    let probed = model.interpolatedBand(at: 0.5)
    #expect(probed != nil)
    #expect(abs(probed!.mean - 1.5) < 1e-9)
    #expect(abs(probed!.lower - 1.5) < 1e-9)
    #expect(abs(probed!.upper - 1.5) < 1e-9)
}

// MARK: - DescriptiveStats tests

/// DataSummary correctly computes n, mean, std, min, max, median, Q1, Q3
/// for a known five-element dataset.
@Test func dataSummaryComputesCorrectStatistics() {
    // Dataset: 1, 2, 3, 4, 5
    let values = [1.0, 3.0, 2.0, 5.0, 4.0]  // deliberately unsorted
    let s = DataSummary(values: values)

    #expect(s.n == 5)
    #expect(abs(s.mean - 3.0) < 1e-9)
    #expect(abs(s.min - 1.0) < 1e-9)
    #expect(abs(s.max - 5.0) < 1e-9)
    #expect(abs(s.median - 3.0) < 1e-9)

    // Sample std of {1,2,3,4,5}: variance = 10/4 = 2.5, std = √2.5
    let expectedStd = (2.5 as Double).squareRoot()
    #expect(abs(s.std - expectedStd) < 1e-9)

    // Q1: 25th percentile of sorted [1,2,3,4,5]; linear interp → 1 + 0.25*(2-1) = 1.75?
    // pos = 0.25 * 4 = 1.0 → lo=1 hi=2 frac=0 → sorted[1] = 2.0
    #expect(abs(s.q1 - 2.0) < 1e-9)
    // Q3: 75th percentile; pos = 0.75 * 4 = 3.0 → sorted[3] = 4.0
    #expect(abs(s.q3 - 4.0) < 1e-9)
    #expect(abs(s.iqr - 2.0) < 1e-9)
}

/// An empty DataSummary returns zeros without crashing.
@Test func dataSummaryHandlesEmptyInput() {
    let s = DataSummary(values: [])
    #expect(s.n == 0)
    #expect(s.mean == 0)
    #expect(s.std == 0)
    #expect(s.min == 0)
    #expect(s.max == 0)
}

/// ChartModel.xSummary and ySummary delegate to the raw arrays correctly.
@Test func chartModelSummaryExtensionsDelegate() {
    let rawX = [1.0, 2.0, 3.0]
    let rawY = [10.0, 20.0, 30.0]
    let gridX = [1.0, 2.0, 3.0]
    let mean  = [10.0, 20.0, 30.0]

    let model = ChartModel(rawX: rawX, rawY: rawY, gridX: gridX, mean: mean)

    let xs = model.xSummary
    #expect(xs.n == 3)
    #expect(abs(xs.mean - 2.0) < 1e-9)
    #expect(abs(xs.min - 1.0) < 1e-9)
    #expect(abs(xs.max - 3.0) < 1e-9)

    let ys = model.ySummary
    #expect(ys.n == 3)
    #expect(abs(ys.mean - 20.0) < 1e-9)
    #expect(abs(ys.min - 10.0) < 1e-9)
    #expect(abs(ys.max - 30.0) < 1e-9)
}

/// fittedGridTSV produces well-formed tab-separated lines.
@Test func fittedGridTSVFormatIsCorrect() {
    let model = ChartModel(
        rawX: [1.0, 2.0], rawY: [1.0, 2.0],
        gridX: [1.0, 1.5, 2.0], mean: [1.0, 1.5, 2.0],
        lower: [0.8, 1.2, 1.6], upper: [1.2, 1.8, 2.4]
    )
    let tsv = model.fittedGridTSV
    let lines = tsv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    // Header row
    #expect(lines[0] == "x\tfit\tlower\tupper")
    // Data rows: 3 data rows after header
    #expect(lines.count == 4)
    // Each data row has 3 tabs (4 columns)
    for line in lines.dropFirst() {
        #expect(line.filter { $0 == "\t" }.count == 3)
    }
}

@Test func analysisReportCapturesProvenanceAndExportsStableFormats() throws {
    let url = try scratchCSV("time,value\n0,1\n1,3\n2,NA\n3,7\n")
    let model = ChartModel(
        rawX: [0, 1, 3], rawY: [1, 3, 7], gridX: [0, 1, 2, 3], mean: [1, 3, 5, 7],
        fittedAtTraining: [1, 3, 7], residuals: [0, 0, .nan]
    )
    let loaded = LoadedChart(model: model, summary: nil, smootherName: "Loess",
                             xName: "time", yName: "value", keptIndices: [0, 1, 3])
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let report = AnalysisReport.make(from: loaded, sourceURL: url,
                                     inputObservationCount: 4, createdAt: date)

    #expect(report.schemaVersion == 2)
    #expect(report.source.fileName.hasSuffix(".csv"))
    #expect(report.inputObservationCount == 4)
    #expect(report.retainedObservationCount == 3)
    #expect(report.droppedObservationCount == 1)
    #expect(report.observations.map(\.sourceRow) == [0, 1, 3])
    #expect(report.observations.last?.residual == nil)
    #expect(report.assessment?.observationCount == 2)

    let json = try #require(String(data: report.jsonData(), encoding: .utf8))
    #expect(json.contains("\"schemaVersion\" : 2"))
    #expect(json.contains("\"createdAt\" : \"2023-11-14T22:13:20Z\""))
    let csv = report.observationsCSV()
    #expect(csv.hasPrefix("source_row,time,value,fitted,residual\n"))
    #expect(csv.split(separator: "\n").count == 4)
}

@Test func builtInWorkbenchToolsProducePortableOrderedResults() async throws {
    let model = ChartModel(
        rawX: [0, 1, 2], rawY: [1, 3, 20], gridX: [0, 1, 2], mean: [1, 3, 5],
        fittedAtTraining: [1, 3, 5], residuals: [0, 0, 15]
    )
    let loaded = LoadedChart(model: model, summary: nil, smootherName: "Loess",
                             xName: "time", yName: "value", keptIndices: [0, 1, 2])
    let source = try WorkbenchSource(displayName: "observations.csv", inputObservationCount: 4)
    let input = try WorkbenchInput(loaded: loaded, source: source, sourceRows: [4, 8, 12])

    let outputs = try await WorkbenchCatalog.builtIns.runAll(on: input)
    #expect(outputs.map(\.id) == [
        "descriptive-statistics", "model-assessment", "cross-validation", "residual-review", "residual-profile",
    ])
    #expect(outputs[0].metrics.first(where: { $0.id == "retained-observations" })?.value == 3)
    #expect(outputs[3].table?.rows.first == ["12", "2", "20", "5", "15", "15"])
    #expect(outputs[4].table?.rows.count == 3)

    #expect(throws: WorkbenchError.duplicateToolIdentifier("descriptive-statistics")) {
        _ = try WorkbenchCatalog(tools: [DescriptiveWorkbenchTool(), DescriptiveWorkbenchTool()])
    }
    await #expect(throws: WorkbenchError.unknownTool("missing")) {
        _ = try await WorkbenchCatalog.builtIns.run(id: "missing", on: input)
    }
}

@Test func residualProfileIsBoundedAndPreservesPredictorStructure() async throws {
    let xs = (0 ..< 12).map(Double.init)
    let residuals = xs.map { $0 < 6 ? -2.0 : 2.0 }
    let model = ChartModel(
        rawX: xs, rawY: Array(repeating: 0, count: xs.count), gridX: xs,
        mean: Array(repeating: 0, count: xs.count), fittedAtTraining: Array(repeating: 0, count: xs.count),
        residuals: residuals
    )
    let loaded = LoadedChart(model: model, summary: nil, smootherName: "Loess",
                             xName: "time", yName: "value", keptIndices: Array(xs.indices))
    let source = try WorkbenchSource(displayName: "step-residuals.csv", inputObservationCount: xs.count)
    let output = try await ResidualProfileWorkbenchTool(maximumBins: 3).run(
        on: WorkbenchInput(loaded: loaded, source: source)
    )

    #expect(output.id == "residual-profile")
    #expect(output.summary == "3 equal-count predictor bins summarize 12 finite residuals.")
    #expect(output.table?.columns == ["bin", "time_min", "time_max", "n", "mean_residual", "residual_rms"])
    #expect(output.table?.rows.count == 3)
    #expect(output.table?.rows.map { $0[3] } == ["4", "4", "4"])
    #expect(output.table?.rows.map { $0[4] } == ["-2", "0", "2"])
    #expect(output.metrics.first(where: { $0.id == "relative-structure" })?.value == 1)
}

@Test func workbenchSessionRoundTripsAndRejectsUnknownSchemas() throws {
    let source = try WorkbenchSource(displayName: "observations.csv", inputObservationCount: 40)
    let budget = TuningBudget(
        degree: 1, spans: [0.3, 0.6], robustIterations: 2, gridCount: 120,
        fastAdaptivePrediction: true, adaptiveContender: false, smoothingPenalty: 4
    )
    let session = try WorkbenchSession(
        source: source, predictor: "time", response: "value", secondPredictor: "temperature",
        smoother: .whittaker, budget: budget, activePlanesRawValue: 7,
        enabledToolIDs: WorkbenchCatalog.builtIns.toolIDs
    )
    let data = try session.jsonData()
    let restored = try WorkbenchSession(jsonData: data)
    #expect(restored == session)
    #expect(restored.tuning.tuningBudget == budget)
    #expect(restored.smootherChoice == .whittaker)
    #expect(restored.validationConfiguration.specification.degree == budget.degree)
    #expect(restored.validationConfiguration.specification.spans == budget.spans)

    var legacyObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacyObject["schemaVersion"] = 1
    legacyObject.removeValue(forKey: "validationConfiguration")
    let legacy = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
    let decodedLegacy = try WorkbenchSession(jsonData: legacy)
    #expect(decodedLegacy.schemaVersion == 1)
    #expect(decodedLegacy.validationConfiguration.specification.degree == budget.degree)

    let json = try #require(String(data: data, encoding: .utf8))
    let unsupported = try #require(json.replacingOccurrences(
        of: "\"schemaVersion\" : 2", with: "\"schemaVersion\" : 99"
    ).data(using: .utf8))
    #expect(throws: WorkbenchSessionError.unsupportedSchema(99)) {
        _ = try WorkbenchSession(jsonData: unsupported)
    }
}

@Test func analysisDocumentPreservesEvidenceAndMarksDependentBlocksStale() throws {
    let url = try scratchCSV("time,value\n0,1\n1,3\n2,5\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let table = try CSVTable.load(contentsOf: url)
    let source = try AnalysisDocument.Source.make(from: url, table: table)
    let workbenchSource = try WorkbenchSource(
        displayName: source.displayName, inputObservationCount: source.inputObservationCount
    )
    let session = try WorkbenchSession(
        source: workbenchSource, predictor: "time", response: "value", smoother: .loess,
        budget: .interactive, activePlanesRawValue: 0, enabledToolIDs: WorkbenchCatalog.builtIns.toolIDs
    )
    let recipe = try AnalysisDocument.ModelRecipe(session: session)
    let loaded = LoadedChart(
        model: ChartModel(
            rawX: [0, 1, 2], rawY: [1, 3, 5], gridX: [0, 1, 2], mean: [1, 3, 5],
            fittedAtTraining: [1, 3, 5], residuals: [0, 0, 0]
        ), summary: nil, smootherName: "Loess", xName: "time", yName: "value", keptIndices: [0, 1, 2]
    )
    let report = AnalysisReport.make(from: loaded, sourceURL: url, inputObservationCount: 3)
    let evidence = try AnalysisDocument.EvidenceSnapshot(
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000), sourceFingerprint: source.fingerprint,
        report: report,
        workbenchOutputs: [try WorkbenchOutput(
            id: "model-assessment", title: "Model Assessment", summary: "No configured thresholds were exceeded."
        )]
    )
    let transformation = try AnalysisDocument.Block(
        title: "Remove incomplete observations",
        payload: .transformation(.dropMissing(columns: ["time", "value"]))
    )
    let model = try AnalysisDocument.Block(
        title: "Loess trend", upstreamBlockIDs: [transformation.id], payload: .model(recipe)
    )
    let evidenceBlock = try AnalysisDocument.Block(
        title: "Fit and validation evidence", upstreamBlockIDs: [model.id], payload: .evidence(evidence)
    )
    var document = try AnalysisDocument(
        title: "Trend analysis", source: source, blocks: [transformation, model, evidenceBlock],
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let stale = try document.update(
        blockID: transformation.id,
        payload: .transformation(.filterNumeric(column: "time", comparison: .greaterThanOrEqual, value: 0)),
        at: Date(timeIntervalSince1970: 1_700_000_100)
    )
    #expect(stale == Set([model.id, evidenceBlock.id]))
    #expect(document.blocks[0].state == .current)
    #expect(document.blocks[1].state == .stale)
    #expect(document.blocks[2].state == .stale)

    let json = try #require(String(data: document.jsonData(), encoding: .utf8))
    #expect(json.contains("\"schemaVersion\" : \(AnalysisDocument.currentSchemaVersion)"))
    #expect(json.contains(source.displayName))
    #expect(!json.contains(url.path))
    #expect(try AnalysisDocument(jsonData: document.jsonData()) == document)

    var legacyObject = try #require(JSONSerialization.jsonObject(with: document.jsonData()) as? [String: Any])
    legacyObject.removeValue(forKey: "composition")
    legacyObject.removeValue(forKey: "review")
    legacyObject["schemaVersion"] = 1
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    #expect(try AnalysisDocument(jsonData: legacyData).schemaVersion == AnalysisDocument.currentSchemaVersion)

    legacyObject["schemaVersion"] = 3
    let versionThreeData = try JSONSerialization.data(withJSONObject: legacyObject)
    #expect(try AnalysisDocument(jsonData: versionThreeData).schemaVersion == AnalysisDocument.currentSchemaVersion)

    legacyObject["schemaVersion"] = 6
    let versionSixData = try JSONSerialization.data(withJSONObject: legacyObject)
    let upgradedVersionSix = try AnalysisDocument(jsonData: versionSixData)
    #expect(upgradedVersionSix.schemaVersion == AnalysisDocument.currentSchemaVersion)
    #expect(upgradedVersionSix.composition.sections.isEmpty)
    #expect(upgradedVersionSix.review.readiness == .draft)
    #expect(upgradedVersionSix.review.findings.isEmpty)

    var futureObject = try #require(JSONSerialization.jsonObject(with: document.jsonData()) as? [String: Any])
    futureObject["schemaVersion"] = 99
    let futureData = try JSONSerialization.data(withJSONObject: futureObject)
    #expect(throws: AnalysisDocumentError.unsupportedSchema(99)) {
        _ = try AnalysisDocument(jsonData: futureData)
    }
}

@Test func analysisDocumentFingerprintsSourceAndRejectsInvalidEvidenceGraphs() throws {
    let firstURL = try scratchCSV("x,y\n0,1\n1,2\n")
    let secondURL = try scratchCSV("x,y\n0,1\n1,20\n")
    defer {
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
    }
    let first = try AnalysisDocument.Source.make(from: firstURL, table: CSVTable.load(contentsOf: firstURL))
    let second = try AnalysisDocument.Source.make(from: secondURL, table: CSVTable.load(contentsOf: secondURL))
    #expect(first.fingerprint != second.fingerprint)

    let orphan = try AnalysisDocument.Block(
        title: "Cannot depend on an absent block", upstreamBlockIDs: [UUID()], payload: .note("Review import.")
    )
    #expect(throws: AnalysisDocumentError.invalidDependency(orphan.id)) {
        _ = try AnalysisDocument(title: "Invalid graph", source: first, blocks: [orphan])
    }

    let model = try AnalysisDocument.Block(
        title: "Model", payload: .model(try AnalysisDocument.ModelRecipe(
            predictor: "x", response: "y", smoother: .loess, tuning: WorkbenchTuning(.interactive),
            validationConfiguration: ValidationConfiguration()
        ))
    )
    let report = AnalysisReport.make(
        from: LoadedChart(
            model: ChartModel(rawX: [0, 1], rawY: [1, 2], gridX: [0, 1], mean: [1, 2]),
            summary: nil, smootherName: "Loess", xName: "x", yName: "y", keptIndices: [0, 1]
        ), sourceURL: firstURL, inputObservationCount: 2
    )
    let mismatchedEvidence = try AnalysisDocument.Block(
        title: "Mismatched evidence", upstreamBlockIDs: [model.id], payload: .evidence(
            try AnalysisDocument.EvidenceSnapshot(
                sourceFingerprint: second.fingerprint, report: report, workbenchOutputs: []
            )
        )
    )
    #expect(throws: AnalysisDocumentError.invalidEvidence(mismatchedEvidence.id)) {
        _ = try AnalysisDocument(title: "Invalid evidence", source: first, blocks: [model, mismatchedEvidence])
    }
}

@Test func notebookCompositionOrganizesExistingBlocksWithoutChangingExecutionGraph() throws {
    let url = try scratchCSV("x,y\n0,1\n1,2\n2,4\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try AnalysisDocument.Source.make(from: url, table: CSVTable.load(contentsOf: url))
    let transform = try AnalysisDocument.Block(
        title: "Complete cases", payload: .transformation(.dropMissing(columns: ["x", "y"]))
    )
    let defaultValidation = ValidationConfiguration()
    let plan = try AnalysisDocument.ValidationPlan(
        intendedUse: .orderedOrSpatial, foldCount: 3, partitioning: .blocked, seed: 13
    )
    let planBlock = try AnalysisDocument.Block(title: "Blocked validation", payload: .validationPlan(plan))
    let recipe = try AnalysisDocument.ModelRecipe(
        predictor: "x", response: "y", smoother: .loess, tuning: WorkbenchTuning(.interactive),
        validationConfiguration: plan.validationConfiguration(for: defaultValidation.specification),
        validationPlanBlockID: planBlock.id
    )
    let model = try AnalysisDocument.Block(
        title: "Loess trend", upstreamBlockIDs: [transform.id, planBlock.id], payload: .model(recipe)
    )
    var document = try AnalysisDocument(
        title: "Composed trend", source: source, blocks: [transform, planBlock, model]
    )
    let run = try AnalysisDocument.AnalysisRun.completed(
        in: document, modelBlockID: model.id, retainedObservationCount: 3,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        completedAt: Date(timeIntervalSince1970: 1_700_000_001)
    )
    let runBlock = try AnalysisDocument.Block(
        title: "Recorded run", upstreamBlockIDs: [model.id], payload: .run(run)
    )
    let figureBlock = try AnalysisDocument.Block(
        title: "Trend figure", upstreamBlockIDs: [runBlock.id],
        payload: .figure(try AnalysisDocument.FigureAnnotation(kind: .fittedCurve, caption: "Trend."))
    )
    let noteBlock = try AnalysisDocument.Block(title: "Interpretation", payload: .note("Residual pattern is acceptable."))
    try document.append(runBlock)
    try document.append(figureBlock)
    try document.append(noteBlock)

    try document.createInitialComposition()
    #expect(document.composition.sections.map(\.title) == [
        "Data & preparation", "Models & validation", "Results & interpretation"
    ])
    #expect(document.composition.blockIDs == document.blocks.map(\.id))
    #expect(document.uncomposedBlocks.isEmpty)
    #expect(document.blocks.map(\.upstreamBlockIDs) == [
        [], [], [transform.id, planBlock.id], [model.id], [runBlock.id], []
    ])

    let conclusionID = try document.appendCompositionSection(
        title: "Conclusion", narrative: "The trend is stable over the observed range."
    )
    let laterNote = try AnalysisDocument.Block(title: "Follow-up", payload: .note("Compare alternative spans next."))
    try document.append(laterNote)
    #expect(document.uncomposedBlocks == [laterNote])
    try document.assignToComposition(blockID: laterNote.id, sectionID: conclusionID)
    try document.updateCompositionSection(
        id: conclusionID, title: "Conclusion", narrative: "Compare alternative spans in the next run."
    )
    try document.moveCompositionSection(id: conclusionID, to: 0)
    #expect(document.composition.sections.first?.id == conclusionID)
    #expect(document.uncomposedBlocks.isEmpty)
    #expect(try AnalysisDocument(jsonData: document.jsonData()) == document)

    let danglingSection = try AnalysisDocument.NotebookComposition.Section(
        title: "Invalid", blockIDs: [UUID()]
    )
    let danglingComposition = try AnalysisDocument.NotebookComposition(sections: [danglingSection])
    #expect(throws: AnalysisDocumentError.invalidConfiguration) {
        _ = try AnalysisDocument(title: "Invalid composition", source: source, composition: danglingComposition)
    }
}

@Test func documentReviewMakesReadinessAndFindingResolutionAuditable() throws {
    let url = try scratchCSV("x,y\n0,1\n1,2\n2,4\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try AnalysisDocument.Source.make(from: url, table: CSVTable.load(contentsOf: url))
    let recipe = try AnalysisDocument.ModelRecipe(
        predictor: "x", response: "y", smoother: .loess, tuning: WorkbenchTuning(.interactive),
        validationConfiguration: ValidationConfiguration()
    )
    let model = try AnalysisDocument.Block(title: "Trend", payload: .model(recipe))
    let figure = try AnalysisDocument.Block(
        title: "Trend figure", upstreamBlockIDs: [model.id],
        payload: .figure(try AnalysisDocument.FigureAnnotation(kind: .fittedCurve, caption: "Observed trend."))
    )
    var document = try AnalysisDocument(title: "Reviewed trend", source: source, blocks: [model, figure])

    #expect(document.reviewSummary.canMarkReady)
    try document.setReviewReadiness(.readyForReview)
    #expect(document.review.readiness == .readyForReview)

    let blockerID = try document.addReviewFinding(
        author: "A. Reviewer", body: "Explain the boundary behavior.", targetBlockID: figure.id,
        severity: .blocker
    )
    #expect(document.review.readiness == .draft)
    #expect(document.reviewSummary.openFindingCount == 1)
    #expect(document.reviewSummary.openBlockerCount == 1)
    #expect(!document.reviewSummary.canMarkReady)
    #expect(throws: AnalysisDocumentError.invalidConfiguration) {
        try document.setReviewReadiness(.accepted)
    }

    try document.closeReviewFinding(
        id: blockerID, as: .resolved, resolution: "Added a boundary-sensitivity note."
    )
    #expect(document.review.findings.first?.status == .resolved)
    #expect(document.review.findings.first?.resolution == "Added a boundary-sensitivity note.")
    try document.setReviewReadiness(.readyForReview)
    try document.setReviewReadiness(.accepted)
    #expect(document.review.readiness == .accepted)

    _ = try document.update(blockID: model.id, payload: .model(recipe))
    #expect(document.review.readiness == .draft)
    #expect(document.blocks.first(where: { $0.id == figure.id })?.state == .stale)
    #expect(document.reviewSummary.staleBlockCount == 1)
    let missingBlockID = UUID()
    #expect(throws: AnalysisDocumentError.invalidDependency(missingBlockID)) {
        _ = try document.addReviewFinding(
            author: "A. Reviewer", body: "Missing target.", targetBlockID: missingBlockID
        )
    }
    #expect(try AnalysisDocument(jsonData: document.jsonData()) == document)
}

@Test func replayableTransformationsPreserveSourceRowsAndDerivedValues() throws {
    let table = try CSVTable.parse("""
    id,x,y,label
    0,1,10,keep
    1,NA,20,missing-x
    2,-2,30,negative-x
    3,4,40,keep
    """)
    let replayed = try AnalysisTransformationExecutor.replay([
        .selectColumns(["id", "x", "y"]),
        .dropMissing(columns: ["x", "y"]),
        .filterNumeric(column: "x", comparison: .greaterThanOrEqual, value: 0),
        .naturalLog(source: "x", destination: "log_x"),
    ], on: table)

    #expect(replayed.sourceRowIndices == [0, 3])
    #expect(replayed.columnNames == ["id", "x", "y", "log_x"])
    #expect(replayed.numericValues(forColumn: "id") == [0, 3])
    #expect(replayed.numericValues(forColumn: "x") == [1, 4])
    #expect(replayed.numericValues(forColumn: "y") == [10, 40])
    #expect(try #require(replayed.numericValues(forColumn: "log_x")).enumerated().allSatisfy {
        abs($0.element - [0.0, log(4.0)][$0.offset]) < 1e-12
    })
    #expect(replayed.textValues(forColumn: "label") == nil)

    #expect(throws: AnalysisTransformationError.nonNumericColumn("label")) {
        _ = try AnalysisTransformationExecutor.replay([.naturalLog(source: "label", destination: "log_label")], on: table)
    }
    #expect(throws: AnalysisTransformationError.invalidTransformation) {
        _ = try AnalysisTransformationExecutor.replay([.selectColumns([])], on: table)
    }
}

@Test func documentReplayUsesOnlyAncestorTransformsAndRejectsChangedSources() throws {
    let url = try scratchCSV("x,y\n0,1\n1,NA\n2,5\n3,7\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let table = try CSVTable.load(contentsOf: url)
    let source = try AnalysisDocument.Source.make(from: url, table: table)
    let removeMissing = try AnalysisDocument.Block(
        title: "Remove incomplete values", payload: .transformation(.dropMissing(columns: ["x", "y"]))
    )
    let keepLateRows = try AnalysisDocument.Block(
        title: "Keep later rows", upstreamBlockIDs: [removeMissing.id],
        payload: .transformation(.filterNumeric(column: "x", comparison: .greaterThanOrEqual, value: 2))
    )
    let recipe = try AnalysisDocument.ModelRecipe(
        predictor: "x", response: "y", smoother: .loess, tuning: WorkbenchTuning(.interactive),
        validationConfiguration: ValidationConfiguration()
    )
    let model = try AnalysisDocument.Block(
        title: "Trend model", upstreamBlockIDs: [keepLateRows.id], payload: .model(recipe)
    )
    let document = try AnalysisDocument(
        title: "Replay test", source: source, blocks: [removeMissing, keepLateRows, model]
    )

    let replay = try AnalysisTransformationExecutor.replay(
        document: document, sourceURL: url, through: model.id
    )
    #expect(replay.appliedBlockIDs == [removeMissing.id, keepLateRows.id])
    #expect(replay.table.sourceRowIndices == [2, 3])
    #expect(replay.table.numericValues(forColumn: "y") == [5, 7])

    try "x,y\n0,1\n1,2\n2,5\n3,7\n".write(to: url, atomically: true, encoding: .utf8)
    #expect(throws: AnalysisTransformationError.sourceChanged) {
        _ = try AnalysisTransformationExecutor.replay(document: document, sourceURL: url, through: model.id)
    }
}

@Test func documentFiguresRequireModelsAndExplicitReplayDoesNotReviveOldEvidence() throws {
    let url = try scratchCSV("x,y\n0,1\n1,3\n2,5\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try AnalysisDocument.Source.make(from: url, table: CSVTable.load(contentsOf: url))
    let transform = try AnalysisDocument.Block(
        title: "Complete cases", payload: .transformation(.dropMissing(columns: ["x", "y"]))
    )
    let model = try AnalysisDocument.Block(
        title: "Trend", upstreamBlockIDs: [transform.id], payload: .model(
            try AnalysisDocument.ModelRecipe(
                predictor: "x", response: "y", smoother: .loess,
                tuning: WorkbenchTuning(.interactive), validationConfiguration: ValidationConfiguration()
            )
        )
    )
    let figure = try AnalysisDocument.Block(
        title: "Fitted trend", upstreamBlockIDs: [model.id], payload: .figure(
            try AnalysisDocument.FigureAnnotation(kind: .fittedCurve, caption: "A smooth increasing trend.")
        )
    )
    let loaded = LoadedChart(
        model: ChartModel(rawX: [0, 1, 2], rawY: [1, 3, 5], gridX: [0, 1, 2], mean: [1, 3, 5]),
        summary: nil, smootherName: "Loess", xName: "x", yName: "y", keptIndices: [0, 1, 2]
    )
    let evidence = try AnalysisDocument.Block(
        title: "Initial evidence", upstreamBlockIDs: [model.id], payload: .evidence(
            try AnalysisDocument.EvidenceSnapshot(
                sourceFingerprint: source.fingerprint,
                report: AnalysisReport.make(from: loaded, sourceURL: url, inputObservationCount: 3),
                workbenchOutputs: []
            )
        )
    )
    var document = try AnalysisDocument(
        title: "Document", source: source, blocks: [transform, model, figure, evidence]
    )

    _ = try document.update(
        blockID: transform.id,
        payload: .transformation(.filterNumeric(column: "x", comparison: .greaterThanOrEqual, value: 0))
    )
    #expect(document.blocks.map(\.state) == [.current, .stale, .stale, .stale])
    let refreshed = try document.markCurrent(through: model.id)
    #expect(refreshed == Set([transform.id, model.id]))
    #expect(document.blocks.map(\.state) == [.current, .current, .stale, .stale])

    let orphanFigure = try AnalysisDocument.Block(
        title: "Orphan figure", payload: .figure(
            try AnalysisDocument.FigureAnnotation(kind: .residuals, caption: "No model.")
        )
    )
    #expect(throws: AnalysisDocumentError.invalidDependency(orphanFigure.id)) {
        _ = try AnalysisDocument(title: "Invalid", source: source, blocks: [orphanFigure])
    }
}

@Test func documentExecutorFitsReplayAndPreservesOriginalRows() async throws {
    let url = try scratchCSV("x,y\n0,1\n1,NA\n2,5\n3,7\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try AnalysisDocument.Source.make(from: url, table: CSVTable.load(contentsOf: url))
    let transform = try AnalysisDocument.Block(
        title: "Complete cases", payload: .transformation(.dropMissing(columns: ["x", "y"]))
    )
    let model = try AnalysisDocument.Block(
        title: "Trend", upstreamBlockIDs: [transform.id], payload: .model(
            try AnalysisDocument.ModelRecipe(
                predictor: "x", response: "y", smoother: .loess,
                tuning: WorkbenchTuning(.interactive), validationConfiguration: ValidationConfiguration()
            )
        )
    )
    let document = try AnalysisDocument(title: "Replay", source: source, blocks: [transform, model])
    let fit = try await AnalysisDocumentExecutor.fit(
        document: document, sourceURL: url, modelBlockID: model.id
    )
    #expect(fit.loaded.model.rawX == [0, 2, 3])
    #expect(fit.sourceRows == [0, 2, 3])
    #expect(fit.transformedObservationCount == 3)
    #expect(try AnalysisDocumentExecutor.workbenchInput(document: document, fit: fit).sourceRows == [0, 2, 3])
}

@Test func scaledStatisticalWorkflowsUseDeterministicStratifiedFitsAndRecordSelection() async throws {
    let predictors = (0..<101).map { [Double($0)] }
    let response = (0..<101).map { Double($0 * $0) }
    let policy = StatisticalScalePolicy.stratifiedLeadingPredictor(maximumObservations: 10, seed: 41)
    let first = try policy.select(predictors: predictors, response: response)
    let second = try policy.select(predictors: predictors, response: response)
    #expect(first == second)
    #expect(first.inputObservationCount == 101)
    #expect(first.eligibleObservationCount == 101)
    #expect(first.selectedObservationCount == 10)
    #expect(first.reduced)
    #expect(first.selectedIndices == first.selectedIndices.sorted())
    #expect(first.selectedIndices.first! < 11)
    #expect(first.selectedIndices.last! > 89)

    let rows = (0..<80).map { index in "\(index),\(Double(index) + sin(Double(index) / 4))" }
    let url = try scratchCSV("x,y\n" + rows.joined(separator: "\n") + "\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try AnalysisDocument.Source.make(from: url, table: CSVTable.load(contentsOf: url))
    let recipe = try AnalysisDocument.ModelRecipe(
        predictor: "x", response: "y", smoother: .loess, tuning: WorkbenchTuning(.interactive),
        validationConfiguration: ValidationConfiguration(),
        scalePolicy: .stratifiedLeadingPredictor(maximumObservations: 12, seed: 9)
    )
    let model = try AnalysisDocument.Block(title: "Bounded trend", payload: .model(recipe))
    var document = try AnalysisDocument(title: "Scaled workflow", source: source, blocks: [model])
    let fit = try await AnalysisDocumentExecutor.fit(
        document: document, sourceURL: url, modelBlockID: model.id
    )
    #expect(fit.scaleSelection.inputObservationCount == 80)
    #expect(fit.scaleSelection.eligibleObservationCount == 80)
    #expect(fit.scaleSelection.selectedObservationCount == 12)
    #expect(fit.trainingSourceRows == fit.scaleSelection.selectedIndices)
    #expect(fit.loaded.model.rawX.count == 12)

    let run = try AnalysisDocument.AnalysisRun.completed(
        in: document, modelBlockID: model.id, retainedObservationCount: fit.sourceRows.count,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        completedAt: Date(timeIntervalSince1970: 1_700_000_001),
        scaleSelection: fit.scaleSelection
    )
    #expect(run.scaleSelection == fit.scaleSelection)
    let runBlock = try AnalysisDocument.Block(
        title: "Bounded run", upstreamBlockIDs: [model.id], payload: .run(run)
    )
    try document.append(runBlock)
    #expect(try AnalysisDocument(jsonData: document.jsonData()) == document)
}

@Test func analysisRunsSnapshotInputsAndRemainAsStaleHistoricalRecords() throws {
    let url = try scratchCSV("x,y\n0,1\n1,3\n2,5\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try AnalysisDocument.Source.make(from: url, table: CSVTable.load(contentsOf: url))
    let transform = try AnalysisDocument.Block(
        title: "Complete cases", payload: .transformation(.dropMissing(columns: ["x", "y"]))
    )
    let recipe = try AnalysisDocument.ModelRecipe(
        predictor: "x", response: "y", smoother: .loess,
        tuning: WorkbenchTuning(.interactive), validationConfiguration: ValidationConfiguration()
    )
    let model = try AnalysisDocument.Block(
        title: "Trend", upstreamBlockIDs: [transform.id], payload: .model(recipe)
    )
    var document = try AnalysisDocument(title: "Run lineage", source: source, blocks: [transform, model])
    let startedAt = Date(timeIntervalSince1970: 1_700_001_000)
    let completed = try AnalysisDocument.AnalysisRun.completed(
        in: document, modelBlockID: model.id, retainedObservationCount: 3,
        startedAt: startedAt, completedAt: startedAt.addingTimeInterval(2)
    )
    #expect(completed.recipe == .model(recipe))
    #expect(completed.transformationBlockIDs == [transform.id])
    #expect(completed.validationSeed == recipe.validationConfiguration.seed)
    let runBlock = try AnalysisDocument.Block(
        title: "Completed run", upstreamBlockIDs: [model.id], payload: .run(completed)
    )
    try document.append(runBlock)

    let stale = try document.update(
        blockID: transform.id,
        payload: .transformation(.filterNumeric(column: "x", comparison: .greaterThanOrEqual, value: 0))
    )
    #expect(stale == Set([model.id, runBlock.id]))
    #expect(document.blocks.last?.state == .stale)

    let replacementSource = try AnalysisDocument.Source(
        displayName: source.displayName, inputObservationCount: source.inputObservationCount,
        columns: source.columns, fingerprint: "changed-source-fingerprint", byteCount: source.byteCount
    )
    #expect(try document.updateSource(replacementSource).contains(runBlock.id))
    #expect(document.blocks.last?.state == .stale)

    let failed = try AnalysisDocument.AnalysisRun.failed(
        in: document, modelBlockID: model.id, description: "Source could not be replayed.",
        startedAt: startedAt, completedAt: startedAt.addingTimeInterval(1)
    )
    #expect(failed.status == .failed)
    #expect(failed.retainedObservationCount == nil)
    #expect(failed.failureDescription == "Source could not be replayed.")
}

@Test func executionEnvironmentsAndRunDifferencesCloseReproducibilityGaps() throws {
    let url = try scratchCSV("x,y\n0,1\n1,3\n2,5\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try AnalysisDocument.Source.make(from: url, table: CSVTable.load(contentsOf: url))
    let validation = ValidationConfiguration(foldCount: 3, partitioning: .blocked, seed: 7)
    let fullRecipe = try AnalysisDocument.ModelRecipe(
        predictor: "x", response: "y", smoother: .loess, tuning: WorkbenchTuning(.interactive),
        validationConfiguration: validation
    )
    let boundedPolicy = StatisticalScalePolicy.stratifiedLeadingPredictor(maximumObservations: 2, seed: 4)
    let boundedRecipe = try AnalysisDocument.ModelRecipe(
        predictor: "x", response: "y", smoother: .loess, tuning: WorkbenchTuning(.interactive),
        validationConfiguration: validation, scalePolicy: boundedPolicy
    )
    let fullModel = try AnalysisDocument.Block(title: "Full fit", payload: .model(fullRecipe))
    let boundedModel = try AnalysisDocument.Block(title: "Bounded fit", payload: .model(boundedRecipe))
    var document = try AnalysisDocument(title: "Environment diff", source: source, blocks: [fullModel, boundedModel])
    let firstEnvironment = AnalysisDocument.ExecutionEnvironment(
        hostBuildIdentifier: "0.38.0", swiftLanguageVersion: "6.1", platform: "macOS",
        architecture: "arm64", swiftDataLensVersion: "0.20.1",
        swiftNumericCoreVersion: "0.7.0", rustNumericCoreVersion: "0.5.0",
        resolverFingerprint: "resolved-a"
    )
    let secondEnvironment = AnalysisDocument.ExecutionEnvironment(
        hostBuildIdentifier: "0.38.1", swiftLanguageVersion: "6.1", platform: "macOS",
        architecture: "arm64", swiftDataLensVersion: "0.20.1",
        swiftNumericCoreVersion: "0.7.0", rustNumericCoreVersion: "0.5.0",
        resolverFingerprint: "resolved-a"
    )
    let startedAt = Date(timeIntervalSince1970: 1_700_010_000)
    let fullRun = try AnalysisDocument.AnalysisRun.completed(
        in: document, modelBlockID: fullModel.id, retainedObservationCount: 3,
        startedAt: startedAt, completedAt: startedAt.addingTimeInterval(1),
        executionEnvironment: firstEnvironment
    )
    let boundedSelection = StatisticalScaleSelection(
        policy: boundedPolicy, inputObservationCount: 3, eligibleObservationCount: 3,
        selectedIndices: [0, 2]
    )
    let boundedRun = try AnalysisDocument.AnalysisRun.completed(
        in: document, modelBlockID: boundedModel.id, retainedObservationCount: 2,
        startedAt: startedAt, completedAt: startedAt.addingTimeInterval(1),
        scaleSelection: boundedSelection, executionEnvironment: secondEnvironment
    )
    let fullRunBlock = try AnalysisDocument.Block(
        title: "Full run", upstreamBlockIDs: [fullModel.id], payload: .run(fullRun)
    )
    let boundedRunBlock = try AnalysisDocument.Block(
        title: "Bounded run", upstreamBlockIDs: [boundedModel.id], payload: .run(boundedRun)
    )
    try document.append(fullRunBlock)
    try document.append(boundedRunBlock)
    let difference = try document.difference(
        baselineRunBlockID: fullRunBlock.id, candidateRunBlockID: boundedRunBlock.id
    )
    #expect(difference.sourceFingerprintMatches)
    #expect(difference.transformationLineageMatches)
    #expect(difference.validationTaskMatches)
    #expect(!difference.scalePolicyMatches)
    #expect(!difference.scaleSelectionMatches)
    #expect(!difference.replayInputsMatch)
    #expect(difference.environmentStatus == .changed)
    #expect(fullRun.executionEnvironment == firstEnvironment)
    #expect(try AnalysisDocument(jsonData: document.jsonData()) == document)

    var legacyObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(fullRun)) as? [String: Any]
    )
    legacyObject.removeValue(forKey: "executionEnvironment")
    let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
    let legacyRun = try JSONDecoder().decode(AnalysisDocument.AnalysisRun.self, from: legacyData)
    #expect(legacyRun.executionEnvironment == nil)
}

@Test func advancedDocumentEvidenceRecordsGamValidationAndBootstrapStability() throws {
    let rows = (0..<36).map { index -> String in
        let x = Double(index) / 7
        return "\(x),\(1.5 + sin(x) + 0.15 * x)"
    }
    let url = try scratchCSV("x,y\n" + rows.joined(separator: "\n") + "\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try AnalysisDocument.Source.make(from: url, table: CSVTable.load(contentsOf: url))
    let specification = StatisticalModelSpecification(
        strategy: .additiveGaussian,
        additive: AdditiveModelSpecification(terms: [.init(predictorIndex: 0, span: 0.8)])
    )
    let recipe = try AnalysisDocument.AdvancedModelRecipe(
        predictorColumns: ["x"], responseColumn: "y", specification: specification,
        validationConfiguration: ValidationConfiguration(
            foldCount: 3, partitioning: .blocked, specification: specification
        ),
        bootstrapConfiguration: BootstrapConfiguration(
            replicateCount: 3, minimumSuccessFraction: 0.5,
            specification: specification
        ),
        stabilityQueries: [[2.5]]
    )
    let modelBlock = try AnalysisDocument.Block(
        title: "Gaussian GAM", payload: .advancedModel(recipe)
    )
    var document = try AnalysisDocument(title: "GAM", source: source, blocks: [modelBlock])
    let fit = try AnalysisDocumentExecutor.fitAdvanced(
        document: document, sourceURL: url, modelBlockID: modelBlock.id
    )
    let evidence = try AnalysisDocumentExecutor.advancedEvidenceSnapshot(document: document, fit: fit)
    #expect(fit.model.kind == .additiveGaussian)
    #expect(fit.sourceRows == Array(0..<36))
    #expect(evidence.validation?.responseFamily == .gaussian)
    #expect(evidence.bootstrap?.attemptedReplicates == 3)
    let evidenceBlock = try AnalysisDocument.Block(
        title: "GAM evidence", upstreamBlockIDs: [modelBlock.id], payload: .advancedEvidence(evidence)
    )
    try document.append(evidenceBlock)
    #expect(try AnalysisDocument(jsonData: document.jsonData()) == document)
}

@Test func comparativeEvidencePairsFrozenRunsAndPreservesNonComparableVerdicts() throws {
    let url = try scratchCSV("x,y\n0,0\n1,1\n2,2\n3,3\n4,4\n5,5\n6,6\n7,7\n8,8\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try AnalysisDocument.Source.make(from: url, table: CSVTable.load(contentsOf: url))
    let rows = (0..<9).map { [Double($0)] }
    let response = (0..<9).map(Double.init)
    let baselineSpecification = StatisticalModelSpecification(
        strategy: .additiveGaussian,
        additive: AdditiveModelSpecification(terms: [.init(predictorIndex: 0, span: 0.9)])
    )
    let candidateSpecification = StatisticalModelSpecification(
        strategy: .additiveGaussian,
        additive: AdditiveModelSpecification(terms: [.init(predictorIndex: 0, span: 0.65)])
    )
    let baselineValidationConfiguration = ValidationConfiguration(
        foldCount: 3, partitioning: .blocked, seed: 11, specification: baselineSpecification
    )
    let candidateValidationConfiguration = ValidationConfiguration(
        foldCount: 3, partitioning: .blocked, seed: 11, specification: candidateSpecification
    )
    let mismatchedValidationConfiguration = ValidationConfiguration(
        foldCount: 3, partitioning: .blocked, seed: 12, specification: candidateSpecification
    )
    let baselineValidation = try #require(CrossValidation.evaluate(
        trainX: rows, trainY: response, configuration: baselineValidationConfiguration
    ))
    let candidateValidation = try #require(CrossValidation.evaluate(
        trainX: rows, trainY: response, configuration: candidateValidationConfiguration
    ))
    let mismatchedValidation = try #require(CrossValidation.evaluate(
        trainX: rows, trainY: response, configuration: mismatchedValidationConfiguration
    ))
    let baselineRecipe = try AnalysisDocument.AdvancedModelRecipe(
        predictorColumns: ["x"], responseColumn: "y", specification: baselineSpecification,
        validationConfiguration: baselineValidationConfiguration
    )
    let candidateRecipe = try AnalysisDocument.AdvancedModelRecipe(
        predictorColumns: ["x"], responseColumn: "y", specification: candidateSpecification,
        validationConfiguration: candidateValidationConfiguration
    )
    let mismatchedRecipe = try AnalysisDocument.AdvancedModelRecipe(
        predictorColumns: ["x"], responseColumn: "y", specification: candidateSpecification,
        validationConfiguration: mismatchedValidationConfiguration
    )
    let baselineModel = try AnalysisDocument.Block(title: "Broad GAM", payload: .advancedModel(baselineRecipe))
    let candidateModel = try AnalysisDocument.Block(title: "Narrow GAM", payload: .advancedModel(candidateRecipe))
    let mismatchedModel = try AnalysisDocument.Block(title: "Different folds GAM", payload: .advancedModel(mismatchedRecipe))
    var document = try AnalysisDocument(
        title: "Compared GAMs", source: source, blocks: [baselineModel, candidateModel, mismatchedModel]
    )
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let baselineRun = try AnalysisDocument.AnalysisRun.completed(
        in: document, modelBlockID: baselineModel.id, retainedObservationCount: 9,
        startedAt: startedAt, completedAt: startedAt.addingTimeInterval(1)
    )
    let candidateRun = try AnalysisDocument.AnalysisRun.completed(
        in: document, modelBlockID: candidateModel.id, retainedObservationCount: 9,
        startedAt: startedAt, completedAt: startedAt.addingTimeInterval(1)
    )
    let mismatchedRun = try AnalysisDocument.AnalysisRun.completed(
        in: document, modelBlockID: mismatchedModel.id, retainedObservationCount: 9,
        startedAt: startedAt, completedAt: startedAt.addingTimeInterval(1)
    )
    let baselineRunBlock = try AnalysisDocument.Block(
        title: "Broad run", upstreamBlockIDs: [baselineModel.id], payload: .run(baselineRun)
    )
    let candidateRunBlock = try AnalysisDocument.Block(
        title: "Narrow run", upstreamBlockIDs: [candidateModel.id], payload: .run(candidateRun)
    )
    let mismatchedRunBlock = try AnalysisDocument.Block(
        title: "Different folds run", upstreamBlockIDs: [mismatchedModel.id], payload: .run(mismatchedRun)
    )
    try document.append(baselineRunBlock)
    try document.append(candidateRunBlock)
    try document.append(mismatchedRunBlock)
    let diagnostics = FitDiagnostics(
        responseFamily: .gaussian, linkFunction: .identity, observationCount: 9,
        effectiveDegreesOfFreedom: 2, residualScale: 1
    )
    for (title, runBlock, validation) in [
        ("Broad evidence", baselineRunBlock, baselineValidation),
        ("Narrow evidence", candidateRunBlock, candidateValidation),
        ("Different folds evidence", mismatchedRunBlock, mismatchedValidation),
    ] {
        let evidence = try AnalysisDocument.AdvancedModelEvidence(
            sourceFingerprint: source.fingerprint, modelKind: .additiveGaussian,
            diagnostics: diagnostics, validation: validation
        )
        try document.append(try AnalysisDocument.Block(
            title: title, upstreamBlockIDs: [runBlock.id], payload: .advancedEvidence(evidence)
        ))
    }

    #expect(document.comparisonCandidateRunBlocks.map(\.id) == [baselineRunBlock.id, candidateRunBlock.id, mismatchedRunBlock.id])
    let comparisonID = try document.recordComparativeEvidence(
        baselineRunBlockID: baselineRunBlock.id, candidateRunBlockID: candidateRunBlock.id,
        at: startedAt.addingTimeInterval(2)
    )
    let comparisonBlock = try #require(document.blocks.first(where: { $0.id == comparisonID }))
    let comparison = try #require({ if case .comparison(let value) = comparisonBlock.payload { return value }; return nil }())
    #expect(comparison.verdict == .comparable)
    #expect(comparison.pairedObservationCount == 9)
    #expect(comparisonBlock.upstreamBlockIDs.count == 4)

    let nonComparableID = try document.recordComparativeEvidence(
        baselineRunBlockID: baselineRunBlock.id, candidateRunBlockID: mismatchedRunBlock.id,
        at: startedAt.addingTimeInterval(3)
    )
    let nonComparableBlock = try #require(document.blocks.first(where: { $0.id == nonComparableID }))
    let nonComparable = try #require({ if case .comparison(let value) = nonComparableBlock.payload { return value }; return nil }())
    #expect(nonComparable.verdict == .validationConfigurationMismatch)

    let synthesisID = try document.recordEvidenceSynthesis(
        title: "GAM evidence synthesis",
        question: "Does the narrower GAM improve held-out performance?",
        conclusion: "The paired validation record supports the narrower candidate for this source and fold plan.",
        assessment: .supported,
        caveats: ["This is held-out predictive evidence, not a causal conclusion."],
        evidenceBlockIDs: [comparisonID], at: startedAt.addingTimeInterval(4)
    )
    let synthesisBlock = try #require(document.blocks.first(where: { $0.id == synthesisID }))
    let synthesis = try #require({ if case .synthesis(let value) = synthesisBlock.payload { return value }; return nil }())
    #expect(synthesis.evidenceBlockIDs == [comparisonID])
    #expect(synthesis.assessment == .supported)
    #expect(document.evidenceSynthesisBlocks.map(\.id) == [synthesisID])
    #expect(throws: AnalysisDocumentError.invalidConfiguration) {
        _ = try document.recordEvidenceSynthesis(
            title: "Invalid synthesis", question: "Question", conclusion: "Conclusion",
            assessment: .inconclusive, caveats: ["A caveat"],
            evidenceBlockIDs: [baselineRunBlock.id]
        )
    }

    _ = try document.update(blockID: baselineModel.id, payload: .advancedModel(baselineRecipe))
    #expect(document.blocks.first(where: { $0.id == comparisonID })?.state == .stale)
    #expect(document.blocks.first(where: { $0.id == synthesisID })?.state == .stale)
    #expect(try AnalysisDocument(jsonData: document.jsonData()) == document)
}

@Test func validationPlansAreReusableNotebookInputsWithHistoricalRunSnapshots() throws {
    let url = try scratchCSV("x,y\n0,1\n1,2\n2,3\n3,5\n4,6\n5,8\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try AnalysisDocument.Source.make(from: url, table: CSVTable.load(contentsOf: url))
    let specification = StatisticalModelSpecification(
        strategy: .additiveGaussian,
        additive: AdditiveModelSpecification(terms: [.init(predictorIndex: 0)])
    )
    let policy = try AnalysisDocument.ValidationPlan.BootstrapPolicy(
        replicateCount: 8, minimumSuccessFraction: 0.75,
        confidenceLevel: 0.9, seed: 23
    )
    let plan = try AnalysisDocument.ValidationPlan(
        intendedUse: .orderedOrSpatial, foldCount: 3, partitioning: .blocked,
        seed: 17, bootstrap: policy, comparisonCohort: "candidate-gams"
    )
    let planBlock = try AnalysisDocument.Block(title: "Ordered GAM assessment", payload: .validationPlan(plan))
    let recipe = try AnalysisDocument.AdvancedModelRecipe(
        predictorColumns: ["x"], responseColumn: "y", specification: specification,
        validationConfiguration: plan.validationConfiguration(for: specification),
        bootstrapConfiguration: plan.bootstrapConfiguration(for: specification),
        stabilityQueries: [[2.5]], validationPlanBlockID: planBlock.id
    )
    let modelBlock = try AnalysisDocument.Block(
        title: "Candidate GAM", upstreamBlockIDs: [planBlock.id], payload: .advancedModel(recipe)
    )
    var document = try AnalysisDocument(
        title: "Reusable validation", source: source, blocks: [planBlock, modelBlock]
    )
    #expect(document.validationPlanBlocks == [planBlock])
    #expect(document.validationPlan(blockID: planBlock.id) == plan)
    #expect(plan.isComparable(to: plan))

    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let run = try AnalysisDocument.AnalysisRun.completed(
        in: document, modelBlockID: modelBlock.id, retainedObservationCount: 6,
        startedAt: startedAt, completedAt: startedAt.addingTimeInterval(1)
    )
    let runBlock = try AnalysisDocument.Block(
        title: "Validated GAM run", upstreamBlockIDs: [modelBlock.id], payload: .run(run)
    )
    try document.append(runBlock)
    #expect(run.recipe == .advancedModel(recipe))
    #expect(run.validationSeed == 17)
    #expect(run.bootstrapSeed == 23)
    #expect(try AnalysisDocument(jsonData: document.jsonData()) == document)

    let revisedPlan = try AnalysisDocument.ValidationPlan(
        intendedUse: .orderedOrSpatial, foldCount: 5, partitioning: .blocked,
        seed: 17, bootstrap: policy, comparisonCohort: "candidate-gams"
    )
    let stale = try document.update(blockID: planBlock.id, payload: .validationPlan(revisedPlan))
    #expect(stale == Set([modelBlock.id, runBlock.id]))
    #expect(document.blocks[1].state == .stale)
    #expect(document.blocks[2].state == .stale)
    #expect(run.recipe == .advancedModel(recipe))
}

@Test func currentModelsRejectMismatchedValidationPlanResolution() throws {
    let url = try scratchCSV("x,y\n0,1\n1,2\n2,3\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try AnalysisDocument.Source.make(from: url, table: CSVTable.load(contentsOf: url))
    let specification = StatisticalModelSpecification(
        strategy: .additiveGaussian,
        additive: AdditiveModelSpecification(terms: [.init(predictorIndex: 0)])
    )
    let plan = try AnalysisDocument.ValidationPlan(
        intendedUse: .orderedOrSpatial, foldCount: 3, partitioning: .blocked, seed: 4
    )
    let planBlock = try AnalysisDocument.Block(title: "Blocked folds", payload: .validationPlan(plan))
    let recipe = try AnalysisDocument.AdvancedModelRecipe(
        predictorColumns: ["x"], responseColumn: "y", specification: specification,
        validationConfiguration: ValidationConfiguration(
            foldCount: 5, partitioning: .blocked, seed: 4, specification: specification
        ), validationPlanBlockID: planBlock.id
    )
    let modelBlock = try AnalysisDocument.Block(
        title: "Mismatched model", upstreamBlockIDs: [planBlock.id], payload: .advancedModel(recipe)
    )
    #expect(throws: AnalysisDocumentError.invalidDependency(modelBlock.id)) {
        _ = try AnalysisDocument(title: "Invalid plan reference", source: source, blocks: [planBlock, modelBlock])
    }
}

@Test func advancedDocumentMultivariateFitRecordsActualSolverBackend() throws {
    var rows: [String] = []
    for index in 0..<42 {
        let x = Double(index % 7) / 3
        let z = Double(index / 7) / 2
        let response = 1 + 0.7 * x - 0.25 * z + 0.1 * x * z
        rows.append("\(x),\(z),\(response)")
    }
    let url = try scratchCSV("x,z,y\n" + rows.joined(separator: "\n") + "\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try AnalysisDocument.Source.make(from: url, table: CSVTable.load(contentsOf: url))
    let multivariate = MultivariateModelSpecification(
        terms: [.spline(.init(predictorIndex: 0, knotCount: 1)),
                .spline(.init(predictorIndex: 1, knotCount: 1))],
        penaltyWeight: 1, solverPreference: .denseQR
    )
    let specification = StatisticalModelSpecification(
        strategy: .multivariateGaussian, multivariate: multivariate
    )
    let recipe = try AnalysisDocument.AdvancedModelRecipe(
        predictorColumns: ["x", "z"], responseColumn: "y", specification: specification,
        validationConfiguration: ValidationConfiguration(
            foldCount: 3, partitioning: .blocked, specification: specification
        )
    )
    let block = try AnalysisDocument.Block(title: "Multivariate spline", payload: .advancedModel(recipe))
    let document = try AnalysisDocument(title: "Surface", source: source, blocks: [block])
    let fit = try AnalysisDocumentExecutor.fitAdvanced(
        document: document, sourceURL: url, modelBlockID: block.id
    )
    let evidence = try AnalysisDocumentExecutor.advancedEvidenceSnapshot(document: document, fit: fit)
    #expect(fit.model.kind == StatisticalModelKind.multivariateGaussian)
    #expect(fit.solverBackend == MultivariateSolverBackend.denseQR)
    #expect(evidence.requestedSolverPreference == .denseQR)
    #expect(evidence.solverBackend == .denseQR)
    #expect(evidence.sparseExecution == nil)
    #expect(fit.sourceRows == Array(0..<42))
}

@Test func advancedDocumentRecordsNativeSparseExecutionEvidence() throws {
    let levels = Array(0..<8)
    var rows: [String] = []
    for first in levels {
        for second in levels {
            for third in levels {
                let response = 1 + 0.25 * Double(first) - 0.1 * Double(second) + 0.05 * Double(third)
                rows.append("\(first),\(second),\(third),\(response)")
            }
        }
    }
    let url = try scratchCSV("a,b,c,y\n" + rows.joined(separator: "\n") + "\n")
    defer { try? FileManager.default.removeItem(at: url) }
    let source = try AnalysisDocument.Source.make(from: url, table: CSVTable.load(contentsOf: url))
    let terms: [MultivariateTermSpecification] = (0..<3).map {
        .categorical(.init(predictorIndex: $0, levels: levels, referenceLevel: 0))
    }
    let multivariate = MultivariateModelSpecification(
        terms: terms, penaltyWeight: 0.1, solverPreference: .sparseCGLS,
        maxIterations: 40, tolerance: 1e-8
    )
    let specification = StatisticalModelSpecification(
        strategy: .multivariateGaussian, multivariate: multivariate
    )
    let recipe = try AnalysisDocument.AdvancedModelRecipe(
        predictorColumns: ["a", "b", "c"], responseColumn: "y", specification: specification,
        validationConfiguration: ValidationConfiguration(
            foldCount: 2, partitioning: .blocked, specification: specification
        )
    )
    let block = try AnalysisDocument.Block(title: "Sparse factors", payload: .advancedModel(recipe))
    let document = try AnalysisDocument(title: "Sparse", source: source, blocks: [block])
    let fit = try AnalysisDocumentExecutor.fitAdvanced(
        document: document, sourceURL: url, modelBlockID: block.id
    )
    let evidence = try AnalysisDocumentExecutor.advancedEvidenceSnapshot(document: document, fit: fit)
    let sparse = try #require(evidence.sparseExecution)
    #expect(evidence.requestedSolverPreference == .sparseCGLS)
    #expect(evidence.solverBackend == .sparseCGLS)
    #expect(sparse.converged)
    #expect(sparse.designRows == rows.count)
    #expect(sparse.designColumns == 22)
    #expect(sparse.nonZeroCount < sparse.designRows * sparse.designColumns / 4)
    #expect(sparse.iterations > 0 && sparse.normalResidualNorm.isFinite)

    var savedDocument = document
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let run = try AnalysisDocument.AnalysisRun.completed(
        in: savedDocument, modelBlockID: block.id,
        retainedObservationCount: fit.sourceRows.count, startedAt: startedAt,
        completedAt: startedAt.addingTimeInterval(1)
    )
    #expect(run.transformationBlockIDs.isEmpty)
    #expect(run.validationSeed == recipe.validationConfiguration.seed)
    #expect(run.requestedSolverPreference == .sparseCGLS)
    let runBlock = try AnalysisDocument.Block(
        title: "Sparse analysis run", upstreamBlockIDs: [block.id], payload: .run(run),
        createdAt: startedAt, updatedAt: startedAt
    )
    try savedDocument.append(runBlock, at: startedAt)
    let evidenceBlock = try AnalysisDocument.Block(
        title: "Sparse numerical evidence", upstreamBlockIDs: [runBlock.id],
        payload: .advancedEvidence(evidence)
    )
    try savedDocument.append(evidenceBlock)
    #expect(try AnalysisDocument(jsonData: savedDocument.jsonData()) == savedDocument)

    var legacyEvidence = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(evidence)) as? [String: Any]
    )
    legacyEvidence.removeValue(forKey: "requestedSolverPreference")
    legacyEvidence.removeValue(forKey: "sparseExecution")
    let legacyEvidenceData = try JSONSerialization.data(withJSONObject: legacyEvidence)
    let migratedEvidence = try JSONDecoder().decode(
        AnalysisDocument.AdvancedModelEvidence.self, from: legacyEvidenceData
    )
    #expect(migratedEvidence.requestedSolverPreference == nil)
    #expect(migratedEvidence.sparseExecution == nil)
}

@Test func validationWorkbenchUsesOutOfFoldPredictionsAndSourceRows() async throws {
    let xs = (0..<20).map { Double($0) / 5 }
    let ys = xs.map { 1.5 * $0 + 0.25 }
    let model = ChartModel(
        rawX: xs, rawY: ys, gridX: xs, mean: ys,
        fittedAtTraining: ys, residuals: Array(repeating: 0, count: ys.count)
    )
    let loaded = LoadedChart(model: model, summary: nil, smootherName: "Loess",
                             xName: "time", yName: "value", keptIndices: Array(xs.indices))
    let source = try WorkbenchSource(displayName: "linear.csv", inputObservationCount: xs.count)
    let configuration = ValidationConfiguration(
        foldCount: 4, partitioning: .blocked,
        specification: .init(degree: 1, spans: [0.75], robustIterations: 0,
                             adaptiveContender: false)
    )
    let input = try WorkbenchInput(
        loaded: loaded, source: source, sourceRows: xs.indices.map { $0 + 100 },
        validationConfiguration: configuration
    )
    let output = try await ValidationWorkbenchTool().run(on: input)

    #expect(output.id == "cross-validation")
    #expect(output.metrics.first(where: { $0.id == "response-family" })?.text == "gaussian")
    #expect(try #require(output.metrics.first(where: { $0.id == "primary-score" })?.value) < 1e-8)
    #expect(output.table?.columns == ["source_row", "fold", "observed", "held_out_fit", "error"])
    #expect(output.table?.rows.allSatisfy { $0.first.map { Int($0) != nil } ?? false } == true)
}

@Test func continuousAssessmentReportsFitAndResidualStructure() throws {
    let model = ChartModel(
        rawX: [0, 1, 2, 3, 4], rawY: [1, 3, 5, 7, 9],
        gridX: [0, 1, 2, 3, 4], mean: [1, 3, 5, 7, 9],
        fittedAtTraining: [1, 3, 5, 7, 9], residuals: [0, 0, 0, 0, 0]
    )
    let result = try #require(ModelAssessment.make(from: model))
    #expect(result.responseScale == .continuous)
    #expect(result.rootMeanSquaredError == 0)
    #expect(result.rSquared == 1)
    #expect(result.devianceExplained == nil)
    #expect(result.largeResidualCount == 0)
}

@Test func binomialAssessmentUsesDevianceRatherThanRSquared() throws {
    let observed = [0.0, 0, 1, 1]
    let fitted = [0.1, 0.2, 0.8, 0.9]
    let residuals = zip(observed, fitted).map { ($0 - $1) / sqrt($1 * (1 - $1)) }
    let model = ChartModel(rawX: [0, 1, 2, 3], rawY: observed,
                           gridX: [0, 1, 2, 3], mean: fitted,
                           fittedAtTraining: fitted, residuals: residuals,
                           responseScale: .probability, residualKind: .pearson)
    let result = try #require(ModelAssessment.make(from: model))
    #expect(result.rSquared == nil)
    #expect(try #require(result.devianceExplained) > 0.5)
    #expect(try #require(result.deviancePerObservation) > 0)
}

@Test func countAssessmentFlagsWeakNullModel() throws {
    let observed = [0.0, 4, 0, 4]
    let fitted = [2.0, 2, 2, 2]
    let residuals = zip(observed, fitted).map { ($0 - $1) / sqrt($1) }
    let model = ChartModel(rawX: [0, 1, 2, 3], rawY: observed,
                           gridX: [0, 1, 2, 3], mean: fitted,
                           fittedAtTraining: fitted, residuals: residuals,
                           responseScale: .intensity, residualKind: .pearson)
    let result = try #require(ModelAssessment.make(from: model))
    #expect(abs(try #require(result.devianceExplained)) < 1e-12)
    #expect(result.findings.contains { $0.code == "low-deviance-explained" })
}
