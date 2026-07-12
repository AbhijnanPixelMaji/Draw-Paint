import Metal
import CoreGraphics

/// Builds brush stamp masks and the shared paper-grain texture (grayscale coverage in .r).
enum StampFactory {
    /// Radial falloff whose edge sharpness is controlled by `hardness`.
    static func makeRoundStamp(context: MetalContext, size: Int = 256, hardness: CGFloat) throws -> MTLTexture {
        var pixels = [UInt8](repeating: 0, count: size * size)
        let c = Float(size - 1) / 2
        let r = Float(size) / 2
        let inner = r * Float(max(0, min(0.999, hardness)))
        for y in 0..<size {
            for x in 0..<size {
                let dx = Float(x) - c
                let dy = Float(y) - c
                let d = (dx * dx + dy * dy).squareRoot()
                let cover: Float
                if d <= inner {
                    cover = 1
                } else if d >= r {
                    cover = 0
                } else {
                    let t = (d - inner) / max(0.0001, (r - inner))
                    cover = 1 - (t * t * (3 - 2 * t))   // smoothstep edge
                }
                pixels[y * size + x] = UInt8(max(0, min(1, cover)) * 255)
            }
        }
        return try makeR8Texture(context: context, pixels: pixels, size: size)
    }

    /// A column of bristle dots. Stamped with `directionalRotation`, consecutive overlapping stamps
    /// trace parallel streaks along the stroke — the acrylic flat-brush look.
    static func makeBristleStamp(context: MetalContext, size: Int = 256, seed: UInt64 = 0xB5297A4D) throws -> MTLTexture {
        var pixels = [Float](repeating: 0, count: size * size)
        var state = seed
        func next() -> Float {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Float(z & 0xFFFFFF) / Float(0xFFFFFF)
        }
        let bristles = 16
        let cx = Float(size) / 2
        for i in 0..<bristles {
            // Bristles spread across the stamp's vertical axis with jitter.
            let fy = (Float(i) + 0.5) / Float(bristles)
            let by = fy * Float(size) * 0.9 + Float(size) * 0.05 + (next() - 0.5) * 8
            let bx = cx + (next() - 0.5) * Float(size) * 0.25
            let radius = (0.02 + next() * 0.045) * Float(size)
            let strength = 0.45 + next() * 0.55
            let minY = max(0, Int(by - radius - 1)), maxY = min(size - 1, Int(by + radius + 1))
            let minX = max(0, Int(bx - radius - 1)), maxX = min(size - 1, Int(bx + radius + 1))
            guard minY <= maxY, minX <= maxX else { continue }
            for y in minY...maxY {
                for x in minX...maxX {
                    let dx = Float(x) - bx, dy = Float(y) - by
                    let d = (dx * dx + dy * dy).squareRoot()
                    guard d < radius else { continue }
                    let t = d / radius
                    let cover = strength * (1 - t * t * (3 - 2 * t))
                    let idx = y * size + x
                    pixels[idx] = max(pixels[idx], cover)
                }
            }
        }
        let bytes = pixels.map { UInt8(max(0, min(1, $0)) * 255) }
        return try makeR8Texture(context: context, pixels: bytes, size: size)
    }

    /// Tileable multi-octave value noise — the paper tooth. Sampled canvas-anchored with repeat addressing.
    static func makePaperGrain(context: MetalContext, size: Int = 256, seed: UInt64 = 0x9E3779B97F4A7C15) throws -> MTLTexture {
        // Deterministic PRNG (splitmix64) so grain is stable across launches.
        var state = seed
        func next() -> Float {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Float(z & 0xFFFFFF) / Float(0xFFFFFF)
        }

        // Tileable value noise at one lattice resolution.
        func noiseLayer(cells: Int) -> [Float] {
            var lattice = [Float](repeating: 0, count: cells * cells)
            for i in 0..<lattice.count { lattice[i] = next() }
            var out = [Float](repeating: 0, count: size * size)
            let step = Float(size) / Float(cells)
            for y in 0..<size {
                for x in 0..<size {
                    let fx = Float(x) / step, fy = Float(y) / step
                    let x0 = Int(fx) % cells, y0 = Int(fy) % cells
                    let x1 = (x0 + 1) % cells, y1 = (y0 + 1) % cells
                    let tx = fx - Float(Int(fx)), ty = fy - Float(Int(fy))
                    let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
                    let a = lattice[y0 * cells + x0], b = lattice[y0 * cells + x1]
                    let c = lattice[y1 * cells + x0], d = lattice[y1 * cells + x1]
                    out[y * size + x] = (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
                }
            }
            return out
        }

        let coarse = noiseLayer(cells: 24)
        let mid = noiseLayer(cells: 64)
        let fine = noiseLayer(cells: 128)
        var pixels = [UInt8](repeating: 0, count: size * size)
        for i in 0..<pixels.count {
            // Weighted octaves, biased bright so grain darkens selectively (tooth valleys).
            let v = 0.45 * coarse[i] + 0.35 * mid[i] + 0.2 * fine[i]
            let shaped = 0.35 + 0.65 * v   // keep floor above 0 so strokes never fully vanish
            pixels[i] = UInt8(max(0, min(1, shaped)) * 255)
        }
        return try makeR8Texture(context: context, pixels: pixels, size: size)
    }

    private static func makeR8Texture(context: MetalContext, pixels: [UInt8], size: Int) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = context.device.makeTexture(descriptor: desc) else {
            throw EngineError.textureFailed
        }
        pixels.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, size, size),
                        mipmapLevel: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: size)
        }
        return tex
    }
}
