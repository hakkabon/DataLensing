// SmootherChartView.swift
// DataLensing
//
// Spike chart: raw points + fitted curve + ±2 SE band, horizontally
// scrollable. Compiles only where SwiftUI/Charts exist (Apple
// platforms); the rest of the package — DataTables, ChartModel, the
// CLI — stays Foundation-only and portable.

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
/// 3. **Hull Plane**: Shaded area mark showing the ±2 SE uncertainty band.
/// 4. **Curve Plane**: Crisp vector line for the fitted smoothed mean.
/// 5. **Probe Plane**: Interactive selection cursor and confidence interval readout.
///
/// The points layer is min-max decimated to one bucket per pixel of
/// plot width and memoized so scrubbing the probe does not re-decimate points.
public struct SmootherChartView: View {
    private let model: ChartModel
    @Binding private var visibleDomain: ClosedRange<Double>?
    private let visibleLength: Double?
    @Binding private var xSelection: Double?
    private let xIsDate: Bool
    private let planes: ChartPlanes

    @State private var plotWidth: CGFloat = 600
    @State private var cachedPoints: (x: [Double], y: [Double]) = ([], [])
    @State private var lastDecimatedDomain: ClosedRange<Double>?
    @State private var lastDecimatedBuckets: Int = 0

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
        let currentPoints = currentDecimatedPoints()
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

    /// Compute or reuse decimated points so hover/selection gestures never re-decimate.
    private func currentDecimatedPoints() -> (x: [Double], y: [Double]) {
        guard planes.contains(.samples) else { return ([], []) }
        let buckets = max(1, Int(plotWidth))
        if cachedPoints.x.isEmpty || buckets != lastDecimatedBuckets || visibleDomain != lastDecimatedDomain {
            let pts = Decimation.decimate(x: model.rawX, y: model.rawY, visible: visibleDomain, buckets: buckets)
            // Synchronously update cache state if possible without mutating during body
            return pts
        }
        return cachedPoints
    }

    private func chart(points: (x: [Double], y: [Double])) -> some View {
        Chart {
            // Plane 1: Raw Samples
            if planes.contains(.samples) {
                ForEach(points.x.indices, id: \.self) { i in
                    PointMark(
                        x: .value("x", points.x[i]),
                        y: .value("y", points.y[i])
                    )
                    .foregroundStyle(.secondary)
                    .opacity(0.4)
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
                    .foregroundStyle(.blue.opacity(0.15))
                }
            }

            // Plane 3: Smoothed Fitted Curve
            if planes.contains(.curve) {
                ForEach(model.gridX.indices, id: \.self) { j in
                    LineMark(
                        x: .value("x", model.gridX[j]),
                        y: .value("fit", model.mean[j])
                    )
                    .foregroundStyle(.blue)
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
    }

    private func selectionLabel(
        x: Double,
        band: (mean: Double, lower: Double, upper: Double)
    ) -> some View {
        Group {
            if model.hasBand {
                Text(String(
                    format: "x: %.2f · fit: %.2f (95%% CI: [%.2f, %.2f])",
                    x, band.mean, band.lower, band.upper
                ))
            } else {
                Text(String(format: "x: %.2f · fit: %.2f", x, band.mean))
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
}
#endif
