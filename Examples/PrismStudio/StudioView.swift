// StudioView.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import AppKit
import Prism
import SwiftUI

struct StudioView: View {
    @ObservedObject var model: StudioModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.12))
            HStack(spacing: 0) {
                imagePane
                Divider().overlay(Color.white.opacity(0.12))
                controls
                    .frame(width: 350)
            }
        }
        .background(Color(nsColor: NSColor(calibratedWhite: 0.065, alpha: 1)))
        .preferredColorScheme(.dark)
        .alert("Prism", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("PRISM")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .tracking(5)
            Text("STUDIO")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .tracking(2)
            Spacer()
            if model.isRendering { ProgressView().controlSize(.small) }
            Text(model.dimensionText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button("Open…") { model.openImage() }
            Button("Export…") { model.exportImage() }
                .disabled(model.processedImage == nil)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private var imagePane: some View {
        ZStack {
            checkerboard
            if let image = model.displayedImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(30)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 42, weight: .thin))
                    Text("DROP AN IMAGE")
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .tracking(2)
                    Button("Choose Image…") { model.openImage() }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.secondary)
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(12)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if model.sourceImage != nil {
                Button(model.showingOriginal ? "Showing Original" : "Showing Processed") {
                    model.showingOriginal.toggle()
                }
                .buttonStyle(.bordered)
                .padding(20)
                .onHover { hovering in
                    if hovering { model.showingOriginal = true }
                    else { model.showingOriginal = false }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: model.acceptDrop)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var checkerboard: some View {
        Canvas { context, size in
            let tile: CGFloat = 14
            for y in stride(from: 0, to: size.height, by: tile) {
                for x in stride(from: 0, to: size.width, by: tile) {
                    let even = (Int(x / tile) + Int(y / tile)).isMultiple(of: 2)
                    context.fill(Path(CGRect(x: x, y: y, width: tile, height: tile)),
                                 with: .color(.white.opacity(even ? 0.045 : 0.025)))
                }
            }
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.sourceName).font(.headline).lineLimit(1)
                        Text(model.highPrecision ? "RGBA16 FLOAT" : "RGBA8 UNORM")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reset") { model.resetParameters() }.buttonStyle(.plain).foregroundStyle(.secondary)
                }

                parameter("EXPOSURE", value: $model.exposure, range: -3...3, format: "%+.2f EV")
                parameter("CONTRAST", value: $model.contrast, range: 0...2, format: "%.2f")
                parameter("SATURATION", value: $model.saturation, range: 0...2, format: "%.2f")
                parameter("TEMPERATURE", value: $model.temperature, range: -1...1, format: "%+.2f")
                parameter("BLUR", value: $model.blur, range: 0...20, format: "%.1f px")
                parameter("SHARPEN", value: $model.sharpen, range: 0...2, format: "%.2f")
                parameter("VIGNETTE", value: $model.vignette, range: 0...1, format: "%.2f")

                Toggle("16-bit float intermediates", isOn: $model.highPrecision)
                    .font(.caption)

                Divider()
                InspectorView(metrics: model.metrics)
            }
            .padding(22)
        }
    }

    private func parameter(
        _ name: String, value: Binding<Double>, range: ClosedRange<Double>, format: String
    ) -> some View {
        VStack(spacing: 7) {
            HStack {
                Text(name).font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1.4)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

private struct InspectorView: View {
    let metrics: RenderMetrics?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GPU INSPECTOR")
                .font(.system(size: 10, weight: .semibold, design: .rounded)).tracking(1.4)
            Text("Per-pass timing mode: each pass is encoded separately, so totals differ slightly from the default encoding.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            if let metrics {
                metricRow("FRAME", milliseconds(metrics.totalDuration))
                metricRow("GPU", milliseconds(metrics.gpuDuration))
                metricRow("ENCODE", milliseconds(metrics.cpuEncodeDuration))
                metricRow("TEXTURES", "\(metrics.peakActiveTextures) active · \(metrics.textureReuses) reused")
                metricRow("CACHE", "\(metrics.pipelineCacheHits) hit · \(metrics.pipelineCacheMisses) compiled")

                Text("GRAPH").inspectorLabel()
                ForEach(Array(metrics.nodes.enumerated()), id: \.offset) { _, node in
                    HStack(spacing: 8) {
                        Circle().fill(Color.accentColor.opacity(0.8)).frame(width: 4, height: 4)
                        Text(node.name).lineLimit(1)
                        Spacer()
                        Text(milliseconds(node.gpuDuration)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
                if metrics.nodes.isEmpty {
                    Text("All passes eliminated")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                }
            } else {
                Text("Load an image to inspect GPU work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).inspectorLabel()
            Spacer()
            Text(value).font(.system(size: 11, design: .monospaced))
        }
    }

    private func milliseconds(_ value: TimeInterval?) -> String {
        value.map { String(format: "%.2f ms", $0 * 1_000) } ?? "—"
    }
}

private extension View {
    func inspectorLabel() -> some View {
        font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(.secondary)
    }
}
