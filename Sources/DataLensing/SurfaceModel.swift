import DataLens
import DataTables
import Foundation

/// Regular two-predictor response grid prepared for contour or surface rendering.
public struct SurfaceModel: Sendable {
    public let xGrid: [Double]
    public let yGrid: [Double]
    /// Row-major values: `mean[yIndex * xGrid.count + xIndex]`.
    public let mean: [Double]
    public let gradientX: [Double]
    public let gradientY: [Double]
    public let responseScale: ResponseScale

    public var valueRange: ClosedRange<Double>? {
        let finite = mean.filter(\.isFinite)
        guard let low = finite.min(), let high = finite.max() else { return nil }
        return low...high
    }

    public static func make(
        trainX: [[Double]], fit: FittedSmoother, xCount: Int = 50, yCount: Int = 50
    ) -> SurfaceModel? {
        guard xCount > 1, yCount > 1, !fit.keptIndices.isEmpty else { return nil }
        let kept = fit.keptIndices.compactMap { trainX.indices.contains($0) ? trainX[$0] : nil }
        guard kept.count == fit.keptIndices.count, kept.allSatisfy({ $0.count == 2 }),
              let xLow = kept.map({ $0[0] }).min(), let xHigh = kept.map({ $0[0] }).max(),
              let yLow = kept.map({ $0[1] }).min(), let yHigh = kept.map({ $0[1] }).max(),
              xHigh > xLow, yHigh > yLow else { return nil }
        let xs = grid(low: xLow, high: xHigh, count: xCount)
        let ys = grid(low: yLow, high: yHigh, count: yCount)
        let queries = ys.flatMap { y in xs.map { x in [x, y] } }
        return assemble(xs: xs, ys: ys, fit: fit, queries: queries,
                        mean: fit.predict(queries))
    }

    public static func makeConcurrently(
        trainX: [[Double]], fit: FittedSmoother, xCount: Int = 50, yCount: Int = 50
    ) async throws -> SurfaceModel? {
        guard xCount > 1, yCount > 1, !fit.keptIndices.isEmpty else { return nil }
        let kept = fit.keptIndices.compactMap { trainX.indices.contains($0) ? trainX[$0] : nil }
        guard kept.count == fit.keptIndices.count, kept.allSatisfy({ $0.count == 2 }),
              let xLow = kept.map({ $0[0] }).min(), let xHigh = kept.map({ $0[0] }).max(),
              let yLow = kept.map({ $0[1] }).min(), let yHigh = kept.map({ $0[1] }).max(),
              xHigh > xLow, yHigh > yLow else { return nil }
        let xs = grid(low: xLow, high: xHigh, count: xCount)
        let ys = grid(low: yLow, high: yHigh, count: yCount)
        let queries = ys.flatMap { y in xs.map { x in [x, y] } }
        let mean = try await fit.predictConcurrently(queries)
        return try await assembleConcurrently(xs: xs, ys: ys, fit: fit,
                                              queries: queries, mean: mean)
    }

    private static func grid(low: Double, high: Double, count: Int) -> [Double] {
        (0..<count).map { low + (high - low) * Double($0) / Double(count - 1) }
    }

    private static func scale(for fit: FittedSmoother) -> ResponseScale {
        guard case .likelihood(let likelihood) = fit else { return .continuous }
        switch likelihood.family {
        case .gaussian: return .continuous
        case .binomial: return .probability
        case .poisson: return .intensity
        }
    }

    private static func assemble(
        xs: [Double], ys: [Double], fit: FittedSmoother,
        queries: [[Double]], mean: [Double]
    ) -> SurfaceModel? {
        let gradients = fit.gradients(at: queries)
        return finish(xs: xs, ys: ys, fit: fit, mean: mean, gradients: gradients)
    }

    private static func assembleConcurrently(
        xs: [Double], ys: [Double], fit: FittedSmoother,
        queries: [[Double]], mean: [Double]
    ) async throws -> SurfaceModel? {
        let gradients = try await fit.gradientsConcurrently(at: queries)
        return finish(xs: xs, ys: ys, fit: fit, mean: mean, gradients: gradients)
    }

    private static func finish(
        xs: [Double], ys: [Double], fit: FittedSmoother,
        mean: [Double], gradients: [[Double]?]
    ) -> SurfaceModel? {
        guard mean.count == xs.count * ys.count, gradients.count == mean.count else { return nil }
        return SurfaceModel(
            xGrid: xs, yGrid: ys, mean: mean,
            gradientX: gradients.map { $0?.first ?? .nan },
            gradientY: gradients.map { gradient in
                guard let gradient, gradient.count > 1 else { return .nan }
                return gradient[1]
            },
            responseScale: scale(for: fit)
        )
    }
}

public struct LoadedSurface: Sendable {
    public let model: SurfaceModel
    public let xName: String
    public let yName: String
    public let responseName: String
    public let summary: TuningSummary
}

/// Load and automatically tune a two-predictor surface from a CSV file.
public func loadSurfaceConcurrently(
    from url: URL, xColumn: String, yColumn: String, responseColumn: String,
    budget: TuningBudget = .interactive, gridSize: Int = 50
) async throws -> LoadedSurface {
    let table = try CSVTable.load(contentsOf: url)
    guard let trainX = table.numericMatrix(columns: [xColumn, yColumn]),
          let trainY = table.doubles(forColumn: responseColumn) else {
        throw ChartLoadError.badColumn("\(xColumn), \(yColumn), or \(responseColumn)")
    }
    guard let tuned = AutomaticSmoother.fit(
        trainX: trainX, trainY: trainY, degree: budget.degree, spans: budget.spans,
        robustIterations: budget.robustIterations, droppingMissing: true,
        adaptiveContender: budget.adaptiveContender
    ) else { throw ChartLoadError.fitFailed }
    guard let model = try await SurfaceModel.makeConcurrently(
        trainX: trainX, fit: tuned.fit, xCount: gridSize, yCount: gridSize
    ) else { throw ChartLoadError.modelFailed }
    return LoadedSurface(model: model, xName: xColumn, yName: yColumn,
                         responseName: responseColumn, summary: tuned.summary)
}
