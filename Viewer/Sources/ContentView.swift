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

/// What the viewer has finished building on a background task.
private struct BuiltChart: Sendable {
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
                SmootherChartView(model: built.loaded.model)
                    .frame(minHeight: 320)
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

    private func open(_ url: URL) {
        work?.cancel()
        let name = url.lastPathComponent
        phase = .fitting(name)
        work = Task {
            do {
                let built = try await withThrowingTaskGroup(of: BuiltChart.self) { group in
                    group.addTask { try scopedLoad(from: url) }
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
}

/// Load + fit off the main actor with security-scoped file access.
/// Free function (not a method) so the task closure captures no `self`.
private func scopedLoad(from url: URL) throws -> BuiltChart {
    let didAccess = url.startAccessingSecurityScopedResource()
    defer {
        if didAccess { url.stopAccessingSecurityScopedResource() }
    }
    let loaded = try loadChart(from: url)
    try Task.checkCancellation()
    return BuiltChart(loaded: loaded, fileName: url.lastPathComponent)
}
