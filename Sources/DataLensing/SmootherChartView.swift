// SmootherChartView.swift
// DataLensing
//
// Spike chart: raw points + fitted curve + ±2 SE band, horizontally
// scrollable. Compiles only where SwiftUI/Charts exist (Apple
// platforms); the rest of the package — DataTables, ChartModel, the
// CLI — stays Foundation-only and portable.

#if canImport(SwiftUI) && canImport(Charts)
import Charts
import SwiftUI

/// Raw points + fitted mean + uncertainty band for one smoother.
///
/// The scrolling-view contract this spikes: the view only ever reads
/// `model` (built once per fit). Scrolling re-renders cached arrays —
/// it must never trigger a refit (see the windowed refit policy).
///
/// The points layer is min-max decimated to one bucket per pixel of
/// view width (`Decimation`); the fitted curve always renders at full
/// grid resolution. Below ~2 points per pixel decimation is a no-op,
/// so small datasets render exactly.
public struct SmootherChartView: View {
    private let model: ChartModel

    public init(model: ChartModel) {
        self.model = model
    }

    public var body: some View {
        GeometryReader { proxy in
            let buckets = max(1, Int(proxy.size.width))
            let points = Decimation.decimate(x: model.rawX, y: model.rawY, buckets: buckets)
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
            }
            .chartScrollableAxes(.horizontal)
        }
    }
}
#endif
