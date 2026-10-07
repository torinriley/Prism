// MetalContext.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Foundation
import Metal

/// Owns the device, command queue, and shader libraries.
///
/// All members are immutable after `init`, and the Metal objects held here
/// (`MTLDevice`, `MTLCommandQueue`, `MTLLibrary`) are thread-safe by Apple's contract,
/// so the context is shared freely without an actor. Mutable shared state (pipeline
/// cache, texture pool) lives in its own synchronized types, not here.
final class MetalContext: Sendable {
    /// Where the shader code comes from.
    enum ShaderLoading: Sendable {
        /// The precompiled `default.metallib` in the package bundle if it exists; otherwise compile the
        /// bundle's `.metal` sources at runtime.
        ///
        /// Xcode's build system (and Swift 6.4's SwiftPM) compile `.metal` resources into the metallib. An
        /// older SwiftPM build system only *copies* them, so `swift build` there produces a package with no
        /// compiled shaders. The fallback keeps `swift build`, `swift test` and `swift run` working on
        /// those toolchains, at the price of compiling the shaders when the first `Renderer` is created.
        case automatic
        /// Always compile from source, reading `.metal` and `.h` files from `directory`, or from the
        /// bundle when `nil`. Used to test the fallback.
        case runtimeSource(directory: URL?)
    }

    let device: any MTLDevice
    let queue: any MTLCommandQueue
    /// One library per `.metal` file when compiled at runtime, or the single precompiled library.
    private let libraries: [any MTLLibrary]
    /// Whether the shaders were compiled at runtime rather than loaded precompiled.
    let compiledFromSource: Bool

    init(device: (any MTLDevice)? = nil, shaders: ShaderLoading = .automatic) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw PrismError.metalUnavailable
        }
        guard let queue = device.makeCommandQueue() else {
            throw PrismError.metalUnavailable
        }
        self.device = device
        self.queue = queue
        switch shaders {
        case .automatic:
            if let precompiled = try? device.makeDefaultLibrary(bundle: Bundle.module) {
                libraries = [precompiled]
                compiledFromSource = false
            } else {
                libraries = try Self.compileSources(device: device, directory: nil)
                compiledFromSource = true
            }
        case .runtimeSource(let directory):
            libraries = try Self.compileSources(device: device, directory: directory)
            compiledFromSource = true
        }
    }

    /// Names of every kernel available.
    var functionNames: [String] { libraries.flatMap(\.functionNames).sorted() }

    // MARK: Runtime compilation

    /// Compiles each `.metal` file as its own library (so identically named helper types in different files
    /// cannot collide), with `#include "…"` directives of the bundled headers expanded in place.
    private static func compileSources(device: any MTLDevice, directory: URL?) throws -> [any MTLLibrary] {
        let fileManager = FileManager.default
        let urls: [URL]
        if let directory {
            urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        } else {
            urls = (Bundle.module.urls(forResourcesWithExtension: "metal", subdirectory: nil) ?? [])
                + (Bundle.module.urls(forResourcesWithExtension: "h", subdirectory: nil) ?? [])
        }
        let sources = urls.filter { $0.pathExtension == "metal" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !sources.isEmpty else {
            throw PrismError.shaderLibraryUnavailable(
                reason: "the package bundle has no precompiled shader library and no shader sources to compile")
        }
        var headers: [String: String] = [:]
        for url in urls where url.pathExtension == "h" {
            headers[url.lastPathComponent] = try? String(contentsOf: url, encoding: .utf8)
        }

        var result: [any MTLLibrary] = []
        for url in sources {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw PrismError.shaderLibraryUnavailable(reason: "could not read \(url.lastPathComponent)")
            }
            var included = Set<String>()
            let expanded = try expandIncludes(text, headers: headers, included: &included, file: url.lastPathComponent)
            do {
                result.append(try device.makeLibrary(source: expanded, options: nil))
            } catch {
                throw PrismError.shaderLibraryUnavailable(
                    reason: "compiling \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return result
    }

    /// Replaces `#include "Name.h"` with the header's text (once per file, like `#pragma once`) and drops
    /// `#pragma once`. System includes (`<…>`) are left for the compiler.
    static func expandIncludes(
        _ text: String, headers: [String: String], included: inout Set<String>, file: String
    ) throws -> String {
        var output: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "#pragma once" { continue }
            if trimmed.hasPrefix("#include \"") {
                let name = String(trimmed.dropFirst(10).prefix { $0 != "\"" })
                guard let header = headers[name] else {
                    throw PrismError.shaderLibraryUnavailable(reason: "\(file) includes missing header \(name)")
                }
                if included.insert(name).inserted {
                    output.append(Substring(try expandIncludes(header, headers: headers, included: &included, file: name)))
                }
                continue
            }
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    /// Creates (without caching) a compute pipeline for the named kernel.
    func makePipeline(kernel name: String) throws -> any MTLComputePipelineState {
        guard let function = libraries.lazy.compactMap({ $0.makeFunction(name: name) }).first else {
            throw PrismError.shaderFunctionNotFound(name: name)
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw PrismError.pipelineCreationFailed(kernel: name, reason: error.localizedDescription)
        }
    }

    /// Storage mode for textures the CPU uploads to or reads from.
    ///
    /// Unified-memory GPUs (all Apple silicon and every iOS device) use `.shared`. Discrete GPUs on Intel
    /// Macs need `.managed`, a storage mode that does not exist on iOS.
    var cpuVisibleStorage: MTLStorageMode {
        #if os(macOS)
        device.hasUnifiedMemory ? .shared : .managed
        #else
        .shared
        #endif
    }

    func makeTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat = .rgba8Unorm) throws -> any MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = cpuVisibleStorage
        guard width > 0, height > 0, let texture = device.makeTexture(descriptor: desc) else {
            throw PrismError.textureAllocationFailed(width: width, height: height)
        }
        return texture
    }

    func makeLUTTexture(_ lut: LUT3D) throws -> any MTLTexture {
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba32Float   // exact lattice values; read() needs no filtering support
        desc.width = lut.size; desc.height = lut.size; desc.depth = lut.size
        desc.usage = .shaderRead
        desc.storageMode = cpuVisibleStorage
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw PrismError.textureAllocationFailed(width: lut.size, height: lut.size)
        }
        var rgba = [Float](); rgba.reserveCapacity(lut.size * lut.size * lut.size * 4)
        for i in stride(from: 0, to: lut.rgb.count, by: 3) { rgba += [lut.rgb[i], lut.rgb[i + 1], lut.rgb[i + 2], 1] }
        rgba.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake3D(0, 0, 0, lut.size, lut.size, lut.size), mipmapLevel: 0, slice: 0,
                withBytes: $0.baseAddress!, bytesPerRow: lut.size * 16, bytesPerImage: lut.size * lut.size * 16)
        }
        return texture
    }
}
