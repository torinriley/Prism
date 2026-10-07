// MetalContext.swift — Prism
// Author: Torin Etheridge
// Date: October 6, 2026

import Foundation
import Metal

/// Owns the device, command queue, and shader library.
///
/// All members are immutable after `init`, and the Metal objects held here
/// (`MTLDevice`, `MTLCommandQueue`, `MTLLibrary`) are thread-safe by Apple's contract,
/// so the context is shared freely without an actor. Mutable shared state (pipeline
/// cache, texture pool) lives in its own synchronized types, not here.
final class MetalContext: Sendable {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let library: any MTLLibrary

    init(device: (any MTLDevice)? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw PrismError.metalUnavailable
        }
        guard let queue = device.makeCommandQueue() else {
            throw PrismError.metalUnavailable
        }
        self.device = device
        self.queue = queue
        do {
            self.library = try device.makeDefaultLibrary(bundle: Bundle.module)
        } catch {
            throw PrismError.shaderLibraryUnavailable(reason: error.localizedDescription)
        }
    }

    /// Creates (without caching) a compute pipeline for the named kernel.
    func makePipeline(kernel name: String) throws -> any MTLComputePipelineState {
        guard let function = library.makeFunction(name: name) else {
            throw PrismError.shaderFunctionNotFound(name: name)
        }
        do {
            return try device.makeComputePipelineState(function: function)
        } catch {
            throw PrismError.pipelineCreationFailed(kernel: name, reason: error.localizedDescription)
        }
    }

    /// Storage mode for textures the CPU uploads to or reads from.
    var cpuVisibleStorage: MTLStorageMode {
        device.hasUnifiedMemory ? .shared : .managed
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
