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

/// Raw points + fitted mean + uncertainty band for one smoother.
///
/// The scrolling-view contract: the view only ever reads `model`
/// (built once per fit). Scrolling re-renders cached arrays — it must
/// never trigger a refit (see the windowed refit policy).
///
/// The points layer is min-max decimated to one bucket per pixel of
/// plot width, restricted to the tracked visible domain when one is
/// known; the fitted curve always renders at full grid resolution.
/// Below ~2 points per pixel decimation is a no-op, so small datasets
/// render exactly.
///
/// `visibleDomain` reports the live x-window (via `ChartProxy`) for
/// coverage readouts and re-decimation; `visibleLength` optionally
/// constrains the initial window (the large-series policy in
/// `ChartWindow`). Both `nil` preserves the original full-view chart.
public struct SmootherChartView: View {
    private let model: ChartModel
    @Binding private var visibleDomain: ClosedRange<Double>?
    private let visibleLength: Double?
    @Binding private var xSelection: Double?
    private let xIsDate: Bool
    @State private var plotWidth: CGFloat = 600

    public init(model: ChartModel) {
        self.model = model
        self._visibleDomain = .constant(nil)
        self.visibleLength = nil
        self._xSelection = .constant(nil)
        self.xIsDate = false
    }

    public init(
        model: ChartModel,
        visibleDomain: Binding<ClosedRange<Double>?>,
        visibleLength: Double? = nil
    ) {
        self.model = model
        self._visibleDomain = visibleDomain
        self.visibleLength = visibleLength
        self._xSelection = .constant(nil)
        self.xIsDate = false
    }

    /// Inspectable chart: tap/drag selects an x, drawn as a rule with
    /// the interpolated fitted value; the binding feeds viewer readouts.
    /// With `xIsDate`, x ticks render as UTC dates (day precision past
    /// two days of span, minute precision below).
    public init(
        model: ChartModel,
        visibleDomain: Binding<ClosedRange<Double>?>,
        visibleLength: Double? = nil,
        xSelection: Binding<Double?>,
        xIsDate: Bool = false
    ) {
        self.model = model
        self._visibleDomain = visibleDomain
        self.visibleLength = visibleLength
        self._xSelection = xSelection
        self.xIsDate = xIsDate
    }

    public var body: some View {
        let buckets = max(1, Int(plotWidth))
        let points = Decimation.decimate(x: model.rawX, y: model.rawY, visible: visibleDomain, buckets: buckets)
        Group {
            if let visibleLength {
                chart(points: points)
                    .chartXVisibleDomain(length: visibleLength)
            } else {
                chart(points: points)
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

    private func chart(points: (x: [Double], y: [Double])) -> some View {
        Chart {
            ForEach(points.x.indices, id: \.self) { i in
                PointMark(
                    x: .value("x", points.x[i]),
                    y: .value("y", points.y[i])
                )
                .foregroundStyle(.secondary)
                .opacity(0.5)
            }
            ForEach(model.gridX.indices, id: \.self) { j in
                AreaMark(
                    x: .value("x", model.gridX[j]),
                    yStart: .value("lower", model.lower[j]),
                    yEnd: .value("upper", model.upper[j])
                )
                .foregroundStyle(.blue.opacity(0.15))
            }
            ForEach(model.gridX.indices, id: \.self) { j in
                LineMark(
                    x: .value("x", model.gridX[j]),
                    y: .value("fit", model.mean[j])
                )
                .foregroundStyle(.blue)
            }
            if let selected = xSelection,
               let fitted = model.interpolatedMean(at: selected)
            {
                RuleMark(x: .value("selected", selected))
                    .foregroundStyle(.primary)
                    .annotation(position: .top, alignment: .center) {
                        selectionLabel(x: selected, fitted: fitted)
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

    private func selectionLabel(x: Double, fitted: Double) -> some View {
        Text("x \(x, format: .number.precision(.fractionLength(2))) · fit \(fitted, format: .number.precision(.fractionLength(2)))")
            .font(.caption)
            .padding(4)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    /// Shared axis furniture: ~6 ticks with gridlines and adaptive
    /// precision (integers stay bare, fractions get up to 3 places).
    /// A named helper (not inline closures) to keep the Chart
    /// type-check tractable — Charts DSL + big closures exhaust it.
    private var axisContent: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 6)) { _ in
            AxisGridLine()
            AxisTick()
            AxisValueLabel(format: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...3)))
        }
    }

    /// Date axis furniture for epoch-second x values: UTC labels, day
    /// precision past two days of data span, minute precision below.
    /// A per-call formatter (never shared) keeps this Sendable-clean.
    @AxisContentBuilder
    private func dateAxisContent(range: ClosedRange<Double>) -> some AxisContent {
        let dayPrecision = range.upperBound - range.lowerBound > 2 * 86400
        AxisMarks(values: .automatic(desiredCount: 6)) { value in
            AxisGridLine()
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
