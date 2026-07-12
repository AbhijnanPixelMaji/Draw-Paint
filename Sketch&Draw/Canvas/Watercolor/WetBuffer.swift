import Metal
import CoreGraphics
import simd

/// The watercolor wet buffer: watercolor stamps accumulate here (overlap darkens → blooms).
/// While wet, a separable-blur diffusion pass spreads pigment; the composite draws it through the
/// edge-darkening `wet_fragment`. `dry(into:)` bakes it (edges included) into a layer and clears.
@MainActor
final class WetBuffer {
    private let ctx: MetalContext
    let canvasSize: CGSize
    private(set) var texture: MTLTexture
    private var scratch: MTLTexture          // ping-pong partner for the blur
    /// Union of everything painted since the last dry (drives the undo snapshot on dry).
    private(set) var bounds = CGRect.null
    /// Remaining wetness 0…1; diffusion stops at 0.
    private(set) var wetness: CGFloat = 0

    var hasContent: Bool { !bounds.isNull }
    var edgeGain: Float = 0.4

    init(context: MetalContext, canvasSize: CGSize) throws {
        self.ctx = context
        self.canvasSize = canvasSize
        self.texture = try context.makeLayerTexture(width: Int(canvasSize.width),
                                                    height: Int(canvasSize.height))
        self.scratch = try context.makeLayerTexture(width: Int(canvasSize.width),
                                                    height: Int(canvasSize.height))
        clear()
    }

    func noteStamped(rect: CGRect) {
        bounds = bounds.union(rect)
        wetness = 1
    }

    /// One diffusion step: horizontal + vertical gaussian ping-pong over the wet region.
    /// Returns false once fully dry (caller stops its timer).
    func diffuse() -> Bool {
        guard hasContent, wetness > 0.02 else { wetness = 0; return false }
        guard let cmd = ctx.queue.makeCommandBuffer() else { return false }
        // Diffusion radius shrinks as the wash dries.
        let radius = Float(0.6 + 1.2 * wetness)
        let texel = SIMD2<Float>(radius / Float(canvasSize.width), radius / Float(canvasSize.height))

        func pass(from src: MTLTexture, to dst: MTLTexture, dir: SIMD2<Float>) {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dst
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(ctx.blurPipeline)
            let w = Float(canvasSize.width), h = Float(canvasSize.height)
            var quad = [
                BlitVertex(pos: SIMD2(0, 0), uv: SIMD2(0, 0)),
                BlitVertex(pos: SIMD2(w, 0), uv: SIMD2(1, 0)),
                BlitVertex(pos: SIMD2(0, h), uv: SIMD2(0, 1)),
                BlitVertex(pos: SIMD2(w, h), uv: SIMD2(1, 1)),
            ]
            var proj = canvasOrtho(size: canvasSize)
            enc.setVertexBytes(&quad, length: MemoryLayout<BlitVertex>.stride * 4, index: 0)
            enc.setVertexBytes(&proj, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            enc.setFragmentTexture(src, index: 0)
            enc.setFragmentSamplerState(ctx.sampler, index: 0)
            var uniforms = BlurUniforms(dir: dir, texel: texel)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<BlurUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
        }

        pass(from: texture, to: scratch, dir: SIMD2(1, 0))
        pass(from: scratch, to: texture, dir: SIMD2(0, 1))
        cmd.commit()

        // Diffusion enlarges the wet footprint slightly.
        bounds = bounds.insetBy(dx: -4, dy: -4)
        wetness -= 0.045
        return wetness > 0.02
    }

    /// Bakes the wet buffer (with edge darkening) into `target` and clears. Returns the baked rect.
    @discardableResult
    func dry(into target: MTLTexture) -> CGRect {
        guard hasContent, let cmd = ctx.queue.makeCommandBuffer() else { return .null }
        let baked = bounds
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            encodeComposite(enc, opacity: 1)
            enc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()   // caller snapshots undo pixels right after
        clear()
        return baked
    }

    /// Encodes the wet buffer draw (edge-darkening fragment) into an existing pass.
    func encodeComposite(_ enc: MTLRenderCommandEncoder, opacity: Float) {
        enc.setRenderPipelineState(ctx.wetPipeline)
        let w = Float(canvasSize.width), h = Float(canvasSize.height)
        var quad = [
            BlitVertex(pos: SIMD2(0, 0), uv: SIMD2(0, 0)),
            BlitVertex(pos: SIMD2(w, 0), uv: SIMD2(1, 0)),
            BlitVertex(pos: SIMD2(0, h), uv: SIMD2(0, 1)),
            BlitVertex(pos: SIMD2(w, h), uv: SIMD2(1, 1)),
        ]
        var proj = canvasOrtho(size: canvasSize)
        enc.setVertexBytes(&quad, length: MemoryLayout<BlitVertex>.stride * 4, index: 0)
        enc.setVertexBytes(&proj, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(ctx.sampler, index: 0)
        var uniforms = WetUniforms(
            texel: SIMD2(1 / Float(canvasSize.width), 1 / Float(canvasSize.height)),
            edgeGain: edgeGain, opacity: opacity)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<WetUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    func clear() {
        guard let cmd = ctx.queue.makeCommandBuffer() else { return }
        for t in [texture, scratch] {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = t
            rpd.colorAttachments[0].loadAction = .clear
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            rpd.colorAttachments[0].storeAction = .store
            cmd.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
        }
        cmd.commit()
        bounds = .null
        wetness = 0
    }
}
