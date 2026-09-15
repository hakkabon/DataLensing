//
//  ContentView.swift
//  DataLensingViewer
//
//  File picker → background `loadChart(from:)` → SmootherChartView.
//  The fit runs in a structured child task off the main actor; picking
//  another file cancels the in-flight fit (no refit-per-frame, no
//  orphaned work). Security-scoped access wraps the load so the app
//  stays correct if/when sandboxed.
//

import DataLensing
import SwiftUI
import UniformTypeIdentifiers

/// What the viewer has finished building on a background task. The
/// controller is retained for the windowed refit policy: future scrolls
/// ask it `needsRefit(covering:)` instead of fitting again.
private struct BuiltChart: Sendable {
    let controller: FitController
    let loaded: LoadedChart
    let fileName: String
}

struct ContentView: View {
    private enum Phase {
        case idle
        case fitting(String)
        case ready(BuiltChart)
        case failed(String)
    }

    @State private var phase = Phase.idle
    @State private var showingImporter = false
    @State private var work: Task<Void, Never>?
    @State private var visibleDomain: ClosedRange<Double>?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Open CSV…") { showingImporter = true }
                if case .fitting = phase {
                    Button("Cancel") { work?.cancel() }
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text(statusLine).foregroundStyle(.secondary)
            }
            switch phase {
            case .idle:
                Text("Open a CSV file with two numeric columns.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .fitting(let name):
                ProgressView("Fitting \(name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready(let built):
                SmootherChartView(
                    model: built.loaded.model,
                    visibleDomain: $visibleDomain,
                    visibleLength: ChartWindow.initialVisibleLength(
                        hull: built.controller.hull,
                        pointCount: built.loaded.model.rawX.count
                    )
                )
                .frame(minHeight: 320)
                HStack {
                    Text(coverageLine(for: built))
                    if let domain = visibleDomain,
                       built.controller.needsRefit(covering: domain)
                    {
                        Button("Refit to view") { refitToView(built, domain) }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("\(built.loaded.xName) vs \(built.loaded.yName) — \(built.loaded.summary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 480)
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                open(url)
            case .failure(let error):
                phase = .failed(String(describing: error))
            }
        }
    }

    private var statusLine: String {
        switch phase {
        case .idle: "No file"
        case .fitting(let name): "Fitting \(name)"
        case .ready(let built): built.fileName
        case .failed: "Failed"
        }
    }

    /// Live windowed-policy readout: what the chart reports visible,
    /// whether the cached fit still covers it.
    private func coverageLine(for built: BuiltChart) -> String {
        let hullText = built.controller.hull.map {
            String(format: "hull %.2f–%.2f", $0.lowerBound, $0.upperBound)
        } ?? "no hull"
        guard let domain = visibleDomain else {
            return "\(hullText) · full view · cached fit"
        }
        let viewText = String(
            format: "viewing %.2f–%.2f", domain.lowerBound, domain.upperBound
        )
        if built.controller.needsRefit(covering: domain) {
            return "\(hullText) · \(viewText) · OUTSIDE fitted hull — cached fit shown"
        }
        return "\(hullText) · \(viewText) · cached fit"
    }

    private func open(_ url: URL) {
        work?.cancel()
        let name = url.lastPathComponent
        visibleDomain = nil  // stale windows must never decimate new data
        phase = .fitting(name)
        work = Task {
            do {
                let built = try await withThrowingTaskGroup(of: BuiltChart.self) { group in
                    group.addTask { try await scopedLoad(from: url) }
                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return first
                }
                phase = .ready(built)
            } catch is CancellationError {
                phase = .idle
            } catch {
                phase = .failed(String(describing: error))
            }
        }
    }

    /// Windowed refit to the live viewport: subset, spend the budget,
    /// keep the old chart on cancel or when the window turns out covered.
    private func refitToView(_ built: BuiltChart, _ domain: ClosedRange<Double>) {
        work?.cancel()
        phase = .fitting("refit \(built.fileName)")
        work = Task {
            do {
                let (controller, didRefit) = try await withThrowingTaskGroup(
                    of: (FitController, Bool).self
                ) { group in
                    group.addTask {
                        var controller = built.controller
                        let didRefit = try await controller.refitConcurrently(covering: domain)
                        return (controller, didRefit)
                    }
                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return first
                }
                guard didRefit, let loaded = controller.loaded else {
                    phase = .ready(built)  // covered or empty: keep showing the cache
                    return
                }
                visibleDomain = nil  // re-track against the new hull
                phase = .ready(BuiltChart(controller: controller, loaded: loaded, fileName: built.fileName))
            } catch is CancellationError {
                phase = .ready(built)
            } catch {
                phase = .failed(String(describing: error))
            }
        }
    }
}

/// Parse instantly, then spend the interactive budget in the
/// background. Free function (not a method) so the task closure
/// captures no `self`.
private func scopedLoad(from url: URL) async throws -> BuiltChart {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
        if didAccess { url.stopAccessingSecurityScopedResource() }
    }
    var controller = try loadController(from: url, budget: .interactive)
    try Task.checkCancellation()
    let loaded = try await controller.fitConcurrently()
    try Task.checkCancellation()
    return BuiltChart(controller: controller, loaded: loaded, fileName: url.lastPathComponent)
}
