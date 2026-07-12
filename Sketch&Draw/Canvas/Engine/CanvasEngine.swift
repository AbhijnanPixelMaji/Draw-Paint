import Metal
import MetalKit
import SwiftUI
import Combine
import simd

/// A raw input sample in view space, as delivered by `CanvasMTKView`.
struct InputSample {
    var viewPoint: CGPoint
    var pressure: CGFloat        // normalized 0…1
    var altitude: CGFloat        // radians; .pi/2 = perpendicular (no tilt)
    var timestamp: TimeInterval
}

/// The canvas engine: owns the Metal context, the layer stack, the stroke scratch buffer, brush/color,
/// the view transform, and tile undo. `MTKViewDelegate` for the composite pass.
///
/// Compositing model: layers are blended bottom→top into an **opaque accumulator** that starts as the
/// paper color (ping-pong between two textures, `blend_fragment` applies the blend mode); the final
/// accumulator is drawn to the drawable with the view transform. The in-progress stroke scratch is
/// blended (normal mode) right above the active layer.
@MainActor
final class CanvasEngine: NSObject, ObservableObject, MTKViewDelegate {
    let ctx: MetalContext
    let canvasSize: CGSize
    private(set) var layers: [PaintLayer]
    @Published var activeIndex = 0 { didSet { markComposited() } }
    var activeLayer: PaintLayer { layers[activeIndex] }
    let undo: TileUndoStack

    /// Per-stroke scratch: stamps render here, then merge into the active layer at stroke end.
    private let strokeScratch: PaintLayer
    /// Ping-pong accumulators for the blend composite.
    private let accumA: MTLTexture
    private let accumB: MTLTexture
    private var compositeDirty = true

    /// Watercolor wet state (Phase 4).
    let wet: WetBuffer
    private var diffusionTimer: Timer?
    /// Pickup texture for the smudge tool (copies pixels from under the previous stamp).
    private let smudgePickup: MTLTexture
    private var lastSmudgeRect: MTLRegion?
    private var dwellTimer: Timer?

    @Published var brush: BrushDescriptor = .pencil { didSet { rebuildStampIfNeeded(old: oldValue) } }
    @Published var color = PaintColor.black
    @Published var paper = PaintColor(r: 0.98, g: 0.97, b: 0.94, a: 1) { didSet { markComposited() } }

    @Published var transform = CanvasTransform()
    /// Bumps when undo/redo availability or layer structure/thumbnails change (drives SwiftUI refresh).
    @Published private(set) var revision = 0
    /// True when the document differs from the last save.
    private(set) var hasUnsavedChanges = false

    private var stampMask: MTLTexture
    private let paperGrain: MTLTexture

    private weak var mtkView: MTKView?
    private var didFit = false

    // Stroke state
    private var strokeActive = false
    private var builder: StrokeBuilder?
    private var strokeBounds = CGRect.null
    private var lastSampleTime: TimeInterval = 0
    private var lastSamplePoint = CGPoint.zero
    private var smoothedVelocity: CGFloat = 0
    private var rng = SystemRandomNumberGenerator()

    // MARK: - Init

