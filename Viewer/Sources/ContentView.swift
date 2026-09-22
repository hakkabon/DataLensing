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
import DataLens
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
    /// Original CSV row per controller training row when replay transformed
    /// the source. File-backed charts use the controller's native mapping.
    let sourceRows: [Int]?

    /// Numeric column names for the pickers, in file order.
    var numericNames: [String] {
        columns.filter(\.isNumeric).map(\.name)
    }

    var keptSourceRows: [Int]? {
        guard let sourceRows else { return controller.keptFileIndices }
        guard sourceRows.count == controller.trainX.count else { return nil }
        return loaded.keptIndices.map { sourceRows[controller.windowBase[$0]] }
    }
}

/// A small FileDocument wrapper keeps persistence in the platform file picker
/// while `AnalysisDocument` stays a portable Codable statistical record.
private struct AnalysisDocumentFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private enum AdvancedStrategyChoice: String, CaseIterable, Identifiable {
    case gaussianGAM = "Gaussian GAM"
    case binomialGAM = "Binomial GAM"
    case poissonGAM = "Poisson GAM"
    case gaussianMultivariate = "Gaussian multivariate"
    case binomialMultivariate = "Binomial multivariate"
    case poissonMultivariate = "Poisson multivariate"

    var id: String { rawValue }
    var requiresSecondPredictor: Bool {
        switch self {
        case .gaussianMultivariate, .binomialMultivariate, .poissonMultivariate: true
        default: false
        }
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

    @State private var workbenchOutputs: [WorkbenchOutput] = []
    @State private var workbenchTask: Task<Void, Never>?
    @State private var workbenchLoading = false
    @State private var workbenchError: String?

    @State private var analysisDocument: AnalysisDocument?
    @State private var documentURL: URL?
    @State private var documentSourceURL: URL?
    @State private var documentTask: Task<Void, Never>?
    @State private var documentRecomputing = false
    @State private var documentError: String?
    @State private var showingDocumentImporter = false
    @State private var showingDocumentSourceImporter = false
    @State private var showingDocumentExporter = false
    @State private var documentExport: AnalysisDocumentFile?
    @State private var figureCaption = ""
    @State private var advancedStrategy: AdvancedStrategyChoice = .gaussianGAM
    @State private var advancedSolver: MultivariateSolverPreference = .automatic
    @State private var advancedBootstrap = false
    @State private var advancedTask: Task<Void, Never>?
    @State private var advancedLoading = false

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
        .fileImporter(
            isPresented: $showingDocumentImporter,
            allowedContentTypes: [.json], allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                openDocument(url)
            case .failure(let error):
                documentError = String(describing: error)
            }
        }
        .fileImporter(
            isPresented: $showingDocumentSourceImporter,
            allowedContentTypes: [.commaSeparatedText], allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                recomputeDocument(from: url)
            case .failure(let error):
                documentError = String(describing: error)
            }
        }
        .fileExporter(
            isPresented: $showingDocumentExporter, document: documentExport,
            contentType: .json, defaultFilename: documentDefaultFileName
        ) { result in
            if case .success(let url) = result { documentURL = url }
            if case .failure(let error) = result { documentError = String(describing: error) }
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
            exportReport: exportAnalysisReport,
            exportSession: exportWorkbenchSession,
            newDocument: createDocumentFromChart,
            openDocument: { showingDocumentImporter = true },
            saveDocument: saveDocument,
            canClear: isReady,
            canExport: isReady,
            canSaveDocument: analysisDocument != nil
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

            Section("Analysis Document") {
                if let document = analysisDocument {
                    HStack(spacing: 6) {
                        Image(systemName: "book.closed")
                            .foregroundStyle(Color.accentColor)
                        Text(document.title).font(.caption.bold()).lineLimit(1)
                        Spacer()
                        documentStateBadge(for: document)
                    }
                    Text("Source: \(document.source.displayName) · \(document.blocks.count) blocks")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let documentError {
                        Label(documentError, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }

                    Button {
                        if let documentSourceURL {
                            recomputeDocument(from: documentSourceURL)
                        } else {
                            showingDocumentSourceImporter = true
                        }
                    } label: {
                        if documentRecomputing {
                            Label("Recomputing…", systemImage: "arrow.triangle.2.circlepath")
                        } else if documentSourceURL == nil {
                            Label("Attach CSV & Recompute…", systemImage: "link.badge.plus")
                        } else {
                            Label("Recompute Document", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(documentRecomputing || document.latestModelBlockID == nil)

                    if case .ready(let built) = phase {
                        Button("Update Recipe from Visible Chart") {
                            updateDocumentRecipe(from: built)
                        }
                        .disabled(documentRecomputing || documentSourceURL != built.fileURL)

                        TextField("Figure caption", text: $figureCaption, prompt: Text("What does this figure show?"))
                            .font(.caption)
                        Button("Record Figure Annotation") {
                            appendFigureAnnotation(from: built)
                        }
                        .disabled(documentRecomputing || document.latestModelBlockID == nil)

                        Divider()
                        Picker("Advanced model", selection: $advancedStrategy) {
                            ForEach(AdvancedStrategyChoice.allCases) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        if advancedStrategy.requiresSecondPredictor {
                            Picker("Numerical solve", selection: $advancedSolver) {
                                Text("Automatic").tag(MultivariateSolverPreference.automatic)
                                Text("Dense QR").tag(MultivariateSolverPreference.denseQR)
                                Text("Sparse CGLS").tag(MultivariateSolverPreference.sparseCGLS)
                            }
                        } else {
                            Toggle("Bootstrap stability (50)", isOn: $advancedBootstrap)
                        }
                        Button {
                            fitAndRecordAdvancedModel(from: built)
                        } label: {
                            if advancedLoading {
                                Label("Fitting Advanced Model…", systemImage: "gearshape.2")
                            } else {
                                Label("Fit & Record Advanced Model", systemImage: "function")
                            }
                        }
                        .disabled(
                            documentRecomputing || advancedLoading || documentSourceURL != built.fileURL
                                || (advancedStrategy.requiresSecondPredictor && selectedX2 == nil)
                        )
                    }

                    numericalExecutionPanel(for: document)

                    Button("Save Document…") { saveDocument() }
                        .disabled(documentRecomputing)
                    Button("Open Different Document…") { showingDocumentImporter = true }

                    ForEach(document.blocks) { block in
                        documentBlockRow(block)
                    }
                } else {
                    Text("Save models, figures, and validation evidence as a replayable statistical record.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if case .ready = phase {
                        Button("Create Document from Chart") { createDocumentFromChart() }
                    }
                    Button("Open Document…") { showingDocumentImporter = true }
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

                if let assessment = ModelAssessment.make(from: built.loaded.model) {
                    Section("Model Diagnostics") {
                        VStack(alignment: .leading, spacing: 4) {
                            LabeledContent("RMSE", value: fmt6(assessment.rootMeanSquaredError))
                            LabeledContent("MAE", value: fmt6(assessment.meanAbsoluteError))
                            if let value = assessment.rSquared {
                                LabeledContent("R²", value: fmt6(value))
                            }
                            if let value = assessment.devianceExplained {
                                LabeledContent("Deviance explained", value: String(format: "%.1f%%", 100 * value))
                            }
                            if let value = assessment.qqCorrelation {
                                LabeledContent("QQ correlation", value: fmt6(value))
                            }
                            if let value = assessment.residualLagOneCorrelation {
                                LabeledContent("Residual lag-1", value: fmt6(value))
                            }
                        }
                        .font(.caption2.monospacedDigit())

                        if assessment.findings.isEmpty {
                            Label("No threshold warnings", systemImage: "checkmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(assessment.findings, id: \.code) { finding in
                                Label(finding.message,
                                      systemImage: finding.severity == .caution
                                        ? "exclamationmark.triangle" : "info.circle")
                                    .font(.caption2)
                                    .foregroundStyle(finding.severity == .caution ? .orange : .secondary)
                            }
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
                    Button("Copy Analysis Report") { exportAnalysisReport() }
                        .font(.caption)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.accentColor)
                }

                Section("Workbench") {
                    Button {
                        runWorkbench(for: built)
                    } label: {
                        if workbenchLoading {
                            Label("Running Tools…", systemImage: "gearshape.2")
                        } else {
                            Label(
                                workbenchOutputs.isEmpty ? "Run Built-in Tools" : "Refresh Built-in Tools",
                                systemImage: "slider.horizontal.3"
                            )
                        }
                    }
                    .disabled(workbenchLoading)

                    if let workbenchError {
                        Label(workbenchError, systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }

                    ForEach(workbenchOutputs) { output in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(output.title).font(.caption.bold())
                            Text(output.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            ForEach(output.metrics.prefix(4)) { metric in
                                LabeledContent(metric.label, value: workbenchMetricValue(metric))
                                    .font(.caption2.monospacedDigit())
                            }
                            if let table = output.table, let first = table.rows.first {
                                Text("Preview: \(first.joined(separator: " · "))")
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    Button("Copy Workbench Session") { exportWorkbenchSession() }
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

    private var documentDefaultFileName: String {
        let title = analysisDocument?.title ?? "analysis"
        let safe = title.replacingOccurrences(of: "/", with: "-")
        return safe.isEmpty ? "analysis" : safe
    }

    @ViewBuilder
    private func documentStateBadge(for document: AnalysisDocument) -> some View {
        let stale = document.blocks.filter { $0.state == .stale }.count
        Label(
            stale == 0 ? "Current" : "\(stale) stale",
            systemImage: stale == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        )
        .font(.caption2.weight(.medium))
        .foregroundStyle(stale == 0 ? .green : .orange)
    }

    private func latestAdvancedEvidence(in document: AnalysisDocument) -> AnalysisDocument.AdvancedModelEvidence? {
        for block in document.blocks.reversed() {
            guard case .advancedEvidence(let evidence) = block.payload else { continue }
            return evidence
        }
        return nil
    }

    @ViewBuilder
    private func numericalExecutionPanel(for document: AnalysisDocument) -> some View {
        if let evidence = latestAdvancedEvidence(in: document),
           let requested = evidence.requestedSolverPreference {
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Label("Numerical execution", systemImage: "cpu")
                    .font(.caption.weight(.semibold))
                Text("Requested: \(requested.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Accepted: \(evidence.solverBackend?.rawValue ?? "not recorded")")
                    .font(.caption2)
                    .foregroundStyle(evidence.solverBackend == .sparseCGLS ? .green : .secondary)
                if let sparse = evidence.sparseExecution {
                    Text(String(
                        format: "Native CSR · %d × %d · %d nnz · %d iter · residual %.2g",
                        sparse.designRows, sparse.designColumns, sparse.nonZeroCount,
                        sparse.iterations, sparse.normalResidualNorm
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else if evidence.solverBackend == .denseQRFallback {
                    Text("Sparse dispatch did not converge; automatic policy accepted dense QR.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if evidence.solverBackend == .denseQR {
                    Text("Dense QR was selected; no sparse execution record applies.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func documentBlockRow(_ block: AnalysisDocument.Block) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: documentBlockSymbol(block))
                .foregroundStyle(block.state == .current ? Color.accentColor : .orange)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(block.title).font(.caption).lineLimit(1)
                Text(documentBlockDetail(block))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Text(block.state == .current ? "Current" : "Stale")
                .font(.caption2.weight(.medium))
                .foregroundStyle(block.state == .current ? .green : .orange)
        }
    }

    private func documentBlockSymbol(_ block: AnalysisDocument.Block) -> String {
        switch block.payload {
        case .transformation: "line.3.horizontal.decrease.circle"
        case .model: "function"
        case .advancedModel: "function"
        case .evidence: "checklist"
        case .advancedEvidence: "checklist"
        case .figure: "chart.xyaxis.line"
        case .note: "note.text"
        }
    }

    private func documentBlockDetail(_ block: AnalysisDocument.Block) -> String {
        switch block.payload {
        case .transformation: return "Replayable transformation"
        case .model(let recipe): return "\(recipe.smoother) · \(recipe.predictor) → \(recipe.response)"
        case .advancedModel(let recipe):
            return "\(recipe.specification.strategy.rawValue) · \(recipe.predictorColumns.joined(separator: ", ")) → \(recipe.responseColumn)"
        case .evidence(let evidence):
            return "\(evidence.workbenchOutputs.count) validation panels · \(evidence.report.retainedObservationCount) rows"
        case .advancedEvidence(let evidence):
            let validation = evidence.validation?.primaryScore.map { String(format: "score %.4g", $0) }
            let requested = evidence.requestedSolverPreference.map { "requested \($0.rawValue)" }
            let solver = evidence.solverBackend.map { "accepted \($0.rawValue)" }
            let sparse = evidence.sparseExecution.map {
                String(format: "CSR %d×%d · %d nnz · %d iter", $0.designRows,
                       $0.designColumns, $0.nonZeroCount, $0.iterations)
            }
            let calibration = evidence.calibration.map {
                String(format: "Brier %.4g · ECE %.4g", $0.brierScore, $0.expectedCalibrationError)
            }
            let bootstrap = evidence.bootstrap.map { "bootstrap \($0.successfulReplicates)/\($0.attemptedReplicates)" }
            let edf = String(format: "EDF %.3g", evidence.diagnostics.effectiveDegreesOfFreedom)
            return [evidence.modelKind.rawValue, edf, requested, solver, sparse, validation, calibration, bootstrap]
                .compactMap { $0 }.joined(separator: " · ")
        case .figure(let figure): return figure.caption
        case .note(let text): return text
        }
    }

    private func currentDocumentRecipe(for built: BuiltChart) throws -> AnalysisDocument.ModelRecipe {
        guard selectedX2 == nil else {
            throw AnalysisDocumentExecutionError.multivariateModelUnsupported
        }
        return try AnalysisDocument.ModelRecipe(
            predictor: built.controller.xName, response: built.controller.yName,
            smoother: built.controller.smoother, tuning: WorkbenchTuning(built.controller.budget),
            validationConfiguration: validationConfiguration(for: built)
        )
    }

    private func figureAnnotation(for built: BuiltChart) throws -> AnalysisDocument.FigureAnnotation {
        let kind: AnalysisDocument.FigureAnnotation.Kind
        if activePlanes.contains(.qqPlot) { kind = .qqPlot }
        else if activePlanes.contains(.residuals) { kind = .residuals }
        else if activePlanes.contains(.gradient) { kind = .gradient }
        else { kind = .fittedCurve }
        let caption = figureCaption.trimmingCharacters(in: .whitespacesAndNewlines)
        return try AnalysisDocument.FigureAnnotation(
            kind: kind,
            caption: caption.isEmpty
                ? "\(kind.rawValue): \(built.controller.yName) by \(built.controller.xName)."
                : caption
        )
    }

    private func createDocumentFromChart() {
        guard case .ready(let built) = phase else { return }
        documentTask?.cancel()
        documentError = nil
        documentRecomputing = true
        do {
            let recipe = try currentDocumentRecipe(for: built)
            let figure = try figureAnnotation(for: built)
            let title = URL(fileURLWithPath: built.fileName).deletingPathExtension().lastPathComponent
                + " — \(built.controller.yName) by \(built.controller.xName)"
            documentTask = Task {
                do {
                    let document = try await Task.detached(priority: .userInitiated) {
                        try AnalysisDocumentExecutor.createDocument(
                            title: title, sourceURL: built.fileURL, loaded: built.loaded,
                            sourceRows: built.keptSourceRows, model: recipe, figure: figure
                        )
                    }.value
                    guard !Task.isCancelled else { return }
                    analysisDocument = document
                    documentURL = nil
                    documentSourceURL = built.fileURL
                    figureCaption = ""
                    documentRecomputing = false
                } catch is CancellationError {
                    guard !Task.isCancelled else { return }
                    documentRecomputing = false
                } catch {
                    guard !Task.isCancelled else { return }
                    documentError = String(describing: error)
                    documentRecomputing = false
                }
            }
        } catch {
            documentError = String(describing: error)
            documentRecomputing = false
        }
    }

    private func openDocument(_ url: URL) {
        documentTask?.cancel()
        documentError = nil
        documentRecomputing = true
        documentTask = Task {
            do {
                let document = try await Task.detached(priority: .userInitiated) {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                    return try AnalysisDocument(jsonData: Data(contentsOf: url))
                }.value
                guard !Task.isCancelled else { return }
                analysisDocument = document
                documentURL = url
                // A document never persists an absolute source path. Make
                // attachment an explicit user decision even if another chart
                // happens to be visible in this window.
                documentSourceURL = nil
                figureCaption = ""
                documentRecomputing = false
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                documentRecomputing = false
            } catch {
                guard !Task.isCancelled else { return }
                documentError = String(describing: error)
                documentRecomputing = false
            }
        }
    }

    private func saveDocument() {
        guard let analysisDocument else { return }
        do {
            documentExport = AnalysisDocumentFile(data: try analysisDocument.jsonData())
            showingDocumentExporter = true
        } catch {
            documentError = String(describing: error)
        }
    }

    private func updateDocumentRecipe(from built: BuiltChart) {
        guard var document = analysisDocument, let modelID = document.latestModelBlockID else { return }
        do {
            let stale = try document.update(blockID: modelID, payload: .model(currentDocumentRecipe(for: built)))
            analysisDocument = document
            documentSourceURL = built.fileURL
            documentError = stale.isEmpty ? nil : "Model recipe changed; dependent figures and evidence are stale."
        } catch {
            documentError = String(describing: error)
        }
    }

    private func appendFigureAnnotation(from built: BuiltChart) {
        guard var document = analysisDocument, let modelID = document.latestModelBlockID else { return }
        do {
            let annotation = try figureAnnotation(for: built)
            let block = try AnalysisDocument.Block(
                title: "Figure: \(annotation.kind.rawValue)", upstreamBlockIDs: [modelID],
                payload: .figure(annotation)
            )
            try document.append(block)
            analysisDocument = document
            figureCaption = ""
            documentError = nil
        } catch {
            documentError = String(describing: error)
        }
    }

    private func recomputeDocument(from sourceURL: URL) {
        guard let document = analysisDocument, let modelID = document.latestModelBlockID else { return }
        documentTask?.cancel()
        documentError = nil
        documentRecomputing = true
        let figureKind = figureKindForCurrentPlanes()
        documentTask = Task {
            do {
                let result = try await scopedDocumentRecompute(
                    document: document, sourceURL: sourceURL, modelBlockID: modelID
                )
                guard !Task.isCancelled else { return }
                var updated = document
                _ = try updated.markCurrent(through: modelID)
                let figure = try AnalysisDocument.FigureAnnotation(
                    kind: figureKind,
                    caption: "Recomputed \(figureKind.rawValue): \(result.fit.loaded.yName) by \(result.fit.loaded.xName)."
                )
                let figureBlock = try AnalysisDocument.Block(
                    title: "Recomputed figure", upstreamBlockIDs: [modelID], payload: .figure(figure)
                )
                try updated.append(figureBlock)
                let evidence = try AnalysisDocumentExecutor.evidenceSnapshot(
                    document: updated, fit: result.fit, sourceURL: sourceURL,
                    workbenchOutputs: result.outputs
                )
                let evidenceBlock = try AnalysisDocument.Block(
                    title: "Recomputed validation evidence", upstreamBlockIDs: [modelID],
                    payload: .evidence(evidence)
                )
                try updated.append(evidenceBlock)
                guard !Task.isCancelled else { return }
                let built = BuiltChart(
                    controller: result.fit.controller, loaded: result.fit.loaded,
                    fileName: sourceURL.lastPathComponent, fileURL: sourceURL,
                    columns: result.fit.columns, sourceRows: result.fit.trainingSourceRows
                )
                analysisDocument = updated
                documentSourceURL = sourceURL
                selectedX = built.controller.xName
                selectedY = built.controller.yName
                selectedX2 = nil
                selectedSmoother = built.controller.smoother
                visibleDomain = nil
                inspectorX = nil
                loadedSurface = nil
                workbenchOutputs = result.outputs
                phase = .ready(built)
                documentRecomputing = false
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                documentRecomputing = false
            } catch {
                guard !Task.isCancelled else { return }
                documentError = String(describing: error)
                documentRecomputing = false
            }
        }
    }

    private func figureKindForCurrentPlanes() -> AnalysisDocument.FigureAnnotation.Kind {
        if activePlanes.contains(.qqPlot) { return .qqPlot }
        if activePlanes.contains(.residuals) { return .residuals }
        if activePlanes.contains(.gradient) { return .gradient }
        return .fittedCurve
    }

    private func advancedRecipe(for built: BuiltChart) throws -> AnalysisDocument.AdvancedModelRecipe {
        var predictors = [built.controller.xName]
        if advancedStrategy.requiresSecondPredictor {
            guard let selectedX2, selectedX2 != built.controller.xName else {
                throw AnalysisDocumentExecutionError.invalidModelRecipe
            }
            predictors.append(selectedX2)
        }
        let strategy: StatisticalModelStrategy
        let specification: StatisticalModelSpecification
        switch advancedStrategy {
        case .gaussianGAM:
            strategy = .additiveGaussian
            specification = StatisticalModelSpecification(
                strategy: strategy,
                additive: AdditiveModelSpecification(
                    terms: predictors.indices.map { AdditiveTermSpecification(predictorIndex: $0) }
                )
            )
        case .binomialGAM, .poissonGAM:
            strategy = advancedStrategy == .binomialGAM ? .additiveBinomial : .additivePoisson
            specification = StatisticalModelSpecification(
                strategy: strategy,
                likelihoodAdditive: LikelihoodAdditiveModelSpecification(
                    terms: predictors.indices.map { LikelihoodAdditiveTermSpecification(predictorIndex: $0) }
                )
            )
        case .gaussianMultivariate, .binomialMultivariate, .poissonMultivariate:
            switch advancedStrategy {
            case .gaussianMultivariate: strategy = .multivariateGaussian
            case .binomialMultivariate: strategy = .multivariateBinomial
            case .poissonMultivariate: strategy = .multivariatePoisson
            default: preconditionFailure("Covered by the enclosing switch")
            }
            specification = StatisticalModelSpecification(
                strategy: strategy,
                multivariate: MultivariateModelSpecification(
                    terms: predictors.indices.map {
                        .spline(SplineTermSpecification(predictorIndex: $0, knotCount: 3))
                    }, solverPreference: advancedSolver
                )
            )
        }
        let partitioning: ValidationPartitioning = strategy == .additiveBinomial
            || strategy == .multivariateBinomial ? .stratifiedBinary : .blocked
        let validation = ValidationConfiguration(
            foldCount: 5, partitioning: partitioning, specification: specification
        )
        let query: [[Double]]
        let bootstrap: BootstrapConfiguration?
        if advancedBootstrap && !advancedStrategy.requiresSecondPredictor {
            guard
                  let median = built.loaded.model.rawX.sorted().dropFirst(
                      max(0, built.loaded.model.rawX.count - 1) / 2
                  ).first else {
                throw AnalysisDocumentExecutionError.invalidModelRecipe
            }
            query = [[median]]
            bootstrap = BootstrapConfiguration(
                replicateCount: 50, minimumSuccessFraction: 0.8, specification: specification
            )
        } else {
            query = []
            bootstrap = nil
        }
        return try AnalysisDocument.AdvancedModelRecipe(
            predictorColumns: predictors, responseColumn: built.controller.yName,
            specification: specification, validationConfiguration: validation,
            bootstrapConfiguration: bootstrap, stabilityQueries: query
        )
    }

    private func fitAndRecordAdvancedModel(from built: BuiltChart) {
        guard let document = analysisDocument, let sourceURL = documentSourceURL else { return }
        advancedTask?.cancel()
        documentError = nil
        advancedLoading = true
        do {
            let recipe = try advancedRecipe(for: built)
            let upstream = document.latestModelBlockID.map { [$0] } ?? []
            let modelBlock = try AnalysisDocument.Block(
                title: advancedStrategy.rawValue, upstreamBlockIDs: upstream,
                payload: .advancedModel(recipe)
            )
            var prepared = document
            try prepared.append(modelBlock)
            advancedTask = Task {
                do {
                    let run = try await Task.detached(priority: .userInitiated) {
                        try scopedAdvancedDocumentRun(
                            document: prepared, sourceURL: sourceURL, modelBlockID: modelBlock.id
                        )
                    }.value
                    guard !Task.isCancelled else { return }
                    var updated = prepared
                    let figureKind: AnalysisDocument.FigureAnnotation.Kind = advancedStrategy.requiresSecondPredictor
                        ? .surface : .fittedCurve
                    let figure = try AnalysisDocument.FigureAnnotation(
                        kind: figureKind,
                        caption: "\(advancedStrategy.rawValue) fit: \(recipe.responseColumn) by \(recipe.predictorColumns.joined(separator: ", "))."
                    )
                    try updated.append(AnalysisDocument.Block(
                        title: "Advanced model figure", upstreamBlockIDs: [modelBlock.id], payload: .figure(figure)
                    ))
                    try updated.append(AnalysisDocument.Block(
                        title: "Advanced validation evidence", upstreamBlockIDs: [modelBlock.id],
                        payload: .advancedEvidence(run.evidence)
                    ))
                    analysisDocument = updated
                    advancedLoading = false
                } catch is CancellationError {
                    guard !Task.isCancelled else { return }
                    advancedLoading = false
                } catch {
                    guard !Task.isCancelled else { return }
                    documentError = String(describing: error)
                    advancedLoading = false
                }
            }
        } catch {
            documentError = String(describing: error)
            advancedLoading = false
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

    /// Copy a schema-versioned provenance + observation report as JSON.
    private func exportAnalysisReport() {
        guard case .ready(let built) = phase else { return }
        let report = AnalysisReport.make(
            from: built.loaded, sourceURL: built.fileURL,
            inputObservationCount: built.controller.trainY.count,
            sourceRows: built.keptSourceRows
        )
        guard let data = try? report.jsonData(),
              let json = String(data: data, encoding: .utf8) else { return }
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(json, forType: NSPasteboard.PasteboardType("public.json"))
        pb.setString(json, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = json
        #endif
    }

    /// Copy workspace choices (not the source file or its path) as a
    /// versioned JSON session that another host can validate and replay.
    private func exportWorkbenchSession() {
        guard case .ready(let built) = phase,
              let source = try? WorkbenchSource(
                  displayName: built.fileName, inputObservationCount: built.controller.trainY.count
              ),
              let session = try? WorkbenchSession(
                  source: source, predictor: built.controller.xName, response: built.controller.yName,
                  secondPredictor: selectedX2, smoother: built.controller.smoother,
                  budget: built.controller.budget, activePlanesRawValue: activePlanes.rawValue,
                  enabledToolIDs: WorkbenchCatalog.builtIns.toolIDs,
                  validationConfiguration: validationConfiguration(for: built)
              ),
              let data = try? session.jsonData(), let json = String(data: data, encoding: .utf8)
        else { return }
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(json, forType: NSPasteboard.PasteboardType("public.json"))
        pb.setString(json, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = json
        #endif
    }

    /// Run the portable catalog off the main actor. The catalog's input has no
    /// view or URL dependency, so a future host can use the exact same tools.
    private func runWorkbench(for built: BuiltChart) {
        workbenchTask?.cancel()
        workbenchOutputs = []
        workbenchError = nil
        guard let source = try? WorkbenchSource(
            displayName: built.fileName, inputObservationCount: built.controller.trainY.count
        ), let input = try? WorkbenchInput(
            loaded: built.loaded, source: source, sourceRows: built.keptSourceRows,
            validationConfiguration: validationConfiguration(for: built)
        ) else {
            workbenchError = "Could not prepare this chart for the workbench."
            return
        }
        workbenchLoading = true
        workbenchTask = Task {
            do {
                let outputs = try await Task.detached(priority: .userInitiated) {
                    try await WorkbenchCatalog.builtIns.runAll(on: input)
                }.value
                guard !Task.isCancelled else { return }
                workbenchOutputs = outputs
                workbenchLoading = false
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                workbenchLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                workbenchError = String(describing: error)
                workbenchLoading = false
            }
        }
    }

    private func clearWorkbench() {
        workbenchTask?.cancel()
        workbenchTask = nil
        workbenchOutputs = []
        workbenchError = nil
        workbenchLoading = false
    }

    /// Reuse the visible chart's interactive fitting policy for held-out fits.
    /// This keeps validation honest without silently escalating a user's
    /// lightweight exploration into a much more expensive full tuning sweep.
    private func validationConfiguration(for built: BuiltChart) -> ValidationConfiguration {
        let budget = built.controller.budget
        return ValidationConfiguration(
            foldCount: 5, partitioning: .shuffled,
            specification: StatisticalModelSpecification(
                degree: budget.degree, spans: budget.spans,
                robustIterations: budget.robustIterations,
                adaptiveContender: budget.adaptiveContender
            )
        )
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
        clearWorkbench()
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
        clearWorkbench()
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
        clearWorkbench()
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
        clearWorkbench()
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
                    fileName: built.fileName, fileURL: built.fileURL, columns: built.columns,
                    sourceRows: built.sourceRows
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

    private func workbenchMetricValue(_ metric: WorkbenchMetric) -> String {
        metric.text ?? metric.value.map(fmt6) ?? "Unavailable"
    }
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
        fileName: url.lastPathComponent, fileURL: url, columns: columns, sourceRows: nil
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
        fileName: url.lastPathComponent, fileURL: url, columns: columns, sourceRows: nil
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

private struct DocumentRecomputeResult: Sendable {
    let fit: AnalysisDocumentFit
    let outputs: [WorkbenchOutput]
}

private struct AdvancedDocumentRun: Sendable {
    let fit: AdvancedAnalysisDocumentFit
    let evidence: AnalysisDocument.AdvancedModelEvidence
}

/// Keep the security-scoped resource alive across the complete replay, fit,
/// and validation run selected from the document workbench.
private func scopedDocumentRecompute(
    document: AnalysisDocument, sourceURL: URL, modelBlockID: UUID
) async throws -> DocumentRecomputeResult {
    let didAccess = sourceURL.startAccessingSecurityScopedResource()
    defer {
        if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
    }
    let fit = try await AnalysisDocumentExecutor.fit(
        document: document, sourceURL: sourceURL, modelBlockID: modelBlockID
    )
    try Task.checkCancellation()
    let input = try AnalysisDocumentExecutor.workbenchInput(document: document, fit: fit)
    let outputs = try await WorkbenchCatalog.builtIns.runAll(on: input)
    try Task.checkCancellation()
    return DocumentRecomputeResult(fit: fit, outputs: outputs)
}

/// The advanced workflow keeps one security-scoped source available for
/// parsing, fitting, held-out validation, and optional bootstrap refits.
private func scopedAdvancedDocumentRun(
    document: AnalysisDocument, sourceURL: URL, modelBlockID: UUID
) throws -> AdvancedDocumentRun {
    let didAccess = sourceURL.startAccessingSecurityScopedResource()
    defer {
        if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
    }
    let fit = try AnalysisDocumentExecutor.fitAdvanced(
        document: document, sourceURL: sourceURL, modelBlockID: modelBlockID
    )
    let evidence = try AnalysisDocumentExecutor.advancedEvidenceSnapshot(document: document, fit: fit)
    return AdvancedDocumentRun(fit: fit, evidence: evidence)
}
