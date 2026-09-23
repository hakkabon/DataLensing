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

    var isBinomial: Bool {
        switch self {
        case .binomialGAM, .binomialMultivariate: return true
        default: return false
        }
    }
}

private enum ValidationPlanIntentChoice: String, CaseIterable, Identifiable {
    case exchangeable = "Shuffled / exchangeable"
    case orderedOrSpatial = "Blocked / ordered"
    case binaryClassification = "Stratified / binary"

    var id: String { rawValue }

    var intendedUse: AnalysisDocument.ValidationPlan.IntendedUse {
        switch self {
        case .exchangeable: return .exchangeable
        case .orderedOrSpatial: return .orderedOrSpatial
        case .binaryClassification: return .binaryClassification
        }
    }

    var partitioning: ValidationPartitioning {
        switch self {
        case .exchangeable: return .shuffled
        case .orderedOrSpatial: return .blocked
        case .binaryClassification: return .stratifiedBinary
        }
    }
}

private enum AdvancedScaleChoice: String, CaseIterable, Identifiable {
    case full = "Full finite data"
    case bounded25k = "Bounded 25k stratified"
    case bounded100k = "Bounded 100k stratified"

    var id: String { rawValue }

    var needsSeed: Bool { self != .full }

    func policy(seed: UInt64) -> StatisticalScalePolicy {
        switch self {
        case .full: return .fullData
        case .bounded25k: return .stratifiedLeadingPredictor(maximumObservations: 25_000, seed: seed)
        case .bounded100k: return .stratifiedLeadingPredictor(maximumObservations: 100_000, seed: seed)
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
    @State private var showingPublicationExporter = false
    @State private var publicationExport: AnalysisDocumentFile?
    @State private var publicationSnapshot: AnalysisPublication?
    @State private var publicationTitle = ""
    @State private var publicationAbstract = ""
    @State private var figureCaption = ""
    @State private var advancedStrategy: AdvancedStrategyChoice = .gaussianGAM
    @State private var advancedSolver: MultivariateSolverPreference = .automatic
    @State private var advancedScale: AdvancedScaleChoice = .full
    @State private var advancedScaleSeed = "0"
    @State private var advancedBootstrap = false
    @State private var validationPlanName = "Validation plan"
    @State private var validationPlanIntent: ValidationPlanIntentChoice = .orderedOrSpatial
    @State private var validationPlanFoldCount = 5
    @State private var validationPlanSeed = "0"
    @State private var validationPlanBootstrap = false
    @State private var validationPlanCohort = ""
    @State private var selectedValidationPlanBlockID: UUID?
    @State private var compositionSectionTitle = "Conclusion"
    @State private var compositionSectionNarrative = ""
    @State private var selectedCompositionSectionID: UUID?
    @State private var selectedUncomposedBlockID: UUID?
    @State private var reviewAuthor = ""
    @State private var reviewBody = ""
    @State private var reviewSeverity: AnalysisDocument.DocumentReview.Finding.Severity = .concern
    @State private var selectedReviewTargetBlockID: UUID?
    @State private var selectedReviewFindingID: UUID?
    @State private var reviewResolution = ""
    @State private var selectedComparisonBaselineRunID: UUID?
    @State private var selectedComparisonCandidateRunID: UUID?
    @State private var evidenceSynthesisTitle = "Evidence synthesis"
    @State private var evidenceSynthesisQuestion = ""
    @State private var evidenceSynthesisConclusion = ""
    @State private var evidenceSynthesisAssessment: AnalysisDocument.EvidenceSynthesis.Assessment = .inconclusive
    @State private var evidenceSynthesisCaveats = ""
    @State private var selectedSynthesisEvidenceBlockIDs = Set<UUID>()
    @State private var experimentTitle = "Experiment protocol"
    @State private var experimentQuestion = ""
    @State private var experimentHypothesis = ""
    @State private var experimentPrimaryEndpoint = "Held-out predictive loss"
    @State private var experimentDecisionRule = "Use comparable held-out evidence to choose the next model iteration."
    @State private var selectedExperimentModelBlockIDs = Set<UUID>()
    @State private var selectedExperimentProtocolBlockID: UUID?
    @State private var selectedExperimentRunBlockIDs = Set<UUID>()
    @State private var selectedExperimentSynthesisBlockID: UUID?
    @State private var experimentCheckpointStatus: AnalysisDocument.ExperimentCheckpoint.Status = .inProgress
    @State private var experimentDeviationNote = ""
    @State private var experimentNextStep = "Review the checkpoint and record the next planned iteration."
    @State private var selectedRunDiffBaselineID: UUID?
    @State private var selectedRunDiffCandidateID: UUID?
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
        .fileExporter(
            isPresented: $showingPublicationExporter, document: publicationExport,
            contentType: .json, defaultFilename: publicationDefaultFileName
        ) { result in
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

                    Divider()
                    Text("Validation plans are reusable, saved fold and stability policies.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    TextField("Plan name", text: $validationPlanName)
                        .font(.caption)
                    Picker("Fold assignment", selection: $validationPlanIntent) {
                        ForEach(ValidationPlanIntentChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    Picker("Folds", selection: $validationPlanFoldCount) {
                        ForEach([2, 3, 5, 10], id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    TextField("Validation seed", text: $validationPlanSeed)
                        .font(.caption)
                    Toggle("Include bootstrap stability (50)", isOn: $validationPlanBootstrap)
                    TextField("Comparison cohort (optional)", text: $validationPlanCohort)
                        .font(.caption)
                    Button {
                        appendValidationPlan()
                    } label: {
                        Label("Save Validation Plan", systemImage: "checklist.checked")
                    }
                    .disabled(documentRecomputing || advancedLoading)

                    if !document.validationPlanBlocks.isEmpty {
                        Picker("Advanced validation", selection: $selectedValidationPlanBlockID) {
                            Text("Embedded validation").tag(UUID?.none)
                            ForEach(document.validationPlanBlocks) { block in
                                Text(block.title).tag(Optional(block.id))
                            }
                        }
                        .font(.caption)
                    }

                    Divider()
                    Label("Notebook composition", systemImage: "rectangle.3.group")
                        .font(.caption.weight(.semibold))
                    Text("Arrange existing analysis blocks into a reader-facing narrative; composition never recomputes a model.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if document.composition.sections.isEmpty {
                        Button {
                            createInitialComposition()
                        } label: {
                            Label("Create Review Outline", systemImage: "text.badge.checkmark")
                        }
                        .disabled(documentRecomputing || document.blocks.isEmpty)
                    } else {
                        Text("\(document.composition.sections.count) sections · \(document.uncomposedBlocks.count) uncomposed blocks")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Picker("Edit section", selection: $selectedCompositionSectionID) {
                            ForEach(document.composition.sections) { section in
                                Text(section.title).tag(Optional(section.id))
                            }
                        }
                        .onChange(of: selectedCompositionSectionID) { _, sectionID in
                            loadCompositionSection(sectionID, from: document)
                        }
                        TextField("Section title", text: $compositionSectionTitle)
                            .font(.caption)
                        TextField("Section narrative", text: $compositionSectionNarrative)
                            .font(.caption)
                        HStack {
                            Button("Add Section") { appendCompositionSection() }
                            Button("Update Section") { updateCompositionSection() }
                                .disabled(selectedCompositionSectionID == nil)
                        }
                        .font(.caption)
                        if let sectionID = selectedCompositionSectionID,
                           !document.uncomposedBlocks.isEmpty {
                            Picker("Place block", selection: $selectedUncomposedBlockID) {
                                Text("Choose block").tag(UUID?.none)
                                ForEach(document.uncomposedBlocks) { block in
                                    Text(block.title).tag(Optional(block.id))
                                }
                            }
                            Button("Add Block to Section") {
                                assignUncomposedBlock(to: sectionID)
                            }
                            .font(.caption)
                            .disabled(selectedUncomposedBlockID == nil)
                        }
                        ForEach(document.composition.sections) { section in
                            compositionSectionRow(section, in: document)
                        }
                    }

                    Divider()
                    reviewPanel(for: document)

                    Divider()
                    publicationPanel(for: document)

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
                        Picker("Statistical scale", selection: $advancedScale) {
                            ForEach(AdvancedScaleChoice.allCases) { choice in
                                Text(choice.rawValue).tag(choice)
                            }
                        }
                        if advancedScale.needsSeed {
                            TextField("Scale-selection seed", text: $advancedScaleSeed)
                                .font(.caption)
                        }
                        Text("Bounded fits preserve leading-predictor coverage and record their deterministic seed in the run.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if advancedStrategy.requiresSecondPredictor {
                            Picker("Numerical solve", selection: $advancedSolver) {
                                Text("Automatic").tag(MultivariateSolverPreference.automatic)
                                Text("Dense QR").tag(MultivariateSolverPreference.denseQR)
                                Text("Sparse CGLS").tag(MultivariateSolverPreference.sparseCGLS)
                            }
                        } else if selectedValidationPlanBlockID == nil {
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
                                || (advancedStrategy.requiresSecondPredictor && selectedValidationPlanHasBootstrap(in: document))
                                || selectedValidationPlanIsIncompatible(in: document)
                        )
                    }

                    numericalExecutionPanel(for: document)

                    reproducibilityPanel(for: document)

                    experimentWorkflowPanel(for: document)

                    comparativeEvidencePanel(for: document)

                    evidenceSynthesisPanel(for: document)

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

    private var publicationDefaultFileName: String {
        let title = publicationSnapshot?.title ?? analysisDocument?.title ?? "analysis-publication"
        let safe = title.replacingOccurrences(of: "/", with: "-")
        return safe.isEmpty ? "analysis-publication" : "\(safe)-publication"
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

    private func selectedValidationPlan(in document: AnalysisDocument) -> AnalysisDocument.ValidationPlan? {
        guard let selectedValidationPlanBlockID else { return nil }
        return document.validationPlan(blockID: selectedValidationPlanBlockID)
    }

    private func selectedValidationPlanHasBootstrap(in document: AnalysisDocument) -> Bool {
        selectedValidationPlan(in: document)?.bootstrap != nil
    }

    private func selectedValidationPlanIsIncompatible(in document: AnalysisDocument) -> Bool {
        guard let plan = selectedValidationPlan(in: document) else { return false }
        return plan.intendedUse == .binaryClassification && !advancedStrategy.isBinomial
    }

    private func appendValidationPlan() {
        guard var document = analysisDocument else { return }
        documentError = nil
        do {
            guard let seed = UInt64(validationPlanSeed.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw AnalysisDocumentError.invalidConfiguration
            }
            let bootstrap = validationPlanBootstrap
                ? try AnalysisDocument.ValidationPlan.BootstrapPolicy(seed: seed)
                : nil
            let plan = try AnalysisDocument.ValidationPlan(
                intendedUse: validationPlanIntent.intendedUse,
                foldCount: validationPlanFoldCount, partitioning: validationPlanIntent.partitioning,
                seed: seed, bootstrap: bootstrap,
                comparisonCohort: validationPlanCohort
            )
            let title = validationPlanName.trimmingCharacters(in: .whitespacesAndNewlines)
            let block = try AnalysisDocument.Block(
                title: title.isEmpty ? "Validation plan" : title,
                payload: .validationPlan(plan)
            )
            try document.append(block)
            analysisDocument = document
            selectedValidationPlanBlockID = block.id
        } catch {
            documentError = String(describing: error)
        }
    }

    private func loadCompositionSection(_ sectionID: UUID?, from document: AnalysisDocument) {
        guard let sectionID,
              let section = document.composition.sections.first(where: { $0.id == sectionID }) else {
            return
        }
        compositionSectionTitle = section.title
        compositionSectionNarrative = section.narrative
    }

    private func createInitialComposition() {
        guard var document = analysisDocument else { return }
        documentError = nil
        do {
            try document.createInitialComposition()
            analysisDocument = document
            if let section = document.composition.sections.first {
                selectedCompositionSectionID = section.id
                loadCompositionSection(section.id, from: document)
            }
        } catch {
            documentError = String(describing: error)
        }
    }

    private func appendCompositionSection() {
        guard var document = analysisDocument else { return }
        documentError = nil
        do {
            let sectionID = try document.appendCompositionSection(
                title: compositionSectionTitle, narrative: compositionSectionNarrative
            )
            analysisDocument = document
            selectedCompositionSectionID = sectionID
        } catch {
            documentError = String(describing: error)
        }
    }

    private func updateCompositionSection() {
        guard var document = analysisDocument,
              let sectionID = selectedCompositionSectionID else { return }
        documentError = nil
        do {
            try document.updateCompositionSection(
                id: sectionID, title: compositionSectionTitle,
                narrative: compositionSectionNarrative
            )
            analysisDocument = document
        } catch {
            documentError = String(describing: error)
        }
    }

    private func moveCompositionSection(_ section: AnalysisDocument.NotebookComposition.Section, by offset: Int) {
        guard var document = analysisDocument,
              let index = document.composition.sections.firstIndex(where: { $0.id == section.id }) else { return }
        let destination = index + offset
        guard document.composition.sections.indices.contains(destination) else { return }
        documentError = nil
        do {
            try document.moveCompositionSection(id: section.id, to: destination)
            analysisDocument = document
        } catch {
            documentError = String(describing: error)
        }
    }

    private func assignUncomposedBlock(to sectionID: UUID) {
        guard var document = analysisDocument,
              let blockID = selectedUncomposedBlockID else { return }
        documentError = nil
        do {
            try document.assignToComposition(blockID: blockID, sectionID: sectionID)
            analysisDocument = document
            selectedUncomposedBlockID = nil
        } catch {
            documentError = String(describing: error)
        }
    }

    private func addReviewFinding() {
        guard var document = analysisDocument else { return }
        documentError = nil
        do {
            let findingID = try document.addReviewFinding(
                author: reviewAuthor, body: reviewBody,
                targetBlockID: selectedReviewTargetBlockID, severity: reviewSeverity
            )
            analysisDocument = document
            selectedReviewFindingID = findingID
            reviewBody = ""
        } catch {
            documentError = String(describing: error)
        }
    }

    private func closeReviewFinding(as status: AnalysisDocument.DocumentReview.Finding.Status) {
        guard var document = analysisDocument, let findingID = selectedReviewFindingID else { return }
        documentError = nil
        do {
            try document.closeReviewFinding(id: findingID, as: status, resolution: reviewResolution)
            analysisDocument = document
            reviewResolution = ""
            selectedReviewFindingID = nil
        } catch {
            documentError = String(describing: error)
        }
    }

    private func setReviewReadiness(_ readiness: AnalysisDocument.DocumentReview.Readiness) {
        guard var document = analysisDocument else { return }
        documentError = nil
        do {
            try document.setReviewReadiness(readiness)
            analysisDocument = document
        } catch {
            documentError = String(describing: error)
        }
    }

    private func recordComparativeEvidence() {
        guard var document = analysisDocument,
              let baseline = selectedComparisonBaselineRunID,
              let candidate = selectedComparisonCandidateRunID else { return }
        documentError = nil
        do {
            _ = try document.recordComparativeEvidence(
                baselineRunBlockID: baseline, candidateRunBlockID: candidate
            )
            analysisDocument = document
        } catch {
            documentError = String(describing: error)
        }
    }

    private func recordEvidenceSynthesis() {
        guard var document = analysisDocument else { return }
        documentError = nil
        let caveats = evidenceSynthesisCaveats.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            _ = try document.recordEvidenceSynthesis(
                title: evidenceSynthesisTitle, question: evidenceSynthesisQuestion,
                conclusion: evidenceSynthesisConclusion,
                assessment: evidenceSynthesisAssessment, caveats: caveats,
                evidenceBlockIDs: document.synthesisCandidateEvidenceBlocks
                    .filter { selectedSynthesisEvidenceBlockIDs.contains($0.id) }
                    .map(\.id)
            )
            analysisDocument = document
            selectedSynthesisEvidenceBlockIDs.removeAll()
        } catch {
            documentError = String(describing: error)
        }
    }

    private func recordExperimentProtocol() {
        guard var document = analysisDocument else { return }
        documentError = nil
        do {
            let candidateIDs = document.experimentCandidateModelBlocks
                .filter { selectedExperimentModelBlockIDs.contains($0.id) }
                .map(\.id)
            let protocolID = try document.recordExperimentProtocol(
                title: experimentTitle, question: experimentQuestion,
                hypothesis: experimentHypothesis, primaryEndpoint: experimentPrimaryEndpoint,
                decisionRule: experimentDecisionRule, modelBlockIDs: candidateIDs
            )
            analysisDocument = document
            selectedExperimentModelBlockIDs.removeAll()
            selectedExperimentProtocolBlockID = protocolID
        } catch {
            documentError = String(describing: error)
        }
    }

    private func recordExperimentCheckpoint() {
        guard var document = analysisDocument,
              let protocolBlockID = selectedExperimentProtocolBlockID else { return }
        documentError = nil
        do {
            let runIDs = document.experimentCandidateRunBlocks(for: protocolBlockID)
                .filter { selectedExperimentRunBlockIDs.contains($0.id) }
                .map(\.id)
            _ = try document.recordExperimentCheckpoint(
                protocolBlockID: protocolBlockID, runBlockIDs: runIDs,
                status: experimentCheckpointStatus,
                synthesisBlockID: selectedExperimentSynthesisBlockID,
                deviationNote: experimentDeviationNote, nextStep: experimentNextStep
            )
            analysisDocument = document
            selectedExperimentRunBlockIDs.removeAll()
            selectedExperimentSynthesisBlockID = nil
            experimentDeviationNote = ""
        } catch {
            documentError = String(describing: error)
        }
    }

    @ViewBuilder
    private func reviewPanel(for document: AnalysisDocument) -> some View {
        let summary = document.reviewSummary
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Label("Review", systemImage: "person.2.badge.gearshape")
                    .font(.caption.weight(.semibold))
                Spacer()
                reviewReadinessBadge(summary)
            }
            Text(
                "\(summary.openFindingCount) open findings · \(summary.openBlockerCount) blockers · \(summary.staleBlockCount) stale blocks"
            )
            .font(.caption2)
            .foregroundStyle(summary.canMarkReady ? Color.secondary : Color.orange)
            Text("Saved findings travel with this document; author labels are not authenticated identities or live collaboration.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("Reviewer label", text: $reviewAuthor)
                .font(.caption)
            TextField("Finding", text: $reviewBody)
                .font(.caption)
            Picker("Severity", selection: $reviewSeverity) {
                ForEach(AnalysisDocument.DocumentReview.Finding.Severity.allCases, id: \.self) { severity in
                    Text(severity.rawValue.capitalized).tag(severity)
                }
            }
            Picker("Applies to", selection: $selectedReviewTargetBlockID) {
                Text("Whole document").tag(UUID?.none)
                ForEach(document.blocks) { block in
                    Text(block.title).tag(Optional(block.id))
                }
            }
            Button("Add Finding") { addReviewFinding() }
                .font(.caption)
                .disabled(
                    documentRecomputing
                        || reviewAuthor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || reviewBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

            HStack(spacing: 6) {
                Button("Mark Ready") { setReviewReadiness(.readyForReview) }
                    .disabled(documentRecomputing || !summary.canMarkReady)
                Button("Accept") { setReviewReadiness(.accepted) }
                    .disabled(documentRecomputing || !summary.canAccept)
            }
            .font(.caption)

            if !document.review.findings.isEmpty {
                Picker("Close finding", selection: $selectedReviewFindingID) {
                    Text("Choose finding").tag(UUID?.none)
                    ForEach(document.review.openFindings) { finding in
                        Text(reviewFindingPickerTitle(finding, in: document)).tag(Optional(finding.id))
                    }
                }
                .font(.caption)
                TextField("Resolution or dismissal reason", text: $reviewResolution)
                    .font(.caption)
                HStack(spacing: 6) {
                    Button("Resolve") { closeReviewFinding(as: .resolved) }
                    Button("Dismiss") { closeReviewFinding(as: .dismissed) }
                }
                .font(.caption)
                .disabled(
                    selectedReviewFindingID == nil
                        || reviewResolution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                ForEach(document.review.findings) { finding in
                    reviewFindingRow(finding, in: document)
                }
            }
        }
    }

    /// Publishing freezes a reader-facing package outside the mutable
    /// notebook. The local snapshot survives later edits in this view, but
    /// only its JSON/Markdown export is intended for sharing.
    @ViewBuilder
    private func publicationPanel(for document: AnalysisDocument) -> some View {
        let accepted = document.reviewSummary.readiness == .accepted
        VStack(alignment: .leading, spacing: 5) {
            Label("Portable publication", systemImage: "shippingbox.fill")
                .font(.caption.weight(.semibold))
            Text("Freeze accepted conclusions, terminal experiment records, review outcomes, and numerical provenance. Source rows and executable code are excluded.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("Publication title (defaults to document title)", text: $publicationTitle)
                .font(.caption)
            TextField("Editorial context (optional)", text: $publicationAbstract)
                .font(.caption)
            Button("Freeze Publication Snapshot") {
                createPublication(from: document)
            }
            .font(.caption)
            .disabled(documentRecomputing || !accepted)

            if !accepted {
                Text("Accept a fully current document before publication can be frozen.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let publicationSnapshot {
                Label(
                    "Frozen \(publicationSnapshot.syntheses.count) syntheses · \(publicationSnapshot.experiments.count) terminal checkpoints",
                    systemImage: "checkmark.seal.fill"
                )
                .font(.caption2)
                .foregroundStyle(.green)
                HStack(spacing: 6) {
                    Button("Copy Markdown") { copyPublicationMarkdown(publicationSnapshot) }
                    Button("Export JSON…") { exportPublication(publicationSnapshot) }
                }
                .font(.caption)
                Text("Exports are local files or clipboard content; this does not send a publication to a service.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func createPublication(from document: AnalysisDocument) {
        documentError = nil
        do {
            let title = publicationTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            publicationSnapshot = try AnalysisPublication.make(
                from: document, title: title.isEmpty ? nil : title,
                abstract: publicationAbstract
            )
        } catch {
            documentError = String(describing: error)
        }
    }

    private func exportPublication(_ publication: AnalysisPublication) {
        documentError = nil
        do {
            publicationExport = AnalysisDocumentFile(data: try publication.jsonData())
            showingPublicationExporter = true
        } catch {
            documentError = String(describing: error)
        }
    }

    private func copyPublicationMarkdown(_ publication: AnalysisPublication) {
        let markdown = publication.markdown()
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(markdown, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = markdown
        #endif
    }

    @ViewBuilder
    private func reviewReadinessBadge(_ summary: AnalysisDocument.ReviewSummary) -> some View {
        let isAccepted = summary.readiness == .accepted
        let isReady = summary.readiness == .readyForReview
        Label(
            isAccepted ? "Accepted" : (isReady ? "Ready" : "Draft"),
            systemImage: isAccepted ? "checkmark.seal.fill" : (isReady ? "eye.fill" : "pencil.circle")
        )
        .font(.caption2.weight(.medium))
        .foregroundStyle(isAccepted ? .green : (isReady ? .blue : .secondary))
    }

    private func reviewFindingPickerTitle(
        _ finding: AnalysisDocument.DocumentReview.Finding, in document: AnalysisDocument
    ) -> String {
        let target = finding.targetBlockID.flatMap { id in
            document.blocks.first(where: { $0.id == id })?.title
        } ?? "Document"
        return "[\(finding.severity.rawValue)] \(target)"
    }

    @ViewBuilder
    private func reviewFindingRow(
        _ finding: AnalysisDocument.DocumentReview.Finding, in document: AnalysisDocument
    ) -> some View {
        let target = finding.targetBlockID.flatMap { id in
            document.blocks.first(where: { $0.id == id })?.title
        } ?? "Whole document"
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(finding.severity.rawValue.capitalized).font(.caption2.weight(.semibold))
                    .foregroundStyle(finding.severity == .blocker ? Color.red : Color.secondary)
                Text("· \(finding.status.rawValue) · \(target)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(finding.body).font(.caption).lineLimit(2)
            Text(finding.author).font(.caption2).foregroundStyle(.secondary)
            if let resolution = finding.resolution {
                Text("→ \(resolution)").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func compositionSectionRow(
        _ section: AnalysisDocument.NotebookComposition.Section, in document: AnalysisDocument
    ) -> some View {
        let index = document.composition.sections.firstIndex(where: { $0.id == section.id }) ?? 0
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(Color.accentColor)
                Text(section.title).font(.caption.weight(.medium)).lineLimit(1)
                Spacer()
                Button { moveCompositionSection(section, by: -1) } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                Button { moveCompositionSection(section, by: 1) } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(index == document.composition.sections.count - 1)
            }
            if !section.narrative.isEmpty {
                Text(section.narrative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Text("\(section.blockIDs.count) blocks")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func reproducibilityPanel(for document: AnalysisDocument) -> some View {
        let runs = document.runBlocks
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            Label("Reproducibility", systemImage: "seal.text.page")
                .font(.caption.weight(.semibold))
            Text("Each new run records its resolved statistical/numerical stack and runtime target. Legacy runs remain readable but do not claim an environment match.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let latest = runs.last, case .run(let run) = latest.payload {
                executionEnvironmentSummary(run.executionEnvironment)
            } else {
                Text("Record an explicit run to capture execution provenance.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if runs.count >= 2 {
                Picker("Baseline run", selection: $selectedRunDiffBaselineID) {
                    Text("Choose baseline").tag(UUID?.none)
                    ForEach(runs) { runBlock in
                        Text(runDiffTitle(runBlock, in: document)).tag(Optional(runBlock.id))
                    }
                }
                .font(.caption)
                Picker("Candidate run", selection: $selectedRunDiffCandidateID) {
                    Text("Choose candidate").tag(UUID?.none)
                    ForEach(runs) { runBlock in
                        Text(runDiffTitle(runBlock, in: document)).tag(Optional(runBlock.id))
                    }
                }
                .font(.caption)
                if let baseline = selectedRunDiffBaselineID,
                   let candidate = selectedRunDiffCandidateID,
                   baseline != candidate,
                   let difference = try? document.difference(
                    baselineRunBlockID: baseline, candidateRunBlockID: candidate
                   ) {
                    runDifferenceSummary(difference)
                }
            }
        }
    }

    @ViewBuilder
    private func executionEnvironmentSummary(_ environment: AnalysisDocument.ExecutionEnvironment?) -> some View {
        if let environment {
            Text(
                "DataLens \(environment.swiftDataLensVersion) · NumericCore \(environment.swiftNumericCoreVersion) · Rust \(environment.rustNumericCoreVersion)"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text("\(environment.platform) / \(environment.architecture) · build \(environment.hostBuildIdentifier)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("Legacy run: execution environment was not recorded.")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private func runDiffTitle(_ runBlock: AnalysisDocument.Block, in document: AnalysisDocument) -> String {
        guard case .run(let run) = runBlock.payload else { return runBlock.title }
        let modelTitle = document.blocks.first(where: { $0.id == run.modelBlockID })?.title ?? "model"
        return "\(modelTitle) · \(run.status.rawValue) · seed \(run.validationSeed)"
    }

    @ViewBuilder
    private func runDifferenceSummary(_ difference: AnalysisDocument.AnalysisRunDifference) -> some View {
        let inputStatus = difference.replayInputsMatch ? "same replay inputs" : "replay inputs changed"
        let environmentStatus = runDifferenceEnvironmentStatusText(difference.environmentStatus)
        let retained = [difference.baselineRetainedObservationCount, difference.candidateRetainedObservationCount]
            .map { $0.map(String.init) ?? "not retained" }.joined(separator: " → ")
        VStack(alignment: .leading, spacing: 1) {
            Text("\(inputStatus) · \(environmentStatus)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(
                    difference.replayInputsMatch && difference.environmentStatus == .exact
                        ? Color.green : Color.orange
                )
            Text(
                "model \(difference.modelRecipeMatches ? "same" : "changed") · solver \(difference.solverPreferenceMatches ? "same" : "changed") · bootstrap \(difference.bootstrapSeedMatches ? "same" : "changed")"
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text("outcome \(difference.baselineStatus.rawValue) → \(difference.candidateStatus.rawValue) · rows \(retained)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func runDifferenceEnvironmentStatusText(
        _ status: AnalysisDocument.AnalysisRunDifference.EnvironmentStatus
    ) -> String {
        switch status {
        case .exact:
            return "same environment"
        case .changed:
            return "environment changed"
        case .unavailableInLegacyRun:
            return "legacy environment unavailable"
        }
    }

    @ViewBuilder
    private func experimentWorkflowPanel(for document: AnalysisDocument) -> some View {
        let modelCandidates = document.experimentCandidateModelBlocks
        let protocols = document.experimentProtocolBlocks.filter { $0.state == .current }
        let selectedProtocol = selectedExperimentProtocolBlockID.flatMap { id in
            protocols.first(where: { $0.id == id })
        }
        let runCandidates = selectedExperimentProtocolBlockID.map {
            document.experimentCandidateRunBlocks(for: $0)
        } ?? []
        let synthesisCandidates = document.experimentCandidateSynthesisBlocks
        let selectedRunCount = runCandidates.filter {
            selectedExperimentRunBlockIDs.contains($0.id)
        }.count
        let plannedArmCount: Int = {
            guard let selectedProtocol,
                  case .experimentProtocol(let protocolValue) = selectedProtocol.payload else { return 0 }
            return protocolValue.arms.count
        }()
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            Label("Experiment workflow", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption.weight(.semibold))
            Text("Pre-specify arms, endpoint, and decision rule; then record completed-run checkpoints. This does not refit models or infer an outcome.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if modelCandidates.count < 2 {
                Text("Record two current model recipes to plan an experiment.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Protocol title", text: $experimentTitle)
                    .font(.caption)
                TextField("Question", text: $experimentQuestion)
                    .font(.caption)
                TextField("Hypothesis", text: $experimentHypothesis)
                    .font(.caption)
                TextField("Primary endpoint", text: $experimentPrimaryEndpoint)
                    .font(.caption)
                TextField("Decision rule", text: $experimentDecisionRule)
                    .font(.caption)
                Text("Select model arms")
                    .font(.caption2.weight(.medium))
                ForEach(modelCandidates) { block in
                    Toggle(block.title, isOn: experimentModelSelectionBinding(for: block.id))
                        .font(.caption2)
                }
                Button("Record Protocol") { recordExperimentProtocol() }
                    .font(.caption)
                    .disabled(
                        documentRecomputing || selectedExperimentModelBlockIDs.count < 2
                            || experimentTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || experimentQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || experimentHypothesis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || experimentPrimaryEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || experimentDecisionRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
            if !protocols.isEmpty {
                Picker("Checkpoint protocol", selection: $selectedExperimentProtocolBlockID) {
                    Text("Choose protocol").tag(UUID?.none)
                    ForEach(protocols) { block in
                        Text(experimentProtocolTitle(block)).tag(Optional(block.id))
                    }
                }
                .font(.caption)
                if selectedProtocol != nil {
                    Text("Run coverage: \(selectedRunCount)/\(plannedArmCount) planned arms")
                        .font(.caption2)
                        .foregroundStyle(
                            experimentCheckpointStatus == .completed && selectedRunCount != plannedArmCount
                                ? Color.orange : Color.secondary
                        )
                    if runCandidates.isEmpty {
                        Text("No completed current runs match this protocol's arms yet.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(runCandidates) { block in
                            Toggle(experimentRunTitle(block, in: document), isOn: experimentRunSelectionBinding(for: block.id))
                                .font(.caption2)
                        }
                    }
                    Picker("Checkpoint status", selection: $experimentCheckpointStatus) {
                        ForEach(AnalysisDocument.ExperimentCheckpoint.Status.allCases, id: \.self) { status in
                            Text(experimentCheckpointStatusTitle(status)).tag(status)
                        }
                    }
                    .font(.caption)
                    Picker("Linked synthesis", selection: $selectedExperimentSynthesisBlockID) {
                        Text("None").tag(UUID?.none)
                        ForEach(synthesisCandidates) { block in
                            Text(block.title).tag(Optional(block.id))
                        }
                    }
                    .font(.caption)
                    if experimentCheckpointStatus == .stopped {
                        TextField("Deviation / stop reason", text: $experimentDeviationNote, axis: .vertical)
                            .font(.caption)
                            .lineLimit(2...3)
                    }
                    TextField("Next step", text: $experimentNextStep, axis: .vertical)
                        .font(.caption)
                        .lineLimit(2...3)
                    Button("Record Checkpoint") { recordExperimentCheckpoint() }
                        .font(.caption)
                        .disabled(
                            documentRecomputing || selectedRunCount == 0
                                || (experimentCheckpointStatus == .completed
                                    && selectedRunCount != plannedArmCount)
                                || (experimentCheckpointStatus == .stopped
                                    && experimentDeviationNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                || experimentNextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
            ForEach(document.blocks) { block in
                if case .experimentCheckpoint(let checkpoint) = block.payload {
                    experimentCheckpointRow(checkpoint, state: block.state, in: document)
                }
            }
        }
    }

    private func experimentModelSelectionBinding(for blockID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedExperimentModelBlockIDs.contains(blockID) },
            set: { isSelected in
                if isSelected {
                    selectedExperimentModelBlockIDs.insert(blockID)
                } else {
                    selectedExperimentModelBlockIDs.remove(blockID)
                }
            }
        )
    }

    private func experimentRunSelectionBinding(for blockID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedExperimentRunBlockIDs.contains(blockID) },
            set: { isSelected in
                if isSelected {
                    selectedExperimentRunBlockIDs.insert(blockID)
                } else {
                    selectedExperimentRunBlockIDs.remove(blockID)
                }
            }
        )
    }

    private func experimentProtocolTitle(_ block: AnalysisDocument.Block) -> String {
        guard case .experimentProtocol(let protocolValue) = block.payload else { return block.title }
        return "\(block.title) · \(protocolValue.arms.count) arms"
    }

    private func experimentRunTitle(_ block: AnalysisDocument.Block, in document: AnalysisDocument) -> String {
        guard case .run(let run) = block.payload else { return block.title }
        let modelTitle = document.blocks.first(where: { $0.id == run.modelBlockID })?.title ?? "model"
        return "\(modelTitle) · \(run.retainedObservationCount ?? 0) rows"
    }

    private func experimentCheckpointStatusTitle(
        _ status: AnalysisDocument.ExperimentCheckpoint.Status
    ) -> String {
        switch status {
        case .inProgress: return "In progress"
        case .completed: return "Completed"
        case .stopped: return "Stopped"
        }
    }

    @ViewBuilder
    private func experimentCheckpointRow(
        _ checkpoint: AnalysisDocument.ExperimentCheckpoint,
        state: AnalysisDocument.BlockState, in document: AnalysisDocument
    ) -> some View {
        let protocolTitle = document.blocks.first(where: { $0.id == checkpoint.protocolBlockID })?.title
            ?? "missing protocol"
        VStack(alignment: .leading, spacing: 1) {
            Text("\(protocolTitle) · \(experimentCheckpointStatusTitle(checkpoint.status)) · \(checkpoint.armRuns.count) arms")
                .font(.caption2.weight(.medium))
                .foregroundStyle(state == .current ? Color.accentColor : .orange)
            if let deviation = checkpoint.deviationNote {
                Text("Deviation: \(deviation)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("Next: \(checkpoint.nextStep)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func comparativeEvidencePanel(for document: AnalysisDocument) -> some View {
        let candidates = document.comparisonCandidateRunBlocks
        let comparisons = document.blocks.compactMap { block -> AnalysisDocument.ComparativeEvidence? in
            guard case .comparison(let comparison) = block.payload else { return nil }
            return comparison
        }
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            Label("Comparative evidence", systemImage: "arrow.left.arrow.right.circle")
                .font(.caption.weight(.semibold))
            Text("Pairs immutable advanced runs and records either held-out loss evidence or the exact reason a comparison is unavailable.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if candidates.count < 2 {
                Text("Record two completed advanced runs with validation evidence to compare them.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Baseline run", selection: $selectedComparisonBaselineRunID) {
                    Text("Choose baseline").tag(UUID?.none)
                    ForEach(candidates) { runBlock in
                        Text(comparisonRunTitle(runBlock, in: document)).tag(Optional(runBlock.id))
                    }
                }
                .font(.caption)
                Picker("Candidate run", selection: $selectedComparisonCandidateRunID) {
                    Text("Choose candidate").tag(UUID?.none)
                    ForEach(candidates) { runBlock in
                        Text(comparisonRunTitle(runBlock, in: document)).tag(Optional(runBlock.id))
                    }
                }
                .font(.caption)
                Button("Record Comparison") { recordComparativeEvidence() }
                    .font(.caption)
                    .disabled(
                        documentRecomputing || selectedComparisonBaselineRunID == nil
                            || selectedComparisonCandidateRunID == nil
                            || selectedComparisonBaselineRunID == selectedComparisonCandidateRunID
                    )
            }
            ForEach(Array(comparisons.enumerated()), id: \.offset) { _, comparison in
                comparativeEvidenceRow(comparison, in: document)
            }
        }
    }

    private func comparisonRunTitle(_ runBlock: AnalysisDocument.Block, in document: AnalysisDocument) -> String {
        guard case .run(let run) = runBlock.payload else { return runBlock.title }
        let modelTitle = document.blocks.first(where: { $0.id == run.modelBlockID })?.title ?? "model"
        return "\(modelTitle) · seed \(run.validationSeed)"
    }

    @ViewBuilder
    private func comparativeEvidenceRow(
        _ comparison: AnalysisDocument.ComparativeEvidence, in document: AnalysisDocument
    ) -> some View {
        let baseline = document.blocks.first(where: { $0.id == comparison.baselineRunBlockID })
        let candidate = document.blocks.first(where: { $0.id == comparison.candidateRunBlockID })
        let baselineTitle = baseline.map { comparisonRunTitle($0, in: document) } ?? "missing baseline"
        let candidateTitle = candidate.map { comparisonRunTitle($0, in: document) } ?? "missing candidate"
        VStack(alignment: .leading, spacing: 1) {
            Text("\(baselineTitle) → \(candidateTitle)")
                .font(.caption.weight(.medium)).lineLimit(1)
            if comparison.verdict == .comparable,
               let difference = comparison.meanLossDifference,
               let baselineScore = comparison.baselinePrimaryScore,
               let candidateScore = comparison.candidatePrimaryScore {
                Text(String(
                    format: "Paired %@ loss Δ %.4g · scores %.4g → %.4g · %@/%d candidate wins",
                    comparison.responseFamily?.rawValue ?? "held-out", difference,
                    baselineScore, candidateScore, comparison.candidateWinCount,
                    comparison.pairedObservationCount
                ))
                .font(.caption2)
                .foregroundStyle(
                    difference < 0 ? Color.green : (difference > 0 ? Color.orange : Color.secondary)
                )
            } else {
                Text("Not comparable: \(comparisonVerdictDescription(comparison.verdict))")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func comparisonVerdictDescription(_ verdict: AnalysisDocument.ComparativeEvidence.Verdict) -> String {
        switch verdict {
        case .comparable: return "paired held-out evidence"
        case .sourceFingerprintMismatch: return "source fingerprints differ"
        case .transformationLineageMismatch: return "transformation lineage differs"
        case .scaleSelectionMismatch: return "statistical scale selection differs"
        case .validationConfigurationMismatch: return "validation configuration differs"
        case .validationUnavailable: return "held-out validation was not recorded"
        case .responseFamilyMismatch: return "response families differ"
        case .heldOutObservationsMismatch: return "held-out observations differ"
        case .foldAssignmentMismatch: return "fold assignment differs"
        }
    }

    @ViewBuilder
    private func evidenceSynthesisPanel(for document: AnalysisDocument) -> some View {
        let candidates = document.synthesisCandidateEvidenceBlocks
        let syntheses = document.evidenceSynthesisBlocks
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            Label("Evidence synthesis", systemImage: "text.badge.checkmark")
                .font(.caption.weight(.semibold))
            Text("Records an analyst conclusion over selected frozen evidence. It is interpretation, not an automatic verdict; every conclusion must retain its caveats.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text("Record validation evidence or a paired comparison before writing a synthesis.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Synthesis title", text: $evidenceSynthesisTitle)
                    .font(.caption)
                TextField("Question", text: $evidenceSynthesisQuestion)
                    .font(.caption)
                TextField("Conclusion", text: $evidenceSynthesisConclusion)
                    .font(.caption)
                Picker("Assessment", selection: $evidenceSynthesisAssessment) {
                    ForEach(AnalysisDocument.EvidenceSynthesis.Assessment.allCases, id: \.self) { assessment in
                        Text(evidenceSynthesisAssessmentTitle(assessment)).tag(assessment)
                    }
                }
                .font(.caption)
                TextField("One caveat per line", text: $evidenceSynthesisCaveats, axis: .vertical)
                    .font(.caption)
                    .lineLimit(2...4)
                Text("Cite frozen evidence")
                    .font(.caption2.weight(.medium))
                ForEach(candidates) { block in
                    Toggle(synthesisEvidenceTitle(block), isOn: synthesisEvidenceSelectionBinding(for: block.id))
                        .font(.caption2)
                }
                Button("Record Synthesis") { recordEvidenceSynthesis() }
                    .font(.caption)
                    .disabled(
                        documentRecomputing || selectedSynthesisEvidenceBlockIDs.isEmpty
                            || evidenceSynthesisTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || evidenceSynthesisQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || evidenceSynthesisConclusion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || evidenceSynthesisCaveats.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
            ForEach(syntheses) { block in
                if case .synthesis(let synthesis) = block.payload {
                    evidenceSynthesisRow(synthesis, state: block.state)
                }
            }
        }
    }

    private func synthesisEvidenceSelectionBinding(for blockID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedSynthesisEvidenceBlockIDs.contains(blockID) },
            set: { isSelected in
                if isSelected {
                    selectedSynthesisEvidenceBlockIDs.insert(blockID)
                } else {
                    selectedSynthesisEvidenceBlockIDs.remove(blockID)
                }
            }
        )
    }

    private func evidenceSynthesisAssessmentTitle(
        _ assessment: AnalysisDocument.EvidenceSynthesis.Assessment
    ) -> String {
        switch assessment {
        case .supported: return "Supported by cited evidence"
        case .mixed: return "Mixed evidence"
        case .inconclusive: return "Inconclusive evidence"
        }
    }

    private func synthesisEvidenceTitle(_ block: AnalysisDocument.Block) -> String {
        switch block.payload {
        case .evidence:
            return "Validation: \(block.title)"
        case .advancedEvidence:
            return "Advanced validation: \(block.title)"
        case .comparison:
            return "Comparison: \(block.title)"
        default:
            return block.title
        }
    }

    @ViewBuilder
    private func evidenceSynthesisRow(
        _ synthesis: AnalysisDocument.EvidenceSynthesis, state: AnalysisDocument.BlockState
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(evidenceSynthesisAssessmentTitle(synthesis.assessment)) · \(synthesis.evidenceBlockIDs.count) cited blocks")
                .font(.caption2.weight(.medium))
                .foregroundStyle(state == .current ? Color.accentColor : .orange)
            Text(synthesis.question)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(synthesis.conclusion)
                .font(.caption2)
            Text("Caveats: \(synthesis.caveats.joined(separator: " · "))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
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
        case .validationPlan: "checklist.checked"
        case .model: "function"
        case .advancedModel: "function"
        case .run: "play.circle"
        case .evidence: "checklist"
        case .advancedEvidence: "checklist"
        case .comparison: "arrow.left.arrow.right.circle"
        case .synthesis: "text.badge.checkmark"
        case .experimentProtocol: "point.3.connected.trianglepath.dotted"
        case .experimentCheckpoint: "flag.checkered"
        case .figure: "chart.xyaxis.line"
        case .note: "note.text"
        }
    }

    private func documentBlockDetail(_ block: AnalysisDocument.Block) -> String {
        switch block.payload {
        case .transformation: return "Replayable transformation"
        case .validationPlan(let plan):
            let bootstrap = plan.bootstrap.map { "bootstrap \($0.replicateCount)" }
            let cohort = plan.comparisonCohort.map { "cohort \($0)" }
            return [plan.partitioning.rawValue, "\(plan.foldCount) folds", "seed \(plan.seed)", bootstrap, cohort]
                .compactMap { $0 }.joined(separator: " · ")
        case .model(let recipe):
            return "\(recipe.smoother) · \(recipe.predictor) → \(recipe.response) · \(scalePolicyDescription(recipe.effectiveScalePolicy))"
        case .advancedModel(let recipe):
            return "\(recipe.specification.strategy.rawValue) · \(recipe.predictorColumns.joined(separator: ", ")) → \(recipe.responseColumn) · \(scalePolicyDescription(recipe.effectiveScalePolicy))"
        case .run(let run):
            let retained = run.retainedObservationCount.map { "\($0) retained" }
            let solver = run.requestedSolverPreference.map { "requested \($0.rawValue)" }
            let lineage = run.transformationBlockIDs.isEmpty
                ? "raw source" : "\(run.transformationBlockIDs.count) transforms"
            let validationSeed = "validation seed \(run.validationSeed)"
            let bootstrapSeed = run.bootstrapSeed.map { "bootstrap seed \($0)" }
            let scale = run.scaleSelection.map {
                "\($0.selectedObservationCount)/\($0.eligibleObservationCount) selected"
            }
            let environment = run.executionEnvironment.map {
                "DataLens \($0.swiftDataLensVersion) · NumericCore \($0.swiftNumericCoreVersion) · Rust \($0.rustNumericCoreVersion)"
            } ?? "legacy environment"
            let failure = run.failureDescription
            return [run.status.rawValue, retained, lineage, scale, validationSeed, bootstrapSeed, solver, environment, failure]
                .compactMap { $0 }.joined(separator: " · ")
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
        case .comparison(let comparison):
            guard comparison.verdict == .comparable else {
                return "Not comparable · \(comparisonVerdictDescription(comparison.verdict))"
            }
            let difference = comparison.meanLossDifference.map { String(format: "Δ loss %.4g", $0) }
            return [comparison.responseFamily?.rawValue, difference,
                    "\(comparison.candidateWinCount)/\(comparison.pairedObservationCount) candidate wins"]
                .compactMap { $0 }.joined(separator: " · ")
        case .synthesis(let synthesis):
            return "\(evidenceSynthesisAssessmentTitle(synthesis.assessment)) · \(synthesis.evidenceBlockIDs.count) cited blocks · \(synthesis.conclusion)"
        case .experimentProtocol(let protocolValue):
            return "\(protocolValue.arms.count) arms · \(protocolValue.primaryEndpoint) · \(protocolValue.decisionRule)"
        case .experimentCheckpoint(let checkpoint):
            return "\(experimentCheckpointStatusTitle(checkpoint.status)) · \(checkpoint.armRuns.count) arms · next: \(checkpoint.nextStep)"
        case .figure(let figure): return figure.caption
        case .note(let text): return text
        }
    }

    private func scalePolicyDescription(_ policy: StatisticalScalePolicy) -> String {
        switch policy {
        case .fullData: return "full finite data"
        case .stratifiedLeadingPredictor(let maximum, let seed):
            return "≤\(maximum) stratified · seed \(seed)"
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
        let startedAt = Date()
        documentTask = Task {
            do {
                let result = try await scopedDocumentRecompute(
                    document: document, sourceURL: sourceURL, modelBlockID: modelID
                )
                guard !Task.isCancelled else { return }
                var updated = document
                _ = try updated.markCurrent(through: modelID)
                let runRecord = try AnalysisDocument.AnalysisRun.completed(
                    in: updated, modelBlockID: modelID,
                    retainedObservationCount: result.fit.sourceRows.count,
                    startedAt: startedAt, scaleSelection: result.fit.scaleSelection
                )
                let runBlock = try AnalysisDocument.Block(
                    title: "Recomputed analysis run", upstreamBlockIDs: [modelID], payload: .run(runRecord)
                )
                try updated.append(runBlock)
                let figure = try AnalysisDocument.FigureAnnotation(
                    kind: figureKind,
                    caption: "Recomputed \(figureKind.rawValue): \(result.fit.loaded.yName) by \(result.fit.loaded.xName)."
                )
                let figureBlock = try AnalysisDocument.Block(
                    title: "Recomputed figure", upstreamBlockIDs: [runBlock.id], payload: .figure(figure)
                )
                try updated.append(figureBlock)
                let evidence = try AnalysisDocumentExecutor.evidenceSnapshot(
                    document: updated, fit: result.fit, sourceURL: sourceURL,
                    workbenchOutputs: result.outputs
                )
                let evidenceBlock = try AnalysisDocument.Block(
                    title: "Recomputed validation evidence", upstreamBlockIDs: [runBlock.id],
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
                var failed = document
                if let record = try? AnalysisDocument.AnalysisRun.failed(
                    in: failed, modelBlockID: modelID, description: String(describing: error),
                    startedAt: startedAt
                ), let block = try? AnalysisDocument.Block(
                    title: "Failed analysis run", upstreamBlockIDs: [modelID], payload: .run(record)
                ) {
                    try? failed.append(block)
                    analysisDocument = failed
                }
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

    private func advancedRecipe(
        for built: BuiltChart, document: AnalysisDocument
    ) throws -> AnalysisDocument.AdvancedModelRecipe {
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
        let plan = selectedValidationPlan(in: document)
        guard plan?.supports(specification) ?? true else {
            throw AnalysisDocumentExecutionError.invalidModelRecipe
        }
        let scaleSeed: UInt64
        if advancedScale.needsSeed {
            guard let parsed = UInt64(advancedScaleSeed.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw AnalysisDocumentExecutionError.invalidModelRecipe
            }
            scaleSeed = parsed
        } else {
            scaleSeed = 0
        }
        let partitioning: ValidationPartitioning = strategy == .additiveBinomial
            || strategy == .multivariateBinomial ? .stratifiedBinary : .blocked
        let validation = plan?.validationConfiguration(for: specification)
            ?? ValidationConfiguration(
                foldCount: 5, partitioning: partitioning, specification: specification
            )
        let query: [[Double]]
        let bootstrap: BootstrapConfiguration?
        let wantsBootstrap = plan?.bootstrap != nil || advancedBootstrap
        if wantsBootstrap && advancedStrategy.requiresSecondPredictor {
            throw AnalysisDocumentExecutionError.invalidModelRecipe
        }
        if wantsBootstrap {
            guard
                  let median = built.loaded.model.rawX.sorted().dropFirst(
                      max(0, built.loaded.model.rawX.count - 1) / 2
                  ).first else {
                throw AnalysisDocumentExecutionError.invalidModelRecipe
            }
            query = [[median]]
            bootstrap = plan?.bootstrapConfiguration(for: specification)
                ?? BootstrapConfiguration(
                    replicateCount: 50, minimumSuccessFraction: 0.8, specification: specification
                )
        } else {
            query = []
            bootstrap = nil
        }
        return try AnalysisDocument.AdvancedModelRecipe(
            predictorColumns: predictors, responseColumn: built.controller.yName,
            specification: specification, validationConfiguration: validation,
            scalePolicy: advancedScale.policy(seed: scaleSeed),
            bootstrapConfiguration: bootstrap, stabilityQueries: query,
            validationPlanBlockID: plan == nil ? nil : selectedValidationPlanBlockID
        )
    }

    private func fitAndRecordAdvancedModel(from built: BuiltChart) {
        guard let document = analysisDocument, let sourceURL = documentSourceURL else { return }
        advancedTask?.cancel()
        documentError = nil
        advancedLoading = true
        do {
            let recipe = try advancedRecipe(for: built, document: document)
            var upstream = document.latestModelBlockID.map { [$0] } ?? []
            if let validationPlanBlockID = recipe.validationPlanBlockID {
                upstream.append(validationPlanBlockID)
            }
            let modelBlock = try AnalysisDocument.Block(
                title: advancedStrategy.rawValue, upstreamBlockIDs: upstream,
                payload: .advancedModel(recipe)
            )
            var prepared = document
            try prepared.append(modelBlock)
            let startedAt = Date()
            advancedTask = Task {
                do {
                    let run = try await Task.detached(priority: .userInitiated) {
                        try scopedAdvancedDocumentRun(
                            document: prepared, sourceURL: sourceURL, modelBlockID: modelBlock.id
                        )
                    }.value
                    guard !Task.isCancelled else { return }
                    var updated = prepared
                    let runRecord = try AnalysisDocument.AnalysisRun.completed(
                        in: updated, modelBlockID: modelBlock.id,
                        retainedObservationCount: run.fit.sourceRows.count,
                        startedAt: startedAt, scaleSelection: run.fit.scaleSelection
                    )
                    let runBlock = try AnalysisDocument.Block(
                        title: "Advanced analysis run", upstreamBlockIDs: [modelBlock.id], payload: .run(runRecord)
                    )
                    try updated.append(runBlock)
                    let figureKind: AnalysisDocument.FigureAnnotation.Kind = advancedStrategy.requiresSecondPredictor
                        ? .surface : .fittedCurve
                    let figure = try AnalysisDocument.FigureAnnotation(
                        kind: figureKind,
                        caption: "\(advancedStrategy.rawValue) fit: \(recipe.responseColumn) by \(recipe.predictorColumns.joined(separator: ", "))."
                    )
                    try updated.append(AnalysisDocument.Block(
                        title: "Advanced model figure", upstreamBlockIDs: [runBlock.id], payload: .figure(figure)
                    ))
                    try updated.append(AnalysisDocument.Block(
                        title: "Advanced validation evidence", upstreamBlockIDs: [runBlock.id],
                        payload: .advancedEvidence(run.evidence)
                    ))
                    analysisDocument = updated
                    advancedLoading = false
                } catch is CancellationError {
                    guard !Task.isCancelled else { return }
                    advancedLoading = false
                } catch {
                    guard !Task.isCancelled else { return }
                    var failed = prepared
                    if let record = try? AnalysisDocument.AnalysisRun.failed(
                        in: failed, modelBlockID: modelBlock.id, description: String(describing: error),
                        startedAt: startedAt
                    ), let block = try? AnalysisDocument.Block(
                        title: "Failed advanced run", upstreamBlockIDs: [modelBlock.id], payload: .run(record)
                    ) {
                        try? failed.append(block)
                        analysisDocument = failed
                    }
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