    init(canvasSize: CGSize = CGSize(width: 2048, height: 2048)) throws {
        self.ctx = try MetalContext()
        self.canvasSize = canvasSize
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        let layer = try PaintLayer(context: ctx, width: w, height: h, name: "Layer 1")
        self.layers = [layer]
        self.strokeScratch = try PaintLayer(context: ctx, width: w, height: h)
        self.accumA = try ctx.makeLayerTexture(width: w, height: h)
        self.accumB = try ctx.makeLayerTexture(width: w, height: h)
        self.stampMask = try StampFactory.makeRoundStamp(context: ctx, hardness: BrushDescriptor.pencil.hardness)
        self.paperGrain = try StampFactory.makePaperGrain(context: ctx)
        self.undo = TileUndoStack(canvasWidth: w, canvasHeight: h)
        self.wet = try WetBuffer(context: ctx, canvasSize: canvasSize)
        // 256² pickup covers stamp radii up to ~128 canvas px.
        let pickupDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: MetalContext.layerPixelFormat, width: 256, height: 256, mipmapped: false)
        pickupDesc.usage = [.shaderRead]
        pickupDesc.storageMode = .private
        guard let pickup = ctx.device.makeTexture(descriptor: pickupDesc) else {
            throw EngineError.textureFailed
        }
        self.smudgePickup = pickup
        super.init()
        clear(layer.texture)
        clear(strokeScratch.texture)
    }

    /// Loads an existing document bundle into a fresh engine.
    convenience init(document: ArtworkDocument) throws {
        try self.init(canvasSize: CGSize(width: document.manifest.width,
                                         height: document.manifest.height))
        let w = document.manifest.width, h = document.manifest.height
        paper = document.manifest.paper
        var loaded: [PaintLayer] = []
        for (entry, pixels) in zip(document.manifest.layers, document.layerPixels) {
            let layer = try PaintLayer(context: ctx, width: w, height: h, name: entry.name)
            layer.opacity = entry.opacity
            layer.isVisible = entry.visible
            layer.blendMode = entry.blendMode
            layer.writeRegion(MTLRegionMake2D(0, 0, w, h), bytes: pixels)
            loaded.append(layer)
        }
        if !loaded.isEmpty {
            layers = loaded
            activeIndex = loaded.count - 1
        }
        hasUnsavedChanges = false
        markComposited()
    }

    /// Selects the active layer, drying any wet paint into the previously active layer first.
    func selectLayer(_ index: Int) {
        guard layers.indices.contains(index), index != activeIndex else { return }
        dryWetPaint()
        activeIndex = index
    }

    /// Serializes the full state into a document (reads all layer pixels — call sparingly).
    /// Wet paint is dried first so it is never lost to a save.
    func snapshotDocument() -> ArtworkDocument {
        dryWetPaint()
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        let full = MTLRegionMake2D(0, 0, w, h)
        var entries: [ArtworkDocument.LayerEntry] = []
        var pixels: [Data] = []
        for layer in layers {
            entries.append(.init(file: "layer_\(layer.id.uuidString).png",
                                 name: layer.name,
                                 opacity: layer.opacity,
                                 visible: layer.isVisible,
                                 blendMode: layer.blendMode))
            pixels.append(layer.readRegion(full))
        }
        let manifest = ArtworkDocument.Manifest(width: w, height: h, paper: paper, layers: entries)
        return ArtworkDocument(manifest: manifest, layerPixels: pixels,
                               thumbnail: compositeImage(maxDimension: 512))
    }

    func markSaved() { hasUnsavedChanges = false }

    private var maskCache: [String: MTLTexture] = [:]

    private func rebuildStampIfNeeded(old: BrushDescriptor) {
        guard old.hardness != brush.hardness || old.shape != brush.shape else { return }
        let key = "\(brush.shape.rawValue)-\(Int(brush.hardness * 100))"
        if let cached = maskCache[key] {
            stampMask = cached
            return
        }
        let mask: MTLTexture?
        switch brush.shape {
        case .round: mask = try? StampFactory.makeRoundStamp(context: ctx, hardness: brush.hardness)
        case .bristle: mask = try? StampFactory.makeBristleStamp(context: ctx)
        }
        if let mask {
            maskCache[key] = mask
            stampMask = mask
        }
    }

    /// Marks the composite stale and repaints.
    private func markComposited() {
        compositeDirty = true
        requestDisplay()
    }

    private func contentChanged() {
        hasUnsavedChanges = true
        revision &+= 1
        markComposited()
    }

    // MARK: - Layer operations

    var canAddLayer: Bool { layers.count < 16 }

    func addLayer() {
        dryWetPaint()
        guard canAddLayer,
              let layer = try? PaintLayer(context: ctx,
                                          width: Int(canvasSize.width), height: Int(canvasSize.height),
                                          name: "Layer \(layers.count + 1)") else { return }
        clear(layer.texture)
        layers.insert(layer, at: activeIndex + 1)
        activeIndex += 1
        undo.clear()   // structural change invalidates pixel history
        contentChanged()
    }

    // MARK: Background image

    static let backgroundLayerName = "Background"

    /// The dedicated bottom layer holding an image/texture background, if one has been set.
    var backgroundLayer: PaintLayer? {
        layers.first?.name == Self.backgroundLayerName ? layers.first : nil
    }

    var canSetBackgroundImage: Bool { backgroundLayer != nil || canAddLayer }

    /// Replaces the canvas background with a full-bleed image, written into a bottom "Background"
    /// layer (created on demand, reused thereafter). `tiled` repeats the image at its native pixel
    /// size (paper textures); otherwise it is aspect-filled and centered. Clears pixel undo history,
    /// consistent with the other structural layer operations.
    func setBackgroundImage(_ image: CGImage, tiled: Bool = false) {
        dryWetPaint()
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        guard let bytes = Self.backgroundRGBA(from: image, width: w, height: h, tiled: tiled)
        else { return }
        let bg: PaintLayer
        if let existing = backgroundLayer {
            bg = existing
        } else {
            guard canAddLayer,
                  let layer = try? PaintLayer(context: ctx, width: w, height: h,
                                              name: Self.backgroundLayerName) else { return }
            layers.insert(layer, at: 0)
            activeIndex += 1
            bg = layer
        }
        bg.writeRegion(MTLRegionMake2D(0, 0, w, h), bytes: bytes)
        undo.clear()   // entries may reference the replaced background pixels
        contentChanged()
    }

    /// Removes the image background (switching back to a plain paper color).
    func clearBackgroundImage() {
        guard let bg = backgroundLayer, layers.count > 1 else { return }
        dryWetPaint()
        layers.removeAll { $0 === bg }
        activeIndex = min(max(0, activeIndex - 1), layers.count - 1)
        undo.clear()
        contentChanged()
    }

    /// Renders `image` into premultiplied RGBA8 canvas-sized bytes (same convention as
    /// `ArtworkDocument.premultipliedRGBA`), either tiled at native size or aspect-filled.
    private static func backgroundRGBA(from image: CGImage, width: Int, height: Int,
                                       tiled: Bool) -> Data? {
        var data = Data(count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            let full = CGRect(x: 0, y: 0, width: width, height: height)
            ctx.clear(full)
            if tiled {
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                         byTiling: true)
            } else {
                let s = max(CGFloat(width) / CGFloat(image.width),
                            CGFloat(height) / CGFloat(image.height))
                let dw = CGFloat(image.width) * s, dh = CGFloat(image.height) * s
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: (CGFloat(width) - dw) / 2,
                                           y: (CGFloat(height) - dh) / 2, width: dw, height: dh))
            }
            return true
        }
        return ok ? data : nil
    }

    func deleteLayer(at index: Int) {
        guard layers.count > 1, layers.indices.contains(index) else { return }
        dryWetPaint()
        layers.remove(at: index)
        activeIndex = min(max(0, index - 1), layers.count - 1)
        undo.clear()
        contentChanged()
    }

    func duplicateLayer(at index: Int) {
        guard canAddLayer, layers.indices.contains(index) else { return }
        dryWetPaint()
        let src = layers[index]
        guard let copy = try? PaintLayer(context: ctx,
                                         width: src.width, height: src.height,
                                         name: src.name + " copy") else { return }
        copy.opacity = src.opacity
        copy.isVisible = src.isVisible
        copy.blendMode = src.blendMode
        let full = MTLRegionMake2D(0, 0, src.width, src.height)
        copy.writeRegion(full, bytes: src.readRegion(full))
        layers.insert(copy, at: index + 1)
        activeIndex = index + 1
        undo.clear()
        contentChanged()
    }

    func moveLayer(fromOffsets: IndexSet, toOffset: Int) {
        dryWetPaint()
        let activeLayerRef = activeLayer
        layers.move(fromOffsets: fromOffsets, toOffset: toOffset)
        activeIndex = layers.firstIndex(where: { $0 === activeLayerRef }) ?? 0
        undo.clear()
        contentChanged()
    }

    /// Merges layer `index` into the one below with source-over at the layer's opacity.
    /// (Blend modes are intentionally ignored during merge — documented simplification.)
    func mergeDown(at index: Int) {
        guard index > 0, layers.indices.contains(index) else { return }
        dryWetPaint()
        let top = layers[index]
        let below = layers[index - 1]
        guard let cmd = ctx.queue.makeCommandBuffer() else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = below.texture
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            drawFullCanvasQuad(enc, texture: top.texture, opacity: top.opacity)
            enc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        layers.remove(at: index)
        activeIndex = index - 1
        undo.clear()
        contentChanged()
    }

    func setLayerVisible(_ visible: Bool, at index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index].isVisible = visible
        contentChanged()
    }

    func setLayerOpacity(_ opacity: Float, at index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index].opacity = opacity
        hasUnsavedChanges = true
        markComposited()   // no revision bump — sliders drive their own UI
    }

    func setLayerBlendMode(_ mode: BlendMode, at index: Int) {
        guard layers.indices.contains(index) else { return }
        layers[index].blendMode = mode
        contentChanged()
    }

    // MARK: - Thumbnails

    /// Small CGImage of one layer (transparent background preserved).
    func layerThumbnail(at index: Int, maxDimension: CGFloat = 88) -> CGImage? {
        guard layers.indices.contains(index) else { return nil }
        let layer = layers[index]
        let full = MTLRegionMake2D(0, 0, layer.width, layer.height)
        guard let img = ArtworkDocument.image(fromPremultipliedRGBA: layer.readRegion(full),
                                              width: layer.width, height: layer.height) else { return nil }
        return downscale(img, maxDimension: maxDimension)
    }

    /// Downscaled image of the full composite (for gallery thumbs).
    func compositeImage(maxDimension: CGFloat) -> CGImage? {
        recompositeIfNeeded()
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        let full = MTLRegionMake2D(0, 0, w, h)
        var data = Data(count: w * h * 4)
        data.withUnsafeMutableBytes { raw in
            finalAccum.getBytes(raw.baseAddress!, bytesPerRow: w * 4, from: full, mipmapLevel: 0)
        }
        guard let img = ArtworkDocument.image(fromPremultipliedRGBA: data, width: w, height: h) else { return nil }
        return downscale(img, maxDimension: maxDimension)
    }

    private func downscale(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let scale = min(1, maxDimension / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * scale))
        let h = max(1, Int(CGFloat(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - MTKView setup / delegate

    func configure(_ view: MTKView) {
        view.device = ctx.device
        view.colorPixelFormat = MetalContext.layerPixelFormat
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.preferredFramesPerSecond = 120
        // Outside-the-canvas backdrop: warm "desk" gray, a step darker than the default paper so
        // the paper edge reads. Must stay in sync with DrawsyTheme.desk.
        view.clearColor = MTLClearColor(red: 0.90, green: 0.885, blue: 0.86, alpha: 1)
        view.delegate = self
        mtkView = view
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        // MTKView always calls this on the main thread.
        MainActor.assumeIsolated { self.render(in: view) }
    }

    private func requestDisplay() { mtkView?.setNeedsDisplay() }

    /// The accumulator currently holding the finished composite (set by `recompositeIfNeeded`).
    private var cachedFinalAccum: MTLTexture?
    private var finalAccum: MTLTexture { cachedFinalAccum ?? accumA }

    private func render(in view: MTKView) {
        let viewSize = view.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        if !didFit {
            transform = .fitting(canvasSize: canvasSize, in: viewSize)
            didFit = true
        }
        recompositeIfNeeded()
        guard let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cmd = ctx.queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(ctx.blitPipeline)
        var mvp = transform.mvp(viewSize: viewSize)
        let w = Float(canvasSize.width), h = Float(canvasSize.height)
        var quad = [
            BlitVertex(pos: SIMD2(0, 0), uv: SIMD2(0, 0)),
            BlitVertex(pos: SIMD2(w, 0), uv: SIMD2(1, 0)),
            BlitVertex(pos: SIMD2(0, h), uv: SIMD2(0, 1)),
            BlitVertex(pos: SIMD2(w, h), uv: SIMD2(1, 1)),
        ]
        enc.setVertexBytes(&quad, length: MemoryLayout<BlitVertex>.stride * 4, index: 0)
        enc.setVertexBytes(&mvp, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        enc.setFragmentTexture(finalAccum, index: 0)
        enc.setFragmentSamplerState(ctx.sampler, index: 0)
        var op: Float = 1
        enc.setFragmentBytes(&op, length: MemoryLayout<Float>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    /// Rebuilds the opaque composite accumulator if anything changed.
    private func recompositeIfNeeded() {
        guard compositeDirty else { return }
        compositeDirty = false
        guard let cmd = ctx.queue.makeCommandBuffer() else { return }

        var current = accumA
        var other = accumB

        // Base pass: fill with paper color.
        let clearPass = MTLRenderPassDescriptor()
        clearPass.colorAttachments[0].texture = current
        clearPass.colorAttachments[0].loadAction = .clear
        clearPass.colorAttachments[0].clearColor = MTLClearColor(red: Double(paper.r), green: Double(paper.g),
                                                                 blue: Double(paper.b), alpha: 1)
        clearPass.colorAttachments[0].storeAction = .store
        cmd.makeRenderCommandEncoder(descriptor: clearPass)?.endEncoding()

        func blend(_ texture: MTLTexture, mode: BlendMode, opacity: Float) {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = other
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(ctx.blendPipeline)
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
            enc.setFragmentTexture(current, index: 0)
            enc.setFragmentTexture(texture, index: 1)
            enc.setFragmentSamplerState(ctx.sampler, index: 0)
            var uniforms = BlendUniforms(mode: mode.shaderIndex, opacity: opacity)
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<BlendUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            enc.endEncoding()
            swap(&current, &other)
        }

        for (i, layer) in layers.enumerated() where layer.isVisible {
            blend(layer.texture, mode: layer.blendMode, opacity: layer.opacity)
            if i == activeIndex {
                if (strokeActive && brush.medium == .standard) || pendingFill != nil {
                    blend(strokeScratch.texture, mode: .normal, opacity: Float(strokeMergeOpacity))
                }
                if wet.hasContent {
                    // Wet watercolor rides above the active layer until dried. Because the wet
                    // composite needs its edge-darkening shader (not the plain blend pass), draw it
                    // into `other` on top of a copy of the current accumulation.
                    let rpd = MTLRenderPassDescriptor()
                    rpd.colorAttachments[0].texture = other
                    rpd.colorAttachments[0].loadAction = .dontCare
                    rpd.colorAttachments[0].storeAction = .store
                    if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
                        // Base copy…
                        enc.setRenderPipelineState(ctx.blitPipeline)
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
                        enc.setFragmentTexture(current, index: 0)
                        enc.setFragmentSamplerState(ctx.sampler, index: 0)
                        var op: Float = 1
                        enc.setFragmentBytes(&op, length: MemoryLayout<Float>.stride, index: 0)
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                        // …then the wet buffer with edge darkening over it.
                        wet.encodeComposite(enc, opacity: 1)
                        enc.endEncoding()
                    }
                    swap(&current, &other)
                }
            }
        }
        cmd.commit()
        cmd.waitUntilCompleted()
        cachedFinalAccum = current
    }

    // MARK: - Stroke input

    private var strokeMergeOpacity: CGFloat {
        brush.compositing == .flat ? brush.strokeOpacity : 1
    }

    /// Straight-edge guide: when set, stroke points are projected onto the line (canvas space).
    var ruler: (origin: CGPoint, angle: CGFloat)?

    private func applyRuler(_ p: CGPoint) -> CGPoint {
        guard let ruler else { return p }
        let dir = CGPoint(x: cos(ruler.angle), y: sin(ruler.angle))
        let rel = CGPoint(x: p.x - ruler.origin.x, y: p.y - ruler.origin.y)
        let t = rel.x * dir.x + rel.y * dir.y
        return CGPoint(x: ruler.origin.x + dir.x * t, y: ruler.origin.y + dir.y * t)
    }

    func strokeBegan(_ sample: InputSample) {
        let p = applyRuler(transform.viewToCanvas(sample.viewPoint))
        strokeActive = true
        strokeBounds = .null
        lastSampleTime = sample.timestamp
        lastSamplePoint = p
        smoothedVelocity = 0
        lastEmitPoint = nil
        lastSmudgeRect = nil
        if brush.medium == .standard { clear(strokeScratch.texture) }
        if brush.medium == .smudge || brush.medium == .eraser {
            undo.beginStroke(layer: activeLayer)   // direct layer edits
        }
        builder = StrokeBuilder(stabilization: brush.stabilization, spacingFraction: brush.spacing)
        let sp = stampPoint(canvasPoint: p, sample: sample)
        emit(builder?.begin(sp) ?? [])
        if brush.dwellBuildup { startDwellTimer() }
    }

    func strokeMoved(_ sample: InputSample) {
        guard strokeActive, let builder else { return }
        let p = applyRuler(transform.viewToCanvas(sample.viewPoint))
        // Velocity in canvas px/s, exponentially smoothed; drives ink thinning.
        let dt = max(1.0 / 500, sample.timestamp - lastSampleTime)
        let v = p.distance(to: lastSamplePoint) / dt
        smoothedVelocity += (v - smoothedVelocity) * 0.3
        lastSampleTime = sample.timestamp
        lastSamplePoint = p
        emit(builder.add(stampPoint(canvasPoint: p, sample: sample)))
    }

    func strokeEnded() {
        guard strokeActive else { return }
        stopDwellTimer()
        if let builder { emit(builder.finish()) }
        builder = nil
        strokeActive = false
        switch brush.medium {
        case .standard:
            mergeStroke()
        case .watercolor:
            startDiffusionTimer()   // keeps spreading after the stroke lifts
        case .smudge:
            undo.endStroke()
        case .eraser:
            // GPU fence: the undo "after" snapshot reads erased pixels on the CPU.
            if let cmd = ctx.queue.makeCommandBuffer() {
                cmd.commit()
                cmd.waitUntilCompleted()
            }
            undo.endStroke()
        }
        contentChanged()
    }

    // MARK: - Flood fill (tap → preview in scratch → confirm/shuffle/cancel)

    /// Non-nil while a fill preview is showing in the stroke scratch.
    @Published private(set) var pendingFill: FloodFill.Result?
    var fillPattern: FillPattern = .solid
    var fillTolerance: Int = 48

    /// Flood-fills from a canvas point into a *preview* (stroke scratch). Confirm with
    /// `commitFill()`, re-tint with `retintFill(color:)`, abandon with `cancelFill()`.
    func previewFill(atCanvasPoint p: CGPoint) {
        let w = Int(canvasSize.width), h = Int(canvasSize.height)
        let x = Int(p.x), y = Int(p.y)
        guard (0..<w).contains(x), (0..<h).contains(y) else { return }
        // Fence: read the layer only after in-flight strokes land.
        if let cmd = ctx.queue.makeCommandBuffer() { cmd.commit(); cmd.waitUntilCompleted() }
        let pixels = activeLayer.readRegion(MTLRegionMake2D(0, 0, w, h))
        guard let result = FloodFill.fill(pixels: pixels, width: w, height: h,
                                          startX: x, startY: y,
                                          tolerance: fillTolerance, gapClosing: 1) else { return }
        pendingFill = result
        writeFillPreview(result)
    }

    /// Re-renders the pending fill with the current color/pattern (used by the shuffle button).
    func retintFill() {
        guard let pendingFill else { return }
        writeFillPreview(pendingFill)
    }

    private func writeFillPreview(_ result: FloodFill.Result) {
        clear(strokeScratch.texture)
        let bytes = FloodFill.render(result: result, width: Int(canvasSize.width),
                                     color: color, pattern: fillPattern)
        let b = result.bounds
        strokeScratch.writeRegion(
            MTLRegionMake2D(Int(b.minX), Int(b.minY), Int(b.width), Int(b.height)), bytes: bytes)
        markComposited()
    }

    func commitFill() {
        guard let result = pendingFill else { return }
        strokeBounds = result.bounds
        pendingFill = nil
        mergeStroke()   // scratch → layer with undo, then clears scratch
        contentChanged()
    }

    func cancelFill() {
        pendingFill = nil
        clear(strokeScratch.texture)
        markComposited()
    }

    /// Samples the composite color at a canvas point (eyedropper).
    func sampleColor(atCanvasPoint p: CGPoint) -> PaintColor? {
        let x = Int(p.x), y = Int(p.y)
        guard (0..<Int(canvasSize.width)).contains(x), (0..<Int(canvasSize.height)).contains(y)
        else { return nil }
        recompositeIfNeeded()
        var px = [UInt8](repeating: 0, count: 4)
        finalAccum.getBytes(&px, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return PaintColor(r: Float(px[0]) / 255, g: Float(px[1]) / 255,
                          b: Float(px[2]) / 255, a: 1)
    }

    // MARK: - Cutter (lasso cut & move)

    struct FloatingSelection {
        let texture: MTLTexture   // the cut pixels (bounds-sized, premultiplied)
        let bounds: CGRect        // original canvas rect
        var offset: CGPoint = .zero
    }
    @Published private(set) var selection: FloatingSelection?

    /// Cuts the pixels inside the lasso polygon (canvas space) off the active layer into a
    /// floating selection. One tile-undo stroke stays open until commit/cancel.
    func cutSelection(path: [CGPoint]) {
        guard selection == nil, path.count >= 3 else { return }
        dryWetPaint()
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in path {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let bounds = CGRect(x: floor(minX), y: floor(minY),
                            width: ceil(maxX - minX), height: ceil(maxY - minY))
            .intersection(CGRect(origin: .zero, size: canvasSize))
        let bw = Int(bounds.width), bh = Int(bounds.height)
        guard bw > 2, bh > 2 else { return }

        // Rasterize the lasso into an 8-bit coverage mask.
        var maskData = [UInt8](repeating: 0, count: bw * bh)
        maskData.withUnsafeMutableBytes { raw in
            guard let cg = CGContext(data: raw.baseAddress, width: bw, height: bh,
                                     bitsPerComponent: 8, bytesPerRow: bw,
                                     space: CGColorSpaceCreateDeviceGray(),
                                     bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Canvas y-down ↔ CG y-up: flip vertically so mask rows match texture rows.
            cg.translateBy(x: 0, y: CGFloat(bh))
            cg.scaleBy(x: 1, y: -1)
            cg.setFillColor(gray: 1, alpha: 1)
            cg.beginPath()
            cg.move(to: CGPoint(x: path[0].x - bounds.minX, y: path[0].y - bounds.minY))
            for p in path.dropFirst() {
                cg.addLine(to: CGPoint(x: p.x - bounds.minX, y: p.y - bounds.minY))
            }
            cg.closePath()
            cg.fillPath()
        }

        // Fence, then read the layer pixels under the bounds.
        if let cmd = ctx.queue.makeCommandBuffer() { cmd.commit(); cmd.waitUntilCompleted() }
        let region = MTLRegionMake2D(Int(bounds.minX), Int(bounds.minY), bw, bh)
        var pixels = activeLayer.readRegion(region)

        undo.beginStroke(layer: activeLayer)
        undo.willModify(rect: bounds)

        // Split into "cut" (floating) and "remaining" (layer) buffers.
        var floating = Data(count: bw * bh * 4)
        pixels.withUnsafeMutableBytes { (src: UnsafeMutableRawBufferPointer) in
            floating.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
                let s = src.bindMemory(to: UInt8.self).baseAddress!
                let d = dst.bindMemory(to: UInt8.self).baseAddress!
                for i in 0..<(bw * bh) where maskData[i] > 127 {
                    for c in 0..<4 {
                        d[i * 4 + c] = s[i * 4 + c]
                        s[i * 4 + c] = 0
                    }
                }
            }
        }
        activeLayer.writeRegion(region, bytes: pixels)   // layer minus the cut

        guard let tex = try? ctx.makeLayerTexture(width: bw, height: bh) else {
            undo.endStroke()
            return
        }
        tex.replace(region: MTLRegionMake2D(0, 0, bw, bh), mipmapLevel: 0,
                    withBytes: [UInt8](floating), bytesPerRow: bw * 4)
        selection = FloatingSelection(texture: tex, bounds: bounds)
        contentChanged()
    }

    func moveSelection(by delta: CGPoint) {
        guard selection != nil else { return }
        selection!.offset.x += delta.x
        selection!.offset.y += delta.y
        markComposited()
    }

    /// Stamps the floating selection down at its current offset and closes the undo stroke.
    func commitSelection() {
        guard let sel = selection else { return }
        let dest = sel.bounds.offsetBy(dx: sel.offset.x, dy: sel.offset.y)
        undo.willModify(rect: dest)
        if let cmd = ctx.queue.makeCommandBuffer() {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = activeLayer.texture
            rpd.colorAttachments[0].loadAction = .load
            rpd.colorAttachments[0].storeAction = .store
            if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
                encodeQuad(enc, texture: sel.texture, rect: dest, opacity: 1)
                enc.endEncoding()
            }
            cmd.commit()
            cmd.waitUntilCompleted()
        }
        undo.endStroke()
        selection = nil
        contentChanged()
    }

    /// Puts the cut pixels back where they came from.
    func cancelSelection() {
        guard selection != nil else { return }
        selection!.offset = .zero
        commitSelection()
    }

    /// Encodes a textured quad at an arbitrary canvas rect with the blit pipeline.
    private func encodeQuad(_ enc: MTLRenderCommandEncoder, texture: MTLTexture,
                            rect: CGRect, opacity: Float) {
        enc.setRenderPipelineState(ctx.blitPipeline)
        let x0 = Float(rect.minX), y0 = Float(rect.minY)
        let x1 = Float(rect.maxX), y1 = Float(rect.maxY)
        var quad = [
            BlitVertex(pos: SIMD2(x0, y0), uv: SIMD2(0, 0)),
            BlitVertex(pos: SIMD2(x1, y0), uv: SIMD2(1, 0)),
            BlitVertex(pos: SIMD2(x0, y1), uv: SIMD2(0, 1)),
            BlitVertex(pos: SIMD2(x1, y1), uv: SIMD2(1, 1)),
        ]
        var proj = canvasOrtho(size: canvasSize)
        enc.setVertexBytes(&quad, length: MemoryLayout<BlitVertex>.stride * 4, index: 0)
        enc.setVertexBytes(&proj, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentSamplerState(ctx.sampler, index: 0)
        var op = opacity
        enc.setFragmentBytes(&op, length: MemoryLayout<Float>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - Watercolor wet lifecycle

    /// Bakes the wet buffer into the active layer as a single undoable action.
    func dryWetPaint() {
        guard wet.hasContent else { return }
        stopDiffusionTimer()
        undo.beginStroke(layer: activeLayer)
        undo.willModify(rect: wet.bounds)
        wet.dry(into: activeLayer.texture)
        undo.endStroke()
        contentChanged()
    }

    var hasWetPaint: Bool { wet.hasContent }

    private func startDiffusionTimer() {
        guard diffusionTimer == nil else { return }
        diffusionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.wet.diffuse() {
                    self.markComposited()
                } else {
                    self.stopDiffusionTimer()
                    self.markComposited()
                }
            }
        }
    }

    private func stopDiffusionTimer() {
        diffusionTimer?.invalidate()
        diffusionTimer = nil
    }

    // MARK: - Airbrush dwell

    private func startDwellTimer() {
        stopDwellTimer()
        dwellTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.strokeActive else { return }
                // Deposit at the current position; alpha scales with dwell tick.
                let sp = StampPoint(position: self.lastSamplePoint,
                                    radius: self.brush.radius(pressure: 0.6, velocityNorm: 0, tilt: 0),
                                    alpha: self.brush.alpha(pressure: 0.6, tilt: 0))
                self.emit([sp])
            }
        }
    }

    private func stopDwellTimer() {
        dwellTimer?.invalidate()
        dwellTimer = nil
    }

    private func stampPoint(canvasPoint: CGPoint, sample: InputSample) -> StampPoint {
        let tilt = 1 - max(0, min(1, sample.altitude / (.pi / 2)))   // 0 = perpendicular, 1 = flat
        let vNorm = smoothedVelocity / 2500                          // ~2500 px/s = fast
        return StampPoint(position: canvasPoint,
                          radius: brush.radius(pressure: sample.pressure, velocityNorm: vNorm, tilt: tilt),
                          alpha: brush.alpha(pressure: sample.pressure, tilt: tilt))
    }

    private var lastEmitPoint: CGPoint?

    private func emit(_ points: [StampPoint]) {
        guard !points.isEmpty else { return }
        if brush.medium == .smudge {
            emitSmudge(points)
            markComposited()
            return
        }
        var instances: [StampInstance] = []
        instances.reserveCapacity(points.count)
        batchBounds = .null
        let baseColor = color.simd
        for p in points {
            var pos = p.position
            if brush.scatter > 0 {
                let mag = brush.scatter * p.radius
                pos.x += CGFloat.random(in: -mag...mag, using: &rng)
                pos.y += CGFloat.random(in: -mag...mag, using: &rng)
            }
            var angle: Float = 0
            if brush.directionalRotation, let last = lastEmitPoint, last != pos {
                // Bristle column is vertical in the mask; rotate so it lies perpendicular
                // to the motion → each bristle traces a streak along the stroke.
                angle = Float(atan2(pos.y - last.y, pos.x - last.x))
            } else if brush.randomRotation {
                angle = Float.random(in: 0...(2 * .pi), using: &rng)
            }
            lastEmitPoint = pos
            var col = baseColor
            col.w = Float(p.alpha)
            instances.append(StampInstance(center: SIMD2(Float(pos.x), Float(pos.y)),
                                           radius: Float(p.radius), angle: angle, color: col))
            let r = p.radius + brush.scatter * p.radius
            let rect = CGRect(x: pos.x - r, y: pos.y - r, width: r * 2, height: r * 2)
            strokeBounds = strokeBounds.union(rect)
            batchBounds = batchBounds.union(rect)
            if brush.medium == .watercolor { wet.noteStamped(rect: rect) }
        }
        if brush.medium == .eraser, !batchBounds.isNull {
            // Direct layer writes: snapshot the tiles this batch will touch, *before* the GPU work.
            // A tile new to this batch was never in an earlier batch's bounds, so its pixels are
            // not in flight — safe to read without a fence.
            undo.willModify(rect: batchBounds)
        }
        encodeStampPass(instances)
        markComposited()
    }
    private var batchBounds = CGRect.null

    /// Smudge: for each stamp, copy the pixels under the *previous* position into the pickup
    /// texture, then draw them at the *current* position through the soft mask — pigment is
    /// dragged along the stroke. Writes directly to the active layer (tile-undo per rect).
    private func emitSmudge(_ points: [StampPoint]) {
        let layerTex = activeLayer.texture
        for p in points {
            let r = min(120, p.radius)
            let side = Int(r * 2)
            guard side > 1 else { continue }
            let x = Int(p.position.x - r), y = Int(p.position.y - r)
            // Clamp inside the canvas.
            let cx = max(0, min(layerTex.width - side, x))
            let cy = max(0, min(layerTex.height - side, y))
            let destRegion = MTLRegionMake2D(cx, cy, side, side)

            if let srcRegion = lastSmudgeRect,
               let cmd = ctx.queue.makeCommandBuffer() {
                // 1) Pick up from the previous stamp footprint.
                if let blit = cmd.makeBlitCommandEncoder() {
                    blit.copy(from: layerTex, sourceSlice: 0, sourceLevel: 0,
                              sourceOrigin: srcRegion.origin,
                              sourceSize: MTLSize(width: min(srcRegion.size.width, 256),
                                                  height: min(srcRegion.size.height, 256), depth: 1),
                              to: smudgePickup, destinationSlice: 0, destinationLevel: 0,
                              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                }
                // 2) Restamp at the current position.
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = layerTex
                rpd.colorAttachments[0].loadAction = .load
                rpd.colorAttachments[0].storeAction = .store
                if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
                    enc.setRenderPipelineState(ctx.smudgePipeline)
                    var instance = StampInstance(
                        center: SIMD2(Float(cx + side / 2), Float(cy + side / 2)),
                        radius: Float(side) / 2, angle: 0,
                        // r = valid fraction of the pickup texture; a = smudge strength.
                        color: SIMD4(Float(side) / 256, 0, 0, Float(brush.smudgeStrength)))
                    enc.setVertexBytes(&instance, length: MemoryLayout<StampInstance>.stride, index: 0)
                    var proj = canvasOrtho(size: canvasSize)
                    enc.setVertexBytes(&proj, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                    enc.setFragmentTexture(smudgePickup, index: 0)
                    enc.setFragmentTexture(stampMask, index: 1)
                    enc.setFragmentSamplerState(ctx.sampler, index: 0)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    enc.endEncoding()
                }
                undo.willModify(rect: CGRect(x: cx, y: cy, width: side, height: side))
                cmd.commit()
                // The undo "before" snapshot for the *next* stamp reads these pixels on the CPU,
                // so each smudge step must land before the next willModify. Smudge strokes are
                // slow-moving; the sync cost is acceptable (revisit in the Phase 6 perf pass).
                cmd.waitUntilCompleted()
            }
            lastSmudgeRect = destRegion
        }
    }

    private func encodeStampPass(_ instances: [StampInstance]) {
        guard !instances.isEmpty,
              let buf = ctx.device.makeBuffer(bytes: instances,
                                              length: MemoryLayout<StampInstance>.stride * instances.count,
                                              options: .storageModeShared),
              let cmd = ctx.queue.makeCommandBuffer() else { return }
        let rpd = MTLRenderPassDescriptor()
        // Watercolor deposits into the persistent wet buffer, the eraser writes destination-out
        // directly on the layer, everything else goes to the stroke scratch.
        let target: MTLTexture = switch brush.medium {
        case .watercolor: wet.texture
        case .eraser: activeLayer.texture
        default: strokeScratch.texture
        }
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let pipeline: MTLRenderPipelineState = switch brush.medium {
        case .eraser: ctx.erasePipeline
        default: brush.compositing == .flat ? ctx.stampMaxPipeline : ctx.stampPipeline
        }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        var proj = canvasOrtho(size: canvasSize)
        enc.setVertexBytes(&proj, length: MemoryLayout<simd_float4x4>.stride, index: 1)
        enc.setFragmentTexture(stampMask, index: 0)
        enc.setFragmentTexture(paperGrain, index: 1)
        enc.setFragmentSamplerState(ctx.sampler, index: 0)
        enc.setFragmentSamplerState(ctx.repeatSampler, index: 1)
        var uniforms = StampUniforms(useGrain: brush.usesGrain ? 1 : 0,
                                     grainAmount: Float(brush.grainAmount),
                                     grainScale: Float(brush.grainScale),
                                     _pad: 0)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<StampUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                           instanceCount: instances.count)
        enc.endEncoding()
        cmd.commit()
    }

    /// Merges the stroke scratch into the active layer (undo-snapshotting the dirtied tiles), then clears it.
    private func mergeStroke() {
        guard !strokeBounds.isNull else { return }
        undo.beginStroke(layer: activeLayer)
        undo.willModify(rect: strokeBounds)

        guard let cmd = ctx.queue.makeCommandBuffer() else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = activeLayer.texture
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            drawFullCanvasQuad(enc, texture: strokeScratch.texture, opacity: Float(strokeMergeOpacity))
            enc.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()   // undo's "after" snapshot reads these pixels on the CPU

        undo.endStroke()
        clear(strokeScratch.texture)
        strokeBounds = .null
    }

    /// Encodes a full-canvas textured quad with the blit pipeline into the current encoder.
    private func drawFullCanvasQuad(_ enc: MTLRenderCommandEncoder, texture: MTLTexture, opacity: Float) {
        enc.setRenderPipelineState(ctx.blitPipeline)
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
        var op = opacity
        enc.setFragmentBytes(&op, length: MemoryLayout<Float>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func clear(_ texture: MTLTexture) {
        guard let cmd = ctx.queue.makeCommandBuffer() else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        cmd.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    // MARK: - Pan / zoom / undo

    func pan(by delta: CGPoint) {
        transform.offset.x += delta.x
        transform.offset.y += delta.y
        requestDisplay()
    }

    func zoom(by factor: CGFloat, around p: CGPoint) {
        let newScale = min(max(transform.scale * factor, 0.1), 20)
        let realFactor = newScale / transform.scale
        transform.offset.x = p.x - realFactor * (p.x - transform.offset.x)
        transform.offset.y = p.y - realFactor * (p.y - transform.offset.y)
        transform.scale = newScale
        requestDisplay()
    }

    func zoomToFit() {
        if let size = mtkView?.bounds.size {
            transform = .fitting(canvasSize: canvasSize, in: size)
            requestDisplay()
        }
    }

    var canUndo: Bool { undo.canUndo }
    var canRedo: Bool { undo.canRedo }

    // Wet paint is baked first, so "undo" right after painting wet reverts that bake — consistent.
    func performUndo() { dryWetPaint(); undo.undo(); contentChanged() }
    func performRedo() { dryWetPaint(); undo.redo(); contentChanged() }

    #if DEBUG
    /// Draws one deterministic stroke per Phase-2 preset (transform-independent, canvas space) so the
    /// pipeline is verifiable in the Simulator. Gated behind `DRAWSY_DEBUG_STROKE` by the caller.
    func debugStroke() {
        let savedBrush = brush
        let savedColor = color

        func run(_ preset: BrushDescriptor, _ paint: PaintColor,
                 path: (CGFloat) -> CGPoint, pressure: (CGFloat) -> CGFloat, steps: Int = 90) {
            brush = preset
            color = paint
            let t0 = ProcessInfo.processInfo.systemUptime
            strokeBegan(InputSample(viewPoint: transform.canvasToView(path(0)),
                                    pressure: pressure(0), altitude: .pi / 2, timestamp: t0))
            for i in 1...steps {
                let t = CGFloat(i) / CGFloat(steps)
                strokeMoved(InputSample(viewPoint: transform.canvasToView(path(t)),
                                        pressure: pressure(t), altitude: .pi / 2,
                                        timestamp: t0 + Double(t) * 0.9))
            }
            strokeEnded()
        }

        // Layer 1: pencil + ink.
        run(.pencil, .black,
            path: { t in CGPoint(x: 220 + t * 700, y: 260 + t * 480) },
            pressure: { t in 0.15 + t * 0.85 })
        run(.ink, .blue,
            path: { t in CGPoint(x: 220 + t * 1500, y: 1000 + sin(t * .pi * 3) * 160) },
            pressure: { _ in 0.7 })

        // Layer 2 (multiply): marker strokes — visibly multiplying over layer 1.
        addLayer()
        setLayerBlendMode(.multiply, at: activeIndex)
        run(.marker, .red,
            path: { t in
                let a = t * 2 * CGFloat.pi
                return CGPoint(x: 1000 + cos(a) * 300 + t * 240, y: 1520 + sin(a) * 200)
            },
            pressure: { _ in 0.8 }, steps: 140)
        run(.marker, .red,
            path: { t in CGPoint(x: 700 + t * 900, y: 1560) },
            pressure: { _ in 0.8 })
        // Cross the blue ink so the multiply blend is visible.
        run(.marker, PaintColor(r: 0.95, g: 0.75, b: 0.2, a: 1),
            path: { t in CGPoint(x: 500 + t * 900, y: 850 + t * 300) },
            pressure: { _ in 0.8 })

        // Phase 4 — back on layer 1: watercolor overlap (bloom + edge darkening after dry),
        // acrylic bristle curve, airbrush cloud, smudge dragged through the pencil line.
        selectLayer(0)
        run(.watercolor, PaintColor(r: 0.2, g: 0.45, b: 0.8, a: 1),
            path: { t in CGPoint(x: 300 + t * 450, y: 1750 + sin(t * .pi) * 60) },
            pressure: { _ in 0.8 }, steps: 60)
        run(.watercolor, PaintColor(r: 0.85, g: 0.3, b: 0.35, a: 1),
            path: { t in CGPoint(x: 480 + t * 450, y: 1790 - sin(t * .pi) * 50) },
            pressure: { _ in 0.8 }, steps: 60)
        // Let the wash spread, then bake so edge darkening is visible in the saved thumb too.
        for _ in 0..<10 { _ = wet.diffuse() }
        dryWetPaint()

        run(.acrylic, PaintColor(r: 0.15, g: 0.5, b: 0.35, a: 1),
            path: { t in CGPoint(x: 1150 + t * 650, y: 1850 + sin(t * .pi * 2) * 90) },
            pressure: { _ in 0.85 }, steps: 110)

        run(.airbrush, PaintColor(r: 0.5, g: 0.25, b: 0.65, a: 1),
            path: { t in
                let a = t * 4 * CGFloat.pi
                return CGPoint(x: 1650 + cos(a) * (60 + t * 60), y: 350 + sin(a) * (60 + t * 60))
            },
            pressure: { _ in 0.7 }, steps: 120)

        // Smudge: drag across the pencil diagonal, perpendicular to it.
        run(.smudge, .black,
            path: { t in CGPoint(x: 560 - t * 180, y: 500 + t * 180) },
            pressure: { _ in 0.8 }, steps: 40)

        brush = savedBrush
        color = savedColor
    }
    #endif
}
