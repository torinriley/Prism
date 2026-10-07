// StudioModel.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import AppKit
import CoreGraphics
import ImageIO
import Prism
import UniformTypeIdentifiers

@MainActor
final class StudioModel: ObservableObject {
    @Published var sourceImage: CGImage?
    @Published var processedImage: CGImage?
    @Published var metrics: RenderMetrics?
    @Published var sourceName = "No image"
    @Published var errorMessage: String?
    @Published var isRendering = false
    @Published var showingOriginal = false

    @Published var exposure: Double = 0.25 { didSet { scheduleRender() } }
    @Published var contrast: Double = 1.10 { didSet { scheduleRender() } }
    @Published var saturation: Double = 1.0 { didSet { scheduleRender() } }
    @Published var temperature: Double = 0.0 { didSet { scheduleRender() } }
    @Published var blur: Double = 0.0 { didSet { scheduleRender() } }
    @Published var sharpen: Double = 0.25 { didSet { scheduleRender() } }
    @Published var vignette: Double = 0.2 { didSet { scheduleRender() } }
    @Published var highPrecision = false { didSet { scheduleRender() } }

    private var renderer: Renderer?
    private var renderTask: Task<Void, Never>?
    private var generation = 0

    init() {
        do {
            renderer = try Renderer(instrumentation: .detailed)
        } catch {
            errorMessage = error.localizedDescription
        }
        if let path = ImageExport.imagePath(in: CommandLine.arguments) {
            load(URL(fileURLWithPath: path))
        }
    }

    deinit { renderTask?.cancel() }

    var displayedImage: CGImage? {
        showingOriginal ? sourceImage : (processedImage ?? sourceImage)
    }

    var dimensionText: String {
        guard let image = sourceImage else { return "—" }
        return "\(image.width) × \(image.height)"
    }

    func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            errorMessage = "Could not decode \(url.lastPathComponent)."
            return
        }
        sourceImage = image
        processedImage = nil
        metrics = nil
        sourceName = url.lastPathComponent
        errorMessage = nil
        scheduleRender(immediately: true)
    }

    func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { [weak self] item, _ in
            let url: URL?
            if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else { url = item as? URL }
            guard let url else { return }
            Task { @MainActor [weak self] in self?.load(url) }
        }
        return true
    }

    func resetParameters() {
        exposure = 0
        contrast = 1
        saturation = 1
        temperature = 0
        blur = 0
        sharpen = 0
        vignette = 0
        scheduleRender(immediately: true)
    }

    func scheduleRender(immediately: Bool = false) {
        guard sourceImage != nil else { return }
        generation += 1
        let requestedGeneration = generation
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            if !immediately {
                try? await Task.sleep(for: .milliseconds(45))
            }
            guard !Task.isCancelled else { return }
            await self?.render(generation: requestedGeneration)
        }
    }

    private func render(generation requestedGeneration: Int) async {
        guard let sourceImage, let renderer else { return }
        isRendering = true
        defer { if requestedGeneration == generation { isRendering = false } }

        let pipeline = ImagePipeline {
            Exposure(Float(exposure))
            Contrast(Float(contrast))
            Saturation(Float(saturation))
            Temperature(Float(temperature))
            GaussianBlur(radius: Float(blur))
            Sharpen(amount: Float(sharpen))
            Vignette(amount: Float(vignette))
        }
        do {
            let result = try await pipeline.renderWithMetrics(
                sourceImage,
                precision: highPrecision ? .high : .standard,
                using: renderer
            )
            guard requestedGeneration == generation, !Task.isCancelled else { return }
            processedImage = result.image
            metrics = result.metrics
            errorMessage = nil
        } catch is CancellationError {
            // A newer parameter value superseded this render before submission.
        } catch {
            guard requestedGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func exportImage() {
        guard let image = processedImage else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent + "-prism.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !ImageExport.writePNG(image, to: url) {
            errorMessage = "Could not export the image."
        }
    }
}
