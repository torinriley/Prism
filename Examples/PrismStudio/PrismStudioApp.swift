// PrismStudioApp.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import SwiftUI

@main
struct PrismStudioApp: App {
    @StateObject private var model = StudioModel()

    var body: some Scene {
        WindowGroup("Prism Studio") {
            StudioView(model: model)
                .frame(minWidth: 1_080, minHeight: 680)
        }
        .defaultSize(width: 1_280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Image…") { model.openImage() }
                    .keyboardShortcut("o")
                Button("Export Processed Image…") { model.exportImage() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.processedImage == nil)
            }
        }
    }
}
