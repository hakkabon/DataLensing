// SmootherChartView.swift
// DataLensing
//
// Spike chart: raw points + fitted curve + ±2 SE band, horizontally
// scrollable. Compiles only where SwiftUI/Charts exist (Apple
// platforms); the rest of the package — DataTables, ChartModel, the
// CLI — stays Foundation-only and portable.
//
// The chart marks (curve line, uncertainty hull) use the system
// accent colour so the chart respects the user's choice in System
// Preferences. Arrow-key probe stepping is supported via
// `steppedSelection(by:)` — see ContentView for the key handler.

#if canImport(SwiftUI) && canImport(Charts)
import Charts
import Foundation
import SwiftUI

/// Display planes available in `SmootherChartView`.
public struct ChartPlanes: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Background axis gridlines.
    public static let gridlines = ChartPlanes(rawValue: 1 << 0)
    /// Decimated raw sample points.
    public static let samples = ChartPlanes(rawValue: 1 << 1)
    /// Uncertainty hull (±2 SE band).
    public static let hull = ChartPlanes(rawValue: 1 << 2)
    /// Fitted smoothed curve.
    public static let curve = ChartPlanes(rawValue: 1 << 3)
    /// First derivative in a linked lower plot.
    public static let gradient = ChartPlanes(rawValue: 1 << 4)
    /// Training-point residuals in a linked lower plot.
    public static let residuals = ChartPlanes(rawValue: 1 << 5)
    /// Normal quantile plot of residuals.
    public static let qqPlot = ChartPlanes(rawValue: 1 << 6)

    /// All planes visible (default).
    public static let all: ChartPlanes = [.gridlines, .samples, .hull, .curve]
}

/// Raw points + fitted mean + uncertainty band for one smoother.
///
/// The scrolling-view contract: the view only ever reads `model`
/// (built once per fit). Scrolling re-renders cached arrays — it must
/// never trigger a refit (see the windowed refit policy).
///
/// Rendering is organized into decoupled display planes:
/// 1. **Gridlines Plane**: Axis gridlines and ticks (toggleable via `planes`).
/// 2. **Samples Plane**: Min-max decimated raw training points.
/// 3. **Hull Plane**: Shaded area mark showing the ±2 SE uncertainty band — drawn with the system accent colour at 18 % opacity.
/// 4. **Curve Plane**: Crisp vector line for the fitted smoothed mean — drawn in the system accent colour.
/// 5. **Probe Plane**: Interactive selection cursor and confidence interval readout.
///
/// The points layer is min-max decimated to one bucket per pixel of plot
/// width. Dense inputs build a background `DecimationIndex`, so viewport
/// changes query a segment tree instead of rescanning every source row.
///
/// Arrow-key probe stepping is supported: call `steppedSelection(by:)` from
/// the parent to advance/rewind `xSelection` to the nearest grid neighbour.
public struct SmootherChartView: View {
    private let model: ChartModel
    @Binding private var visibleDomain: ClosedRange<Double>?
    private let visibleLength: Double?
    @Binding private var xSelection: Double?
    private let xIsDate: Bool
    private let planes: ChartPlanes

    @State private var plotWidth: CGFloat = 600
    @State private var cachedPoints: (x: [Double], y: [Double]) = ([], [])
    @State private var cachedKey: DecimationKey?
    @State private var decimationIndex: DecimationIndex?

    /// Above this mark count, draw the already-decimated envelope in one
    /// Canvas pass rather than creating a Swift Charts `PointMark` per point.
    /// The curve, axes, selection, and accessibility semantics remain owned
    /// by Charts; Canvas only carries the dense visual layer.
    private static let canvasSampleThreshold = 256

    private struct DecimationKey: Hashable {
        let lower: Double?
        let upper: Double?
        let buckets: Int
        let count: Int
        let firstX: Double?
        let lastX: Double?
    }

    private struct SourceKey: Hashable {
        let fingerprint: Int
    }

    public init(
        model: ChartModel,
        planes: ChartPlanes = .all
    ) {
        self.model = model
        self._visibleDomain = .constant(nil)
        self.visibleLength = nil
        self._xSelection = .constant(nil)
        self.xIsDate = false
        self.planes = planes
    }

    public init(
        model: ChartModel,
        visibleDomain: Binding<ClosedRange<Double>?>,
        visibleLength: Double? = nil,
        planes: ChartPlanes = .all
    ) {
        self.model = model
        self._visibleDomain = visibleDomain
        self.visibleLength = visibleLength
        self._xSelection = .constant(nil)
        self.xIsDate = false
        self.planes = planes
    }

