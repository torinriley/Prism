import CoreGraphics
import Foundation
import Metal
import Testing
@testable import Prism

private let shaderDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/Prism/Shaders")

@Suite("Shader loading: include expansion")
struct IncludeExpansionTests {
    private func expand(_ text: String, _ headers: [String: String]) throws -> String {
        var included = Set<String>()
        return try MetalContext.expandIncludes(text, headers: headers, included: &included, file: "test.metal")
    }

    @Test("A bundled header is inlined, `#pragma once` is dropped, and system includes are left alone")
    func inlines() throws {
        let out = try expand("#include <metal_stdlib>\n#include \"A.h\"\nkernel void k() {}", ["A.h": "#pragma once\nint a;"])
        #expect(out == "#include <metal_stdlib>\nint a;\nkernel void k() {}")
    }

    @Test("A header included twice, directly or through another header, appears once")
    func onlyOnce() throws {
        let headers = ["A.h": "#include \"B.h\"\nint a;", "B.h": "int b;"]
        let out = try expand("#include \"A.h\"\n#include \"B.h\"\n#include \"A.h\"\nend", headers)
        #expect(out.components(separatedBy: "int b;").count == 2 && out.components(separatedBy: "int a;").count == 2)
        #expect(out.hasSuffix("end"))
    }

    @Test("A missing header is reported with the file that asked for it")
    func missing() {
        #expect(throws: PrismError.shaderLibraryUnavailable(reason: "test.metal includes missing header Nope.h")) {
            _ = try expand("#include \"Nope.h\"", [:])
        }
    }
}

@Suite("Shader loading: runtime compilation", .enabled(if: hasMetal))
struct RuntimeCompilationTests {
    @Test("Compiling the sources yields exactly the kernels the precompiled library has")
    func sameKernels() throws {
        let precompiled = try MetalContext()
        let fromSource = try MetalContext(shaders: .runtimeSource(directory: shaderDirectory))
        #expect(fromSource.compiledFromSource)
        #expect(fromSource.functionNames == precompiled.functionNames)
        #expect(fromSource.functionNames.contains("prism_blur_horizontal_tiled") && fromSource.functionNames.contains("prism_pointwise_chain"))
        for name in fromSource.functionNames { _ = try fromSource.makePipeline(kernel: name) }
    }

    @Test("A renderer built on runtime-compiled shaders produces the same pixels as the precompiled one")
    func sameResults() async throws {
        let (w, h) = (97, 61)
        let image = makeImage(width: w, height: h, bytes: testPixels(width: w, height: h))
        let lut = try LUT3D.identity(size: 9)
        let pipelines: [ImagePipeline] = [
            ImagePipeline { Exposure(0.4); Contrast(1.2); Saturation(1.3); Temperature(0.3); Vignette(amount: 0.5) },  // fused chain
            ImagePipeline { GaussianBlur(radius: 2); GaussianBlur(radius: 12) },                                      // tiled blur
            ImagePipeline { Sharpen(amount: 0.8, radius: 2); Resize(scale: 0.6); LUTGrade(lut, intensity: 0.7) },
        ]
        let reference = try Renderer()
        let fallback = Renderer(context: try MetalContext(shaders: .runtimeSource(directory: shaderDirectory)))
        for (index, pipeline) in pipelines.enumerated() {
            for precision in [Precision.standard, .high] {
                let a = try await pipeline.render(image, precision: precision, using: reference)
                let b = try await pipeline.render(image, precision: precision, using: fallback)
                let ab = precision == .standard ? try pixels(of: a) : Array(try floatPixels(of: a).map { $0.bitPattern.littleEndianBytes }.joined())
                let bb = precision == .standard ? try pixels(of: b) : Array(try floatPixels(of: b).map { $0.bitPattern.littleEndianBytes }.joined())
                #expect(ab == bb, "pipeline \(index) at \(precision)")
            }
        }
    }

    @Test("No sources at all is a clear error")
    func noSources() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("prism-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: PrismError.self) { _ = try MetalContext(shaders: .runtimeSource(directory: empty)) }
    }

    @Test("A shader that fails to compile names its file")
    func compileError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prism-bad-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "#include <metal_stdlib>\nkernel void broken( { }".write(to: dir.appendingPathComponent("Broken.metal"), atomically: true, encoding: .utf8)
        do {
            _ = try MetalContext(shaders: .runtimeSource(directory: dir))
            Issue.record("expected a compile error")
        } catch let error as PrismError {
            guard case .shaderLibraryUnavailable(let reason) = error else { Issue.record("wrong error \(error)"); return }
            #expect(reason.contains("Broken.metal"), Comment(rawValue: reason))
        }
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] { (0..<4).map { UInt8((self >> (8 * UInt32($0))) & 0xFF) } }
}
