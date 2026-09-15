//
//  DataLensingApp.swift
//  DataLensing
//
//  Created by Ulf Akerstedt-Inoue on 2026/09/14.
//  Copyright © 2026 hakkabon software. All rights reserved.
//

// Phase 1 spike (hardcoded): bundled sample CSV → DataTables →
// AutomaticSmoother → ChartModel → terminal report with an ASCII
// rendering of raw points vs fitted curve.
//
// Sample data: `SampleData/sine.csv`, 1000 rows of sin(x) + N(0, 0.15)
// on x ∈ [0, 10] with ~2% missing markers, generated deterministically
// (Python `random.Random(42)`). Regenerate with the one-liner in the
// Phase 1 notes; the harness asserts the shape it expects.
//
// Tuning choices below (single span, one robust iteration) are spike
// pragmatics for a fast `swift run`, not library policy — the windowed
// refit policy will own those decisions.

import DataLensing
import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Stderr without the C `stderr` global, which is shared mutable state
/// under Swift 6 on Linux (it fails the build there).
private func eprint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

@main
struct DataLensingApp {
    static func main() {
        do {
            try run()
        } catch {
            eprint("data-lensing-app: \(error)")
            exit(1)
        }
    }

    static func run() throws {
        guard let url = Bundle.module.url(
            forResource: "sine", withExtension: "csv", subdirectory: "SampleData"
        ) else {
            eprint("data-lensing-app: bundled SampleData/sine.csv not found")
            exit(1)
        }
        // The viewer-equivalent path: interactive budget, fast adaptive
        // grids. Tuning choices live in TuningBudget, not here.
        let loaded = try loadChart(from: url, budget: .interactive)
        let model = loaded.model
        let kept = model.rawX.count

        print("rows kept: \(kept) (dropped rows are missing markers)")
        print(loaded.summary)
        print(ascii(model: model, width: 60, height: 15))
    }

    /// Raw points (`.`, downsampled) vs fitted mean (`*`) on a shared grid.
    static func ascii(model: ChartModel, width: Int, height: Int) -> String {
        let allY = model.rawY + model.mean
        guard let lo = allY.min(), let hi = allY.max(), hi > lo,
              let xLo = model.rawX.min(), let xHi = model.rawX.max(), xHi > xLo
        else { return "<empty>" }
        var canvas = [[Character]](repeating: [Character](repeating: " ", count: width), count: height)
        func col(_ x: Double) -> Int {
            min(width - 1, max(0, Int((x - xLo) / (xHi - xLo) * Double(width - 1))))
        }
        func row(_ y: Double) -> Int {
            min(height - 1, max(0, Int((hi - y) / (hi - lo) * Double(height - 1))))
        }
        let step = max(1, model.rawX.count / 500)
        for i in stride(from: 0, to: model.rawX.count, by: step) {
            canvas[row(model.rawY[i])][col(model.rawX[i])] = "."
        }
        for j in model.gridX.indices {
            canvas[row(model.mean[j])][col(model.gridX[j])] = "*"
        }
        return canvas.map { String($0) }.joined(separator: "\n")
    }
}
