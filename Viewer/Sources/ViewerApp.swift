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
    let canClear: Bool
    let canExport: Bool
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
