import Testing
import Metal
import CoreGraphics
import Foundation
@testable import Sketch_Draw

/// Engine-level tests that exercise real Metal textures (run in the simulator/host GPU).
@MainActor
struct EngineTests {

    private func makeLayer(size: Int = 512, fill: UInt8) throws -> (MetalContext, PaintLayer) {
        let ctx = try MetalContext()
        let layer = try PaintLayer(context: ctx, width: size, height: size)
        let bytes = Data(repeating: fill, count: size * size * 4)
        layer.writeRegion(MTLRegionMake2D(0, 0, size, size), bytes: bytes)
        return (ctx, layer)
    }

    @Test func tileUndoRestoresBeforeAndAfterPixels() throws {
        let size = 512
        let (_, layer) = try makeLayer(size: size, fill: 0)
        let undo = TileUndoStack(canvasWidth: size, canvasHeight: size, tileSize: 256)

        // Stroke: snapshot a rect spanning tiles (0,0)+(1,0), then modify those pixels.
        undo.beginStroke(layer: layer)
        undo.willModify(rect: CGRect(x: 200, y: 40, width: 160, height: 60))
        let dirty = MTLRegionMake2D(200, 40, 160, 60)
        layer.writeRegion(dirty, bytes: Data(repeating: 255, count: 160 * 60 * 4))
        undo.endStroke()

        #expect(undo.canUndo)
        #expect(!undo.canRedo)

        undo.undo()
        // All modified pixels must be back to 0.
        #expect(layer.readRegion(dirty).allSatisfy { $0 == 0 })
        #expect(undo.canRedo)

        undo.redo()
        #expect(layer.readRegion(dirty).allSatisfy { $0 == 255 })

        // Pixels *outside* the modified rect must be untouched by undo/redo.
        undo.undo()
        let outside = layer.readRegion(MTLRegionMake2D(0, 400, 100, 100))
        #expect(outside.allSatisfy { $0 == 0 })
    }

    @Test func tileUndoDropsOldestBeyondCapacity() throws {
        let size = 256
        let (_, layer) = try makeLayer(size: size, fill: 0)
        let undo = TileUndoStack(canvasWidth: size, canvasHeight: size, tileSize: 256, maxEntries: 3)
        for i in 0..<5 {
            undo.beginStroke(layer: layer)
            undo.willModify(rect: CGRect(x: 0, y: 0, width: 10, height: 10))
            layer.writeRegion(MTLRegionMake2D(0, 0, 10, 10),
                              bytes: Data(repeating: UInt8(i + 1), count: 10 * 10 * 4))
            undo.endStroke()
        }
        // Only 3 entries retained.
        undo.undo(); undo.undo(); undo.undo()
        #expect(!undo.canUndo)
        // Oldest surviving "before" state is the end state of stroke 2 (value 2).
        let px = layer.readRegion(MTLRegionMake2D(0, 0, 10, 10))
        #expect(px.allSatisfy { $0 == 2 })
    }

    @Test func documentSaveLoadRoundTrip() throws {
        let w = 128, h = 128
        // Two layers with distinct premultiplied patterns.
        var bottom = Data(count: w * h * 4)
        var top = Data(count: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            bottom[i] = 200; bottom[i + 1] = 10; bottom[i + 2] = 10; bottom[i + 3] = 255
            top[i] = 0; top[i + 1] = 0; top[i + 2] = 0; top[i + 3] = 0   // fully transparent
        }
        let manifest = ArtworkDocument.Manifest(
            width: w, height: h,
            paper: PaintColor(r: 1, g: 1, b: 1, a: 1),
            layers: [
                .init(file: "layer_a.png", name: "Base", opacity: 1, visible: true, blendMode: .normal),
                .init(file: "layer_b.png", name: "Top", opacity: 0.5, visible: false, blendMode: .multiply),
            ])
        let doc = ArtworkDocument(manifest: manifest, layerPixels: [bottom, top], thumbnail: nil)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("drawsy-test-\(UUID().uuidString).drawsy")
        defer { try? FileManager.default.removeItem(at: dir) }
        try doc.save(to: dir)

        let loaded = try ArtworkDocument.load(from: dir)
        #expect(loaded.manifest.width == w)
        #expect(loaded.manifest.height == h)
        #expect(loaded.manifest.layers.count == 2)
        #expect(loaded.manifest.layers[1].name == "Top")
        #expect(loaded.manifest.layers[1].opacity == 0.5)
        #expect(loaded.manifest.layers[1].visible == false)
        #expect(loaded.manifest.layers[1].blendMode == .multiply)
        #expect(loaded.layerPixels[0] == bottom)
        #expect(loaded.layerPixels[1] == top)
    }

    @Test func strokeBuilderSpacingIsUniform() {
        let builder = StrokeBuilder(stabilization: 0, spacingFraction: 0.5)
        let radius: CGFloat = 10   // spacing = 0.5 * diameter = 10 px
        var stamps = builder.begin(StampPoint(position: .zero, radius: radius, alpha: 1))
        for i in 1...20 {
            stamps += builder.add(StampPoint(position: CGPoint(x: CGFloat(i) * 25, y: 0),
                                             radius: radius, alpha: 1))
        }
        stamps += builder.finish()
        #expect(stamps.count > 10)
        // Consecutive stamp distances should be ~10 px (tessellation tolerance ±25%).
        for i in 1..<stamps.count {
            let d = stamps[i].position.distance(to: stamps[i - 1].position)
            #expect(d > 7.5 && d < 12.5, "stamp \(i) spacing \(d)")
        }
    }

    @Test func responseCurveEndpointsAndMonotonicity() {
        let curve = ResponseCurve(minValue: 0.3, gamma: 1.7)
        #expect(abs(curve.apply(0) - 0.3) < 0.0001)
        #expect(abs(curve.apply(1) - 1.0) < 0.0001)
        var prev: CGFloat = -1
        for i in 0...20 {
            let v = curve.apply(CGFloat(i) / 20)
            #expect(v >= prev)
            prev = v
        }
    }
}
