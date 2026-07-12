import Metal
import CoreGraphics
import Foundation

/// A single paint layer backed by a premultiplied RGBA8 texture in canvas space, plus its
/// compositing metadata (name, opacity, visibility, blend mode).
final class PaintLayer: Identifiable {
    let id = UUID()
    let texture: MTLTexture
    var name: String
    var opacity: Float = 1
    var isVisible = true
    var blendMode: BlendMode = .normal

    var width: Int { texture.width }
    var height: Int { texture.height }

    init(context: MetalContext, width: Int, height: Int, name: String = "Layer") throws {
        self.texture = try context.makeLayerTexture(width: width, height: height)
        self.name = name
    }

    /// Reads a region of pixels (RGBA8) into a `Data` buffer (undo snapshots, PNG export).
    func readRegion(_ region: MTLRegion) -> Data {
        let bytesPerRow = region.size.width * 4
        var data = Data(count: bytesPerRow * region.size.height)
        data.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: region,
                             mipmapLevel: 0)
        }
        return data
    }

    /// Writes previously-captured pixels back into a region (undo/redo, document load).
    func writeRegion(_ region: MTLRegion, bytes: Data) {
        let bytesPerRow = region.size.width * 4
        bytes.withUnsafeBytes { raw in
            texture.replace(region: region,
                            mipmapLevel: 0,
                            withBytes: raw.baseAddress!,
                            bytesPerRow: bytesPerRow)
        }
    }
}
