import Foundation
import CoreGraphics

/// CPU scanline flood fill over premultiplied RGBA8 pixel data.
/// Pure and deterministic — unit-tested (Phase 3 test list).
enum FloodFill {
    struct Result {
        var mask: [Bool]        // width*height, true = filled
        var bounds: CGRect      // tight pixel bounds of the mask
    }

    /// Region-grows from `start`, accepting pixels whose RGBA distance to the start pixel is within
    /// `tolerance` (0…255 per channel, compared premultiplied). `gapClosing` dilates the result by
    /// that many pixels afterwards so fills tuck under anti-aliased stroke edges.
    static func fill(pixels: Data, width: Int, height: Int,
                     startX: Int, startY: Int,
                     tolerance: Int, gapClosing: Int = 1) -> Result? {
        guard width > 0, height > 0,
              (0..<width).contains(startX), (0..<height).contains(startY),
              pixels.count >= width * height * 4 else { return nil }

        let tol2 = tolerance * tolerance * 4   // squared distance over 4 channels

        return pixels.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Result? in
            let px = raw.bindMemory(to: UInt8.self).baseAddress!
            let startIdx = (startY * width + startX) * 4
            let r0 = Int(px[startIdx]), g0 = Int(px[startIdx + 1])
            let b0 = Int(px[startIdx + 2]), a0 = Int(px[startIdx + 3])

            @inline(__always) func matches(_ i: Int) -> Bool {
                let o = i * 4
                let dr = Int(px[o]) - r0, dg = Int(px[o + 1]) - g0
                let db = Int(px[o + 2]) - b0, da = Int(px[o + 3]) - a0
                return dr * dr + dg * dg + db * db + da * da <= tol2
            }

            var mask = [Bool](repeating: false, count: width * height)
            var minX = startX, maxX = startX, minY = startY, maxY = startY
            // Scanline BFS: each queue entry is a filled seed; expand its full horizontal run,
            // then seed the rows above/below.
            var queue: [(x: Int, y: Int)] = [(startX, startY)]
            mask[startY * width + startX] = true

            while let (sx, sy) = queue.popLast() {
                let rowBase = sy * width
                // Expand left/right from the seed.
                var left = sx
                while left > 0, !mask[rowBase + left - 1], matches(rowBase + left - 1) {
                    left -= 1
                    mask[rowBase + left] = true
                }
                var right = sx
                while right < width - 1, !mask[rowBase + right + 1], matches(rowBase + right + 1) {
                    right += 1
                    mask[rowBase + right] = true
                }
                minX = min(minX, left); maxX = max(maxX, right)
                minY = min(minY, sy); maxY = max(maxY, sy)
                // Seed neighbours in adjacent rows.
                for ny in [sy - 1, sy + 1] where ny >= 0 && ny < height {
                    let nBase = ny * width
                    var x = left
                    while x <= right {
                        if !mask[nBase + x], matches(nBase + x) {
                            mask[nBase + x] = true
                            queue.append((x, ny))
                            // Skip the rest of this run; the seed expands it.
                            while x + 1 <= right, !mask[nBase + x + 1], matches(nBase + x + 1) {
                                x += 1
                                mask[nBase + x] = true
                            }
                        }
                        x += 1
                    }
                }
            }

            // Gap closing: dilate so the fill slides under anti-aliased edges.
            for _ in 0..<max(0, gapClosing) {
                var grown = mask
                for y in 0..<height {
                    for x in 0..<width where !mask[y * width + x] {
                        let i = y * width + x
                        if (x > 0 && mask[i - 1]) || (x < width - 1 && mask[i + 1])
                            || (y > 0 && mask[i - width]) || (y < height - 1 && mask[i + width]) {
                            grown[i] = true
                        }
                    }
                }
                mask = grown
                minX = max(0, minX - 1); maxX = min(width - 1, maxX + 1)
                minY = max(0, minY - 1); maxY = min(height - 1, maxY + 1)
            }

            return Result(mask: mask,
                          bounds: CGRect(x: minX, y: minY,
                                         width: maxX - minX + 1, height: maxY - minY + 1))
        }
    }

    /// Renders a fill mask into premultiplied RGBA8 bytes for the mask's bounds rect.
    /// `pattern` indexes `FillPattern`; `.solid` fills every masked pixel.
    static func render(result: Result, width: Int, color: PaintColor,
                       pattern: FillPattern = .solid) -> Data {
        let bx = Int(result.bounds.minX), by = Int(result.bounds.minY)
        let bw = Int(result.bounds.width), bh = Int(result.bounds.height)
        var out = Data(count: bw * bh * 4)
        let pr = UInt8(max(0, min(255, color.r * color.a * 255)))
        let pg = UInt8(max(0, min(255, color.g * color.a * 255)))
        let pb = UInt8(max(0, min(255, color.b * color.a * 255)))
        let pa = UInt8(max(0, min(255, color.a * 255)))
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<bh {
                for x in 0..<bw where result.mask[(by + y) * width + (bx + x)] {
                    guard pattern.covers(x: bx + x, y: by + y) else { continue }
                    let o = (y * bw + x) * 4
                    dst[o] = pr; dst[o + 1] = pg; dst[o + 2] = pb; dst[o + 3] = pa
                }
            }
        }
        return out
    }
}

/// Procedural seamless fill patterns (original, generated — no bundled artwork).
enum FillPattern: String, CaseIterable, Identifiable {
    case solid, dots, stripes, crosshatch, checker

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .solid: "Solid"
        case .dots: "Dots"
        case .stripes: "Stripes"
        case .crosshatch: "Crosshatch"
        case .checker: "Checker"
        }
    }

    /// Whether the pattern deposits pigment at canvas pixel (x, y).
    func covers(x: Int, y: Int) -> Bool {
        switch self {
        case .solid:
            return true
        case .dots:
            let cx = x % 18 - 9, cy = y % 18 - 9
            return cx * cx + cy * cy <= 16
        case .stripes:
            return (x + y) % 16 < 6
        case .crosshatch:
            return (x + y) % 14 < 3 || (x - y + 14000) % 14 < 3
        case .checker:
            return ((x / 14) + (y / 14)) % 2 == 0
        }
    }
}
