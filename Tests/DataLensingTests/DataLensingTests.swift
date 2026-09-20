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
    #expect(outputs.map(\.id) == ["descriptive-statistics", "model-assessment", "residual-review"])
    #expect(outputs[0].metrics.first(where: { $0.id == "retained-observations" })?.value == 3)
    #expect(outputs[2].table?.rows.first == ["12", "2", "20", "5", "15", "15"])

    #expect(throws: WorkbenchError.duplicateToolIdentifier("descriptive-statistics")) {
        _ = try WorkbenchCatalog(tools: [DescriptiveWorkbenchTool(), DescriptiveWorkbenchTool()])
    }
    await #expect(throws: WorkbenchError.unknownTool("missing")) {
        _ = try await WorkbenchCatalog.builtIns.run(id: "missing", on: input)
    }
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

    let json = try #require(String(data: data, encoding: .utf8))
    let unsupported = try #require(json.replacingOccurrences(
        of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 99"
    ).data(using: .utf8))
    #expect(throws: WorkbenchSessionError.unsupportedSchema(99)) {
        _ = try WorkbenchSession(jsonData: unsupported)
    }
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
