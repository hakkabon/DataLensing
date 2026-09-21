//
//  ViewerApp.swift
//  DataLensingViewer
//
//  macOS host for SmootherChartView: pick a CSV file, fit it off the
//  main thread, draw raw points + fitted curve + SE band.
//

import SwiftUI

struct ViewerCommandActions {
    let open: () -> Void
    let clear: () -> Void
    let export: () -> Void
    let exportReport: () -> Void
    let exportSession: () -> Void
    let newDocument: () -> Void
    let openDocument: () -> Void
    let saveDocument: () -> Void
    let canClear: Bool
    let canExport: Bool
    let canSaveDocument: Bool
}

private struct ViewerCommandActionsKey: FocusedValueKey {
    typealias Value = ViewerCommandActions
}

extension FocusedValues {
    var viewerCommandActions: ViewerCommandActions? {
        get { self[ViewerCommandActionsKey.self] }
        set { self[ViewerCommandActionsKey.self] = newValue }
    }
}

private struct ViewerCommands: Commands {
    @FocusedValue(\.viewerCommandActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open CSV…") { actions?.open() }
                .keyboardShortcut("o", modifiers: .command)

            Button("Clear Chart") { actions?.clear() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(actions?.canClear != true)

            Divider()

            Button("Export Fitted Grid…") { actions?.export() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(actions?.canExport != true)

            Button("Copy Analysis Report") { actions?.exportReport() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions?.canExport != true)

            Button("Copy Workbench Session") { actions?.exportSession() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(actions?.canExport != true)

            Divider()

            Button("Create Analysis Document") { actions?.newDocument() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions?.canExport != true)

            Button("Open Analysis Document…") { actions?.openDocument() }
                .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Save Analysis Document…") { actions?.saveDocument() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(actions?.canSaveDocument != true)
        }
    }
}

@main
struct ViewerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            ViewerCommands()
        }
    }
}