    /// Inspectable chart: tap/drag selects an x, drawn as a rule with
    /// the interpolated fitted value and ±2 SE band; the binding feeds viewer readouts.
    /// With `xIsDate`, x ticks render as UTC dates (day precision past
    /// two days of span, minute precision below).
    public init(
        model: ChartModel,
        visibleDomain: Binding<ClosedRange<Double>?>,
        visibleLength: Double? = nil,
        xSelection: Binding<Double?>,
        xIsDate: Bool = false,
        planes: ChartPlanes = .all
    ) {
        self.model = model
        self._visibleDomain = visibleDomain
        self.visibleLength = visibleLength
        self._xSelection = xSelection
        self.xIsDate = xIsDate
        self.planes = planes
    }

    public var body: some View {
        let key = decimationKey
        let currentPoints = currentDecimatedPoints(for: key)
        VStack(spacing: 8) {
            Group {
                if let visibleLength {
                    chart(points: currentPoints)
                        .chartXVisibleDomain(length: visibleLength)
                } else {
                    chart(points: currentPoints)
                }
            }
            .chartScrollableAxes(.horizontal)
            .chartXSelection(value: $xSelection)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    ZStack {
                        if rendersSamplesOnCanvas(points: currentPoints) {
                            denseSamplesCanvas(points: currentPoints, proxy: proxy, geo: geo)
                        }
                        Color.clear
                            .onChange(of: overlayKey(proxy: proxy, geo: geo)) { _, key in
                                if key.width != plotWidth {
                                    plotWidth = key.width
                                }
                                if key.domain != visibleDomain {
                                    visibleDomain = key.domain
                                }
                            }
                    }
                }
            }

