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
    let fileURL: URL
    let columns: [ColumnInfo]

    /// Numeric column names for the pickers, in file order.
    var numericNames: [String] {
        columns.filter(\.isNumeric).map(\.name)
    }
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
    @State private var selectedX: String?
    @State private var selectedY: String?
    @State private var gate = GenerationGate()
    /// Chart to restore on cancel: nil for fresh opens (→ idle).
    @State private var fallback: BuiltChart?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button("Open CSV…") { showingImporter = true }
                if case .fitting = phase {
                    Button("Cancel") { cancelWork() }
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
                HStack {
                    Picker("X", selection: $selectedX) {
                        ForEach(built.numericNames, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    Picker("Y", selection: $selectedY) {
                        ForEach(built.numericNames, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    Spacer()
                }
                .pickerStyle(.menu)
                .onChange(of: selectedX) { _, _ in reselectIfNeeded(built) }
                .onChange(of: selectedY) { _, _ in reselectIfNeeded(built) }
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

    /// Cancel with instant feedback: the spinner vanishes now, not when
    /// the runaway child finishes. The generation bump also disarms the
    /// stale completion (see GenerationGate).
    private func cancelWork() {
        work?.cancel()
        work = nil
        gate.invalidate()
        phase = fallback.map(Phase.ready) ?? .idle
    }

    private func open(_ url: URL) {
        work?.cancel()
        let name = url.lastPathComponent
        visibleDomain = nil  // stale windows must never decimate new data
        selectedX = nil
        selectedY = nil
        fallback = nil  // fresh open cancels back to idle
        let generation = gate.next()
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
                guard gate.isCurrent(generation) else { return }
                selectedX = built.controller.xName
                selectedY = built.controller.yName
                phase = .ready(built)
            } catch is CancellationError {
                guard gate.isCurrent(generation) else { return }
                phase = .idle
            } catch {
                guard gate.isCurrent(generation) else { return }
                phase = .failed(String(describing: error))
            }
        }
    }

    /// Refit with the picked columns when they differ from the fitted
    /// pair. Setting state after a load carries equal values, so this is
    /// a no-op there — it only fires on real user changes.
    private func reselectIfNeeded(_ built: BuiltChart) {
        guard let x = selectedX, let y = selectedY,
              x != built.controller.xName || y != built.controller.yName
        else { return }
        work?.cancel()
        fallback = built  // cancel restores this chart
        let generation = gate.next()
        phase = .fitting("refit \(x) vs \(y)")
        work = Task {
            do {
                let rebuilt = try await withThrowingTaskGroup(of: BuiltChart.self) { group in
                    group.addTask { try await scopedFit(from: built.fileURL, x: x, y: y) }
                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return first
                }
                guard gate.isCurrent(generation) else { return }
                visibleDomain = nil
                phase = .ready(rebuilt)
            } catch is CancellationError {
                guard gate.isCurrent(generation) else { return }
                phase = .ready(built)
            } catch {
                guard gate.isCurrent(generation) else { return }
                phase = .failed(String(describing: error))
            }
        }
    }

    /// Windowed refit to the live viewport: subset, spend the budget,
    /// keep the old chart on cancel or when the window turns out covered.
    private func refitToView(_ built: BuiltChart, _ domain: ClosedRange<Double>) {
        work?.cancel()
        fallback = built  // cancel restores this chart
        let generation = gate.next()
        phase = .fitting("refit \(built.fileName)")
        work = Task {
            do {
                let result: (controller: FitController, didRefit: Bool) = try await withThrowingTaskGroup(
                    of: (controller: FitController, didRefit: Bool).self
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
                guard gate.isCurrent(generation) else { return }
                guard result.didRefit, let loaded = result.controller.loaded else {
                    phase = .ready(built)  // covered or empty: keep showing the cache
                    return
                }
                visibleDomain = nil  // re-track against the new hull
                phase = .ready(BuiltChart(
                    controller: result.controller, loaded: loaded,
                    fileName: built.fileName, fileURL: built.fileURL, columns: built.columns
                ))
            } catch is CancellationError {
                guard gate.isCurrent(generation) else { return }
                phase = .ready(built)
            } catch {
                guard gate.isCurrent(generation) else { return }
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
    let columns = try inspectColumns(from: url)
    try Task.checkCancellation()
    var controller = try loadController(from: url, budget: .interactive)
    try Task.checkCancellation()
    let loaded = try await controller.fitConcurrently()
    try Task.checkCancellation()
    return BuiltChart(
        controller: controller, loaded: loaded,
        fileName: url.lastPathComponent, fileURL: url, columns: columns
    )
}

/// Explicit-column twin of `scopedLoad` for picker changes: same
/// path, policy replaced by the user's choice.
private func scopedFit(from url: URL, x: String, y: String) async throws -> BuiltChart {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
        if didAccess { url.stopAccessingSecurityScopedResource() }
    }
    let columns = try inspectColumns(from: url)
    try Task.checkCancellation()
    var controller = try loadController(from: url, xColumn: x, yColumn: y, budget: .interactive)
    try Task.checkCancellation()
    let loaded = try await controller.fitConcurrently()
    try Task.checkCancellation()
    return BuiltChart(
        controller: controller, loaded: loaded,
        fileName: url.lastPathComponent, fileURL: url, columns: columns
    )
}
