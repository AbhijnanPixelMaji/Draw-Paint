import Metal
import MetalKit

/// Shared Metal device, queue, library, and pipeline/sampler state. Created once and passed around.
/// `@MainActor` for Phase 1 — all rendering happens on the main thread via `MTKView.draw`.
final class MetalContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary

    let stampPipeline: MTLRenderPipelineState       // premultiplied source-over (buildup strokes)
    let stampMaxPipeline: MTLRenderPipelineState    // max-blend (flat strokes: no self-darkening)
    let blitPipeline: MTLRenderPipelineState
    let blendPipeline: MTLRenderPipelineState       // layer blend pass (opaque write, no HW blending)
    let blurPipeline: MTLRenderPipelineState        // separable diffusion blur (overwrite, no blending)
    let wetPipeline: MTLRenderPipelineState         // wet buffer composite w/ edge darkening (source-over)
    let smudgePipeline: MTLRenderPipelineState      // pickup restamp (source-over into layer)
    let erasePipeline: MTLRenderPipelineState       // destination-out stamps (eraser)
    let sampler: MTLSamplerState                    // clamp (masks, layer composite)
    let repeatSampler: MTLSamplerState              // repeat (canvas-anchored grain)

    static let layerPixelFormat: MTLPixelFormat = .rgba8Unorm

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw EngineError.noMetalDevice
        }
        guard let queue = device.makeCommandQueue() else {
            throw EngineError.commandQueueFailed
        }
        // The synchronized target compiles Shaders.metal into the default library.
        let library = try device.makeDefaultLibrary(bundle: .main)

        self.device = device
        self.queue = queue
        self.library = library

        func makePipeline(vertex: String, fragment: String, maxBlend: Bool = false,
                          hardwareBlending: Bool = true) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            guard let att = desc.colorAttachments[0] else { throw EngineError.pipelineFailed }
            att.pixelFormat = MetalContext.layerPixelFormat
            att.isBlendingEnabled = hardwareBlending
            if maxBlend {
                // Flat strokes: overlap within a stroke keeps the max coverage instead of accumulating.
                att.rgbBlendOperation = .max
                att.alphaBlendOperation = .max
                att.sourceRGBBlendFactor = .one
                att.sourceAlphaBlendFactor = .one
                att.destinationRGBBlendFactor = .one
                att.destinationAlphaBlendFactor = .one
            } else {
                // Premultiplied source-over.
                att.rgbBlendOperation = .add
                att.alphaBlendOperation = .add
                att.sourceRGBBlendFactor = .one
                att.sourceAlphaBlendFactor = .one
                att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        self.stampPipeline = try makePipeline(vertex: "stamp_vertex", fragment: "stamp_fragment")
        self.stampMaxPipeline = try makePipeline(vertex: "stamp_vertex", fragment: "stamp_fragment", maxBlend: true)
        self.blitPipeline = try makePipeline(vertex: "blit_vertex", fragment: "blit_fragment")
        // The blend pass computes its result entirely in the fragment shader and writes opaque pixels.
        self.blendPipeline = try makePipeline(vertex: "blit_vertex", fragment: "blend_fragment",
                                              hardwareBlending: false)
        self.blurPipeline = try makePipeline(vertex: "blit_vertex", fragment: "blur_fragment",
                                             hardwareBlending: false)
        self.wetPipeline = try makePipeline(vertex: "blit_vertex", fragment: "wet_fragment")
        self.smudgePipeline = try makePipeline(vertex: "stamp_vertex", fragment: "smudge_fragment")

        // Eraser: destination-out — dst *= (1 - srcAlpha).
        let eraseDesc = MTLRenderPipelineDescriptor()
        eraseDesc.vertexFunction = library.makeFunction(name: "stamp_vertex")
        eraseDesc.fragmentFunction = library.makeFunction(name: "stamp_fragment")
        guard let ea = eraseDesc.colorAttachments[0] else { throw EngineError.pipelineFailed }
        ea.pixelFormat = MetalContext.layerPixelFormat
        ea.isBlendingEnabled = true
        ea.rgbBlendOperation = .add
        ea.alphaBlendOperation = .add
        ea.sourceRGBBlendFactor = .zero
        ea.sourceAlphaBlendFactor = .zero
        ea.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ea.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.erasePipeline = try device.makeRenderPipelineState(descriptor: eraseDesc)

        func makeSampler(address: MTLSamplerAddressMode) throws -> MTLSamplerState {
            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear
            sd.magFilter = .linear
            sd.sAddressMode = address
            sd.tAddressMode = address
            guard let s = device.makeSamplerState(descriptor: sd) else { throw EngineError.samplerFailed }
            return s
        }
        self.sampler = try makeSampler(address: .clampToEdge)
        self.repeatSampler = try makeSampler(address: .repeat)
    }

    /// Allocates a fresh premultiplied RGBA8 texture in shared storage (CPU-readable for undo/PNG).
    func makeLayerTexture(width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalContext.layerPixelFormat,
            width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { throw EngineError.textureFailed }
        return tex
    }
}

enum EngineError: Error {
    case noMetalDevice, commandQueueFailed, pipelineFailed, samplerFailed, textureFailed
}
