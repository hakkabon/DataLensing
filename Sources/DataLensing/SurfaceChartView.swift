#if canImport(SwiftUI)
import SwiftUI

/// Canvas heatmap for a regular two-predictor smoothing grid.
/// Canvas avoids creating thousands of SwiftUI/Charts mark nodes.
public struct SurfaceChartView: View {
    private let model: SurfaceModel
    private let xLabel: String
    private let yLabel: String

    public init(model: SurfaceModel, xLabel: String, yLabel: String) {
        self.model = model
        self.xLabel = xLabel
        self.yLabel = yLabel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(model.responseScale.rawValue) surface")
                .font(.headline)
            Canvas { context, size in
                guard let range = model.valueRange, !model.xGrid.isEmpty, !model.yGrid.isEmpty else { return }
                let cellWidth = size.width / CGFloat(model.xGrid.count)
                let cellHeight = size.height / CGFloat(model.yGrid.count)
                let span = max(range.upperBound - range.lowerBound, .leastNonzeroMagnitude)
                for y in model.yGrid.indices {
                    for x in model.xGrid.indices {
                        let value = model.mean[y * model.xGrid.count + x]
                        guard value.isFinite else { continue }
                        let t = min(1, max(0, (value - range.lowerBound) / span))
                        let color = Color(hue: 0.67 * (1 - t), saturation: 0.82, brightness: 0.92)
                        let rect = CGRect(x: CGFloat(x) * cellWidth,
                                          y: size.height - CGFloat(y + 1) * cellHeight,
                                          width: cellWidth + 0.5, height: cellHeight + 0.5)
                        context.fill(Path(rect), with: .color(color))
                    }
                }

                // Sparse normalized trend vectors expose the direction of
                // steepest response increase without overcrowding the raster.
                let strideX = max(1, model.xGrid.count / 10)
                let strideY = max(1, model.yGrid.count / 10)
                let arrowLength = min(cellWidth * CGFloat(strideX), cellHeight * CGFloat(strideY)) * 0.32
                for y in stride(from: 0, to: model.yGrid.count, by: strideY) {
                    for x in stride(from: 0, to: model.xGrid.count, by: strideX) {
                        let index = y * model.xGrid.count + x
                        let gx = model.gradientX[index]
                        let gy = model.gradientY[index]
                        let magnitude = hypot(gx, gy)
                        guard magnitude.isFinite, magnitude > 0 else { continue }
                        let center = CGPoint(
                            x: (CGFloat(x) + 0.5) * cellWidth,
                            y: size.height - (CGFloat(y) + 0.5) * cellHeight
                        )
                        let dx = CGFloat(gx / magnitude) * arrowLength
                        let dy = -CGFloat(gy / magnitude) * arrowLength
                        var arrow = Path()
                        arrow.move(to: CGPoint(x: center.x - dx, y: center.y - dy))
                        arrow.addLine(to: CGPoint(x: center.x + dx, y: center.y + dy))
                        context.stroke(arrow, with: .color(.black.opacity(0.48)), lineWidth: 1)
                    }
                }
            }
            .accessibilityLabel("Smoothed response surface for \(xLabel) and \(yLabel)")
            HStack {
                Text(yLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(xLabel).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
