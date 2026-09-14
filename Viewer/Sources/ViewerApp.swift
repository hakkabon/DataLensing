//
//  ViewerApp.swift
//  DataLensingViewer
//
//  macOS host for SmootherChartView: pick a CSV file, fit it off the
//  main thread, draw raw points + fitted curve + SE band.
//

import SwiftUI

@main
struct ViewerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
