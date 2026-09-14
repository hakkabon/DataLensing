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
public struct SmootherChartView: View {
    private let model: ChartModel

    public init(model: ChartModel) {
        self.model = model
    }

    public var body: some View {
        Chart {
            ForEach(model.rawX.indices, id: \.self) { i in
                PointMark(
                    x: .value("x", model.rawX[i]),
                    y: .value("y", model.rawY[i])
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
#endif
