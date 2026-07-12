import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// On-disk artwork bundle:
/// ```
/// <name>.drawsy/
/// ├── manifest.json     — canvas size, paper color, layer metadata (bottom → top)
/// ├── layers/layer_<uuid>.png
/// └── thumb.png
/// ```
/// `journal.bin` joins in Phase 6.
struct ArtworkDocument {
    struct LayerEntry: Codable {
        var file: String
        var name: String
        var opacity: Float
        var visible: Bool
        var blendMode: BlendMode
    }

    struct Manifest: Codable {
        var version: Int = 1
        var width: Int
        var height: Int
        var paper: PaintColor
        var layers: [LayerEntry]   // bottom → top
    }

    var manifest: Manifest
    /// RGBA8 premultiplied pixel data per layer, parallel to `manifest.layers`.
    var layerPixels: [Data]
    /// Composite thumbnail (opaque RGBA8) — written as thumb.png.
    var thumbnail: CGImage?

    // MARK: Save / load

    func save(to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        let layersDir = url.appendingPathComponent("layers")
        // Rewrite the layers dir atomically-ish: write new, then prune stale files.
        try fm.createDirectory(at: layersDir, withIntermediateDirectories: true)

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(manifest).write(to: url.appendingPathComponent("manifest.json"))

        var kept = Set<String>()
        for (entry, pixels) in zip(manifest.layers, layerPixels) {
            kept.insert(entry.file)
            let dst = layersDir.appendingPathComponent(entry.file)
            guard let image = Self.image(fromPremultipliedRGBA: pixels,
                                         width: manifest.width, height: manifest.height) else {
                throw DocumentError.encodeFailed
            }
            try Self.writePNG(image, to: dst)
        }
        // Prune files from deleted layers.
        if let existing = try? fm.contentsOfDirectory(atPath: layersDir.path) {
            for file in existing where !kept.contains(file) {
                try? fm.removeItem(at: layersDir.appendingPathComponent(file))
            }
        }
        if let thumbnail {
            try Self.writePNG(thumbnail, to: url.appendingPathComponent("thumb.png"))
        }
    }

    static func load(from url: URL) throws -> ArtworkDocument {
        let manifestData = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        var pixels: [Data] = []
        for entry in manifest.layers {
            let png = url.appendingPathComponent("layers").appendingPathComponent(entry.file)
            guard let src = CGImageSourceCreateWithURL(png as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let data = premultipliedRGBA(from: image, width: manifest.width, height: manifest.height)
            else { throw DocumentError.decodeFailed }
            pixels.append(data)
        }
        return ArtworkDocument(manifest: manifest, layerPixels: pixels, thumbnail: nil)
    }

    // MARK: Pixel ↔ CGImage

    /// Wraps premultiplied RGBA8 bytes (as read from an MTLTexture) in a CGImage.
    static func image(fromPremultipliedRGBA data: Data, width: Int, height: Int) -> CGImage? {
        guard data.count >= width * height * 4,
              let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    /// Renders any CGImage into premultiplied RGBA8 bytes at the given size (document → texture).
    static func premultipliedRGBA(from image: CGImage, width: Int, height: Int) -> Data? {
        var data = Data(count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw DocumentError.encodeFailed }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw DocumentError.encodeFailed }
    }
}

enum DocumentError: Error {
    case encodeFailed, decodeFailed
}
