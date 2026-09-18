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
//  Phase 2 additions:
//  • ⌘O: open file picker  ⌘W: clear chart  ⌘E: export fitted grid
//  • ←/→ arrow keys step the probe cursor along the fitted grid
//  • Descriptive Statistics section in the sidebar
//  • Polished empty / loading / error states
//

import DataLensing
import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

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
    @State private var selectedX2: String?
    @State private var selectedSmoother: SmootherChoice = .automatic
    @State private var inspectorX: Double?
    @State private var gate = GenerationGate()
    @State private var activePlanes: ChartPlanes = .all
    /// Chart to restore on cancel: nil for fresh opens (→ idle).
    @State private var fallback: BuiltChart?
    /// Last successfully opened URL for "Try Again" retry.
    @State private var lastURL: URL?

    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @State private var loadedSurface: LoadedSurface?
    @State private var surfaceWork: Task<Void, Never>?
    @State private var surfaceError: String?
    @State private var surfaceLoading = false
    @State private var surfaceGeneration = 0

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            detailContent
        }
        .frame(minWidth: 780, minHeight: 520)
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
        // ─── Keyboard Shortcuts ───────────────────────────────────────
        .onKeyPress(.leftArrow) {
            stepProbe(by: -1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            stepProbe(by: 1)
            return .handled
        }
        .onKeyPress(.escape) {
            inspectorX = nil
            return .handled
        }
        .focusedSceneValue(\.viewerCommandActions, ViewerCommandActions(
            open: { showingImporter = true },
            clear: clearChart,
            export: exportFittedGrid,
            canClear: isReady,
            canExport: isReady
        ))
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebarContent: some View {
        List {
            Section("Data Source") {
                Button {
                    showingImporter = true
                } label: {
                    Label("Open CSV…", systemImage: "doc.badge.plus")
                }

                Menu {
                    ForEach(sampleURLs, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            open(url)
                        }
                    }
                } label: {
                    Label("Sample Datasets", systemImage: "folder")
                }

                if case .fitting = phase {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Fitting…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { cancelWork() }
                            .controlSize(.small)
                    }
                }
            }

            if case .ready(let built) = phase {
                Section("Variables") {
                    Picker("Predictor (X)", selection: $selectedX) {
                        ForEach(built.numericNames, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    Picker("Response (Y)", selection: $selectedY) {
                        ForEach(built.numericNames, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    Picker("Second Predictor", selection: $selectedX2) {
                        Text("None (1D)").tag(Optional<String>.none)
                        ForEach(built.numericNames.filter { $0 != selectedX && $0 != selectedY }, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                }
                .onChange(of: selectedX) { _, _ in reselectIfNeeded(built) }
                .onChange(of: selectedY) { _, _ in reselectIfNeeded(built) }
                .onChange(of: selectedX2) { _, value in
                    loadSurfaceIfNeeded(built, secondPredictor: value)
                }

                Section("Statistical Model") {
                    Picker("Algorithm", selection: $selectedSmoother) {
                        ForEach(
                            [
                                SmootherChoice.automatic, .loess, .adaptive, .kernel,
                                .whittaker, .totalVariation,
                            ],
                            id: \.self
                        ) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                }
                .onChange(of: selectedSmoother) { _, _ in reselectIfNeeded(built) }

                Section("Display Planes") {
                    Toggle("Raw Samples", isOn: planeBinding(.samples))
                    Toggle("Uncertainty Hull (±2 SE)", isOn: planeBinding(.hull))
                    Toggle("Fitted Curve", isOn: planeBinding(.curve))
                    Toggle("Coordinate Grid", isOn: planeBinding(.gridlines))
                    Toggle("Gradient", isOn: planeBinding(.gradient))
                    Toggle("Residuals", isOn: planeBinding(.residuals))
                    Toggle("Normal QQ Plot", isOn: planeBinding(.qqPlot))
                }

                Section("Model Information") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("File: \(built.fileName)")
                            .font(.caption)
                            .foregroundStyle(.primary)

                        if let summary = built.loaded.summary {
                            Text(summary.smoother)
                                .font(.caption.bold())
                            Text(summary.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(summary.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(built.loaded.smootherName)
                                .font(.caption.bold())
                            Text("Explicit fit (no tuning competition)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // ── Descriptive Statistics ────────────────────────────
                Section("Descriptive Statistics") {
                    let xs = built.loaded.model.xSummary
                    let ys = built.loaded.model.ySummary
                    VStack(alignment: .leading, spacing: 4) {
                        statsRow(label: "n", x: "\(xs.n)", y: "\(ys.n)")
                        statsRow(label: "mean", x: fmt6(xs.mean), y: fmt6(ys.mean))
                        statsRow(label: "std", x: fmt6(xs.std), y: fmt6(ys.std))
                        statsRow(label: "median", x: fmt6(xs.median), y: fmt6(ys.median))
                        statsRow(label: "min", x: fmt6(xs.min), y: fmt6(ys.min))
                        statsRow(label: "max", x: fmt6(xs.max), y: fmt6(ys.max))
                    }
                    .font(.caption2.monospaced())

                    Button("Copy Fitted Grid") { exportFittedGrid() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("DataLensing")
    }

    private func statsRow(label: String, x: String, y: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .frame(width: 52, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(x)
                .frame(minWidth: 72, alignment: .trailing)
            Spacer()
            Text(y)
                .frame(minWidth: 72, alignment: .trailing)
        }
    }

    // MARK: - Detail Canvas

    @ViewBuilder
    private var detailContent: some View {
        switch phase {
        case .idle:
            idleHeroView

        case .fitting(let name):
            fittingView(name: name)

        case .ready(let built):
            if let loadedSurface {
                VStack(spacing: 12) {
                    HStack {
                        Text("\(loadedSurface.responseName) by \(loadedSurface.xName) and \(loadedSurface.yName)")
                            .font(.headline)
                        Spacer()
                        Button("Return to 1D") {
                            selectedX2 = nil
                            self.loadedSurface = nil
                        }
                    }
                    SurfaceChartView(
                        model: loadedSurface.model,
                        xLabel: loadedSurface.xName,
                        yLabel: loadedSurface.yName
                    )
                    if let surfaceError {
                        Text(surfaceError).foregroundStyle(.red).font(.caption)
                    }
                }
                .padding()
            } else {
                VStack(spacing: 12) {
                if surfaceLoading {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Fitting 2D surface…").font(.caption)
                    }
                } else if let surfaceError {
                    Text(surfaceError).foregroundStyle(.red).font(.caption)
                }
                SmootherChartView(
                    model: built.loaded.model,
                    visibleDomain: $visibleDomain,
                    visibleLength: ChartWindow.initialVisibleLength(
                        hull: built.controller.hull,
                        pointCount: built.loaded.model.rawX.count
                    ),
                    xSelection: $inspectorX,
                    xIsDate: built.columns.first(where: { $0.name == built.controller.xName })?.isDate ?? false,
                    planes: activePlanes
                )
                .frame(minHeight: 340)
                .animation(.easeOut(duration: 0.15), value: inspectorX)

                // Probe & Coverage Status Bar
                HStack {
                    if let x = inspectorX,
                       let band = built.loaded.model.interpolatedBand(at: x)
                    {
                        if built.loaded.model.hasBand {
                            Text(String(
                                format: "x = %.3f · %@ = %.3f (95%% CI: [%.3f, %.3f])",
                                x, built.loaded.model.responseScale.rawValue.lowercased(),
                                band.mean, band.lower, band.upper
                            ))
                            .font(.caption)
                            .monospaced()
                        } else {
                            Text(String(
                                format: "x = %.3f · %@ = %.3f", x,
                                built.loaded.model.responseScale.rawValue.lowercased(), band.mean
                            ))
                                .font(.caption)
                                .monospaced()
                        }
                    } else {
                        Text("Click or drag on the chart to probe fitted values & confidence bounds. ← → keys step the probe.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(coverageLine(for: built))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let domain = visibleDomain,
                       built.controller.needsRefit(covering: domain)
                    {
                        Button("Refit to view") { refitToView(built, domain) }
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.bar)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding()
            }

        case .failed(let message):
            failedView(message: message)
        }
    }

    // MARK: - Polished state views

    private var idleHeroView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.05),
                    Color.accentColor.opacity(0.02),
                    Color.clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 56, weight: .ultraLight))
                    .foregroundStyle(.quaternary)

                VStack(spacing: 6) {
                    Text("No Dataset Loaded")
                        .font(.title2.weight(.semibold))
                    Text("Open a CSV file or choose a sample dataset\nfrom the sidebar to explore smoothing models.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 12) {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Open CSV…", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    if !sampleURLs.isEmpty {
                        Menu {
                            ForEach(sampleURLs, id: \.self) { url in
                                Button(url.deletingPathExtension().lastPathComponent) {
                                    open(url)
                                }
                            }
                        } label: {
                            Label("Try Sample", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }
                .padding(.top, 4)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fittingView(name: String) -> some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .scaleEffect(1.5)
            VStack(spacing: 4) {
                Text("Fitting model…")
                    .font(.headline)
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("Cancel") { cancelWork() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.red)

            VStack(spacing: 6) {
                Text("Failed to Load or Fit")
                    .font(.title3.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .lineLimit(6)
            }

            HStack(spacing: 12) {
                if let url = lastURL {
                    Button("Try Again") { open(url) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                }
                Button("Open Different File…") { showingImporter = true }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Helpers

    private var isReady: Bool {
        if case .ready = phase { return true }
        return false
    }

    private func planeBinding(_ plane: ChartPlanes) -> Binding<Bool> {
        Binding(
            get: { activePlanes.contains(plane) },
            set: { isVisible in
                if isVisible {
                    activePlanes.insert(plane)
                } else {
                    activePlanes.remove(plane)
                }
            }
        )
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

    /// Step the probe cursor by `steps` grid positions.
    private func stepProbe(by steps: Int) {
        guard case .ready(let built) = phase else { return }
        let model = built.loaded.model
        guard !model.gridX.isEmpty else { return }
        // Find current nearest index
        let currentIdx: Int
        if let x = inspectorX {
            var best = 0
            var bestDist = abs(model.gridX[0] - x)
            for i in 1 ..< model.gridX.count {
                let d = abs(model.gridX[i] - x)
                if d < bestDist { bestDist = d; best = i }
            }
            currentIdx = best
        } else {
            currentIdx = model.gridX.count / 2
        }
        let target = max(0, min(model.gridX.count - 1, currentIdx + steps))
        withAnimation(.easeOut(duration: 0.1)) {
            inspectorX = model.gridX[target]
        }
    }

    /// Copy the fitted grid TSV to the pasteboard.
    private func exportFittedGrid() {
        guard case .ready(let built) = phase else { return }
        let tsv = built.loaded.model.fittedGridTSV
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(tsv, forType: .tabularText)
        pb.setString(tsv, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = tsv
        #endif
    }

    private func clearChart() {
        work?.cancel()
        work = nil
        gate.invalidate()
        fallback = nil
        visibleDomain = nil
        inspectorX = nil
        selectedX = nil
        selectedY = nil
        selectedX2 = nil
        loadedSurface = nil
        surfaceWork?.cancel()
        surfaceWork = nil
        surfaceLoading = false
        surfaceGeneration += 1
        phase = .idle
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

    /// Bundled samples, discovered live (adding a CSV to SampleData
    /// needs no code change — the folder reference copies it in).
    private var sampleURLs: [URL] {
        guard let dir = Bundle.main.url(forResource: "SampleData", withExtension: nil),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: nil
              )
        else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "csv" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func open(_ url: URL) {
        work?.cancel()
        surfaceWork?.cancel()
        surfaceGeneration += 1
        surfaceLoading = false
        lastURL = url
        let name = url.lastPathComponent
        visibleDomain = nil  // stale windows must never decimate new data
        selectedX = nil
        selectedY = nil
        selectedX2 = nil
        loadedSurface = nil
        inspectorX = nil
        fallback = nil  // fresh open cancels back to idle
        let generation = gate.next()
        let smoother = selectedSmoother  // sticky preference across files
        phase = .fitting(name)
        work = Task {
            do {
                let built = try await withThrowingTaskGroup(of: BuiltChart.self) { group in
                    group.addTask { try await scopedLoad(from: url, smoother: smoother) }
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

    /// Refit with the picked columns/smoother when they differ from the
    /// fitted ones. Setting state after a load carries equal values, so
    /// this is a no-op there — it only fires on real user changes.
    private func reselectIfNeeded(_ built: BuiltChart) {
        guard let x = selectedX, let y = selectedY,
              x != built.controller.xName || y != built.controller.yName
                || selectedSmoother != built.controller.smoother
        else { return }
        loadedSurface = nil
        selectedX2 = nil
        surfaceWork?.cancel()
        surfaceGeneration += 1
        surfaceLoading = false
        work?.cancel()
        fallback = built  // cancel restores this chart
        let generation = gate.next()
        let smoother = selectedSmoother  // Sendable copy for the child task
        phase = .fitting("refit \(x) vs \(y) (\(smoother.rawValue))")
        work = Task {
            do {
                let rebuilt = try await withThrowingTaskGroup(of: BuiltChart.self) { group in
                    group.addTask {
                        try await scopedFit(
                            from: built.fileURL, x: x, y: y, smoother: smoother
                        )
                    }
                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return first
                }
                guard gate.isCurrent(generation) else { return }
                visibleDomain = nil
                inspectorX = nil
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

    private func loadSurfaceIfNeeded(_ built: BuiltChart, secondPredictor: String?) {
        surfaceWork?.cancel()
        surfaceGeneration += 1
        let generation = surfaceGeneration
        surfaceError = nil
        surfaceLoading = false
        guard let x1 = selectedX, let x2 = secondPredictor, let response = selectedY,
              x1 != x2, response != x1, response != x2 else {
            loadedSurface = nil
            return
        }
        surfaceLoading = true
        surfaceWork = Task {
            do {
                let surface = try await scopedSurface(
                    from: built.fileURL, x: x1, y: x2, response: response
                )
                try Task.checkCancellation()
                guard generation == surfaceGeneration else { return }
                loadedSurface = surface
                surfaceLoading = false
            } catch is CancellationError {
                guard generation == surfaceGeneration else { return }
                surfaceLoading = false
                return
            } catch {
                guard generation == surfaceGeneration else { return }
                loadedSurface = nil
                surfaceError = String(describing: error)
                surfaceLoading = false
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
                inspectorX = nil
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

    // MARK: - Formatting helpers

    private func fmt6(_ v: Double) -> String { String(format: "%.6g", v) }
}

/// Parse instantly, then spend the interactive budget in the
/// background. Free function (not a method) so the task closure
/// captures no `self`.
private func scopedLoad(from url: URL, smoother: SmootherChoice = .automatic) async throws -> BuiltChart {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
        if didAccess { url.stopAccessingSecurityScopedResource() }
    }
    let columns = try inspectColumns(from: url)
    try Task.checkCancellation()
    var controller = try loadController(from: url, budget: .interactive, smoother: smoother)
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
private func scopedFit(
    from url: URL, x: String, y: String, smoother: SmootherChoice = .automatic
) async throws -> BuiltChart {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
        if didAccess { url.stopAccessingSecurityScopedResource() }
    }
    let columns = try inspectColumns(from: url)
    try Task.checkCancellation()
    var controller = try loadController(
        from: url, xColumn: x, yColumn: y, budget: .interactive, smoother: smoother
    )
    try Task.checkCancellation()
    let loaded = try await controller.fitConcurrently()
    try Task.checkCancellation()
    return BuiltChart(
        controller: controller, loaded: loaded,
        fileName: url.lastPathComponent, fileURL: url, columns: columns
    )
}

private func scopedSurface(
    from url: URL, x: String, y: String, response: String
) async throws -> LoadedSurface {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
        if didAccess { url.stopAccessingSecurityScopedResource() }
    }
    return try await loadSurfaceConcurrently(
        from: url, xColumn: x, yColumn: y, responseColumn: response,
        budget: .interactive
    )
}