            if planes.contains(.gradient) { gradientChart }
            if planes.contains(.residuals) { residualChart }
            if planes.contains(.qqPlot) { qqChart }
        }
        .task(id: key) {
            guard planes.contains(.samples) else {
                cachedPoints = ([], [])
                cachedKey = key
                return
            }
            guard let decimationIndex else { return }
            cachedPoints = decimationIndex.decimate(visible: visibleDomain, buckets: key.buckets)
            cachedKey = key
        }
        .task(id: sourceKey) {
            decimationIndex = nil
            cachedPoints = ([], [])
            cachedKey = nil
            let x = model.rawX
            let y = model.rawY
            let index = await Task.detached(priority: .userInitiated) {
                DecimationIndex(x: x, y: y)
            }.value
            guard !Task.isCancelled else { return }
            decimationIndex = index
            let currentKey = decimationKey
            guard planes.contains(.samples) else { return }
            cachedPoints = index.decimate(visible: visibleDomain, buckets: currentKey.buckets)
            cachedKey = currentKey
        }
    }

    /// Compute or reuse decimated points so hover/selection gestures never re-decimate.
    private var decimationKey: DecimationKey {
        DecimationKey(
            lower: visibleDomain?.lowerBound, upper: visibleDomain?.upperBound,
            buckets: max(1, Int(plotWidth)), count: model.rawX.count,
            firstX: model.rawX.first, lastX: model.rawX.last
        )
    }

    private var sourceKey: SourceKey {
        SourceKey(
            fingerprint: model.rawPointFingerprint
        )
    }

    private func currentDecimatedPoints(for key: DecimationKey) -> (x: [Double], y: [Double]) {
        guard planes.contains(.samples) else { return ([], []) }
        if cachedKey == key { return cachedPoints }
        guard let decimationIndex else { return ([], []) }
        return decimationIndex.decimate(visible: visibleDomain, buckets: key.buckets)
    }

    private func chart(points: (x: [Double], y: [Double])) -> some View {
        Chart {
            // Plane 1: Raw Samples
            if planes.contains(.samples) {
                if rendersSamplesOnCanvas(points: points) {
                    // Keep data-domain anchors in Charts so the Canvas layer
                    // cannot accidentally collapse the raw-data y extent.
                    ForEach(sampleScaleAnchors(from: points).indices, id: \.self) { i in
                        let anchor = sampleScaleAnchors(from: points)[i]
                        PointMark(x: .value("x", anchor.x), y: .value("y", anchor.y))
                            .foregroundStyle(.clear)
                    }
                } else {
                    ForEach(points.x.indices, id: \.self) { i in
                        PointMark(
                            x: .value("x", points.x[i]),
                            y: .value("y", points.y[i])
                        )
                        .foregroundStyle(.secondary)
                        .opacity(0.4)
                    }
                }
            }

            // Plane 2: Uncertainty Hull (±2 SE band)
            if planes.contains(.hull), model.hasBand {
                ForEach(model.gridX.indices, id: \.self) { j in
                    AreaMark(
                        x: .value("x", model.gridX[j]),
                        yStart: .value("lower", model.lower[j]),
                        yEnd: .value("upper", model.upper[j])
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.18))
                }
            }

            // Plane 3: Smoothed Fitted Curve
            if planes.contains(.curve) {
                ForEach(model.gridX.indices, id: \.self) { j in
                    LineMark(
                        x: .value("x", model.gridX[j]),
                        y: .value("fit", model.mean[j])
                    )
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }

            // Plane 4: Interactive Probe / RuleMark
            if let selected = xSelection,
               let band = model.interpolatedBand(at: selected)
            {
                RuleMark(x: .value("selected", selected))
                    .foregroundStyle(.primary)
                    .annotation(position: .top, alignment: .center) {
                        selectionLabel(x: selected, band: band)
                    }
            }
        }
        .chartXAxis {
            if xIsDate,
               let lo = model.rawX.min(), let hi = model.rawX.max(), hi > lo
            {
                dateAxisContent(range: lo...hi)
            } else {
                axisContent
            }
        }
        .chartYAxis { axisContent }
        .chartYAxisLabel(model.responseScale.rawValue)
    }

    private func rendersSamplesOnCanvas(points: (x: [Double], y: [Double])) -> Bool {
        planes.contains(.samples) && points.x.count > Self.canvasSampleThreshold
    }

    private func sampleScaleAnchors(from points: (x: [Double], y: [Double])) -> [(x: Double, y: Double)] {
        guard let minimum = points.y.enumerated().min(by: { $0.element < $1.element }),
              let maximum = points.y.enumerated().max(by: { $0.element < $1.element }),
              points.x.indices.contains(minimum.offset), points.x.indices.contains(maximum.offset)
        else { return [] }
        return [
            (points.x[minimum.offset], minimum.element),
            (points.x[maximum.offset], maximum.element),
        ]
    }

    private func denseSamplesCanvas(
        points: (x: [Double], y: [Double]), proxy: ChartProxy, geo: GeometryProxy
    ) -> some View {
        Canvas { context, _ in
            guard let anchor = proxy.plotFrame else { return }
            let frame = geo[anchor]
            var dots = Path()
            for index in points.x.indices where points.y.indices.contains(index) {
                guard points.x[index].isFinite, points.y[index].isFinite,
                      let x = proxy.position(forX: points.x[index]),
                      let y = proxy.position(forY: points.y[index])
                else { continue }
                let center = CGPoint(x: x, y: y)
                guard frame.insetBy(dx: -1, dy: -1).contains(center) else { continue }
                dots.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
            }
            context.fill(dots, with: .color(.secondary.opacity(0.4)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var gradientChart: some View {
        Chart {
            ForEach(model.gridX.indices, id: \.self) { i in
                if model.gradient.indices.contains(i), model.gradient[i].isFinite {
                    LineMark(x: .value("x", model.gridX[i]),
                             y: .value("gradient", model.gradient[i]))
                        .foregroundStyle(.orange)
                }
            }
            RuleMark(y: .value("zero", 0)).foregroundStyle(.secondary.opacity(0.5))
        }
        .frame(minHeight: 100, idealHeight: 130, maxHeight: 170)
        .chartYAxisLabel("dŷ/dx")
    }

    private var residualChart: some View {
        let step = max(1, model.rawX.count / 2_000)
        let indices = Array(stride(from: 0, to: model.rawX.count, by: step))
        return Chart {
            ForEach(indices, id: \.self) { i in
                if model.residuals.indices.contains(i), model.residuals[i].isFinite {
                    PointMark(x: .value("x", model.rawX[i]),
                              y: .value("residual", model.residuals[i]))
                        .foregroundStyle(.purple.opacity(0.55))
                }
            }
            RuleMark(y: .value("zero", 0)).foregroundStyle(.secondary)
        }
        .frame(minHeight: 100, idealHeight: 130, maxHeight: 170)
        .chartYAxisLabel(model.residualKind.rawValue)
    }

    private var qqChart: some View {
        let qq = model.residualQQ
        let step = max(1, qq.observed.count / 2_000)
        let indices = Array(stride(from: 0, to: qq.observed.count, by: step))
        return Chart {
            ForEach(indices, id: \.self) { i in
                PointMark(x: .value("Normal quantile", qq.theoretical[i]),
                          y: .value("Residual quantile", qq.observed[i]))
                    .foregroundStyle(.teal.opacity(0.6))
            }
        }
        .frame(minHeight: 100, idealHeight: 130, maxHeight: 170)
        .chartXAxisLabel("Normal quantile")
        .chartYAxisLabel("Residual quantile")
    }

    private func selectionLabel(
        x: Double,
        band: (mean: Double, lower: Double, upper: Double)
    ) -> some View {
        Group {
            if model.hasBand {
                Text(String(
                    format: "x: %.2f · %@: %.2f (95%% CI: [%.2f, %.2f])",
                    x, model.responseScale.rawValue.lowercased(),
                    band.mean, band.lower, band.upper
                ))
            } else {
                Text(String(format: "x: %.2f · %@: %.2f", x,
                            model.responseScale.rawValue.lowercased(), band.mean))
            }
        }
        .font(.caption)
        .padding(4)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Shared axis furniture: ~6 ticks with gridlines (toggleable via planes)
    /// and adaptive precision (integers stay bare, fractions get up to 3 places).
    private var axisContent: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
            if planes.contains(.gridlines) {
                AxisGridLine()
            }
            AxisTick()
            AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...3)))
        }
    }

    /// Date axis furniture for epoch-second x values: UTC labels, day
    /// precision past two days of data span, minute precision below.
    @AxisContentBuilder
    private func dateAxisContent(range: ClosedRange<Double>) -> some AxisContent {
        let dayPrecision = range.upperBound - range.lowerBound > 2 * 86400
        AxisMarks(values: .automatic(desiredCount: 6)) { value in
            if planes.contains(.gridlines) {
                AxisGridLine()
            }
            AxisTick()
            if let epoch = value.as(Double.self) {
                AxisValueLabel(Self.dateLabel(epoch, dayPrecision: dayPrecision))
            }
        }
    }

    private static func dateLabel(_ epoch: Double, dayPrecision: Bool) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dayPrecision ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: epoch))
    }

    /// Equatable snapshot of the live viewport for `onChange` tracking:
    /// assignments only fire downstream when the window actually moves.
    private struct OverlayKey: Equatable {
        var minX: Double?
        var maxX: Double?
        var width: CGFloat

        var domain: ClosedRange<Double>? {
            guard let minX, let maxX, maxX >= minX else { return nil }
            return minX...maxX
        }
    }

    private func overlayKey(proxy: ChartProxy, geo: GeometryProxy) -> OverlayKey {
        let width = geo.size.width
        guard let anchor = proxy.plotFrame else {
            return OverlayKey(minX: nil, maxX: nil, width: width)
        }
        let frame = geo[anchor]
        guard let lo = proxy.value(atX: frame.minX, as: Double.self),
              let hi = proxy.value(atX: frame.maxX, as: Double.self)
        else {
            return OverlayKey(minX: nil, maxX: nil, width: width)
        }
        return OverlayKey(minX: min(lo, hi), maxX: max(lo, hi), width: width)
    }

    // MARK: - Arrow-key probe stepping

    /// Returns the index of the grid point nearest to `x`, or `nil`
    /// when the grid is empty.
    public func nearestGridIndex(for x: Double) -> Int? {
        guard !model.gridX.isEmpty else { return nil }
        var best = 0
        var bestDist = abs(model.gridX[0] - x)
        for i in 1 ..< model.gridX.count {
            let d = abs(model.gridX[i] - x)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    /// Returns the `x` value of the grid point that is `steps` positions
    /// away from the one nearest to the current `xSelection`.
    ///
    /// Stepping beyond the grid boundary clamps to the first/last point.
    /// Returns `nil` when the grid is empty.
    public func steppedSelection(by steps: Int) -> Double? {
        guard !model.gridX.isEmpty else { return nil }
        let origin = xSelection.flatMap { nearestGridIndex(for: $0) } ?? 0
        let target = max(0, min(model.gridX.count - 1, origin + steps))
        return model.gridX[target]
    }
}
#endif
