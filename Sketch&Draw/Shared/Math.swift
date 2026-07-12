import CoreGraphics
import simd

/// Canvas coordinate space is **pixels**, y-down, origin top-left — matching the layer `MTLTexture`.
/// The view/screen space is UIKit points, y-down, origin top-left.
///
/// `CanvasTransform` maps canvas pixels → view points:  `view = offset + scale * canvasPx`
/// Rotation is reserved for Phase 5 (two-finger rotate); kept at 0 in Phase 1.
struct CanvasTransform: Equatable {
    var offset: CGPoint = .zero      // view points
    var scale: CGFloat = 1           // canvas px → view points
    var rotation: CGFloat = 0        // radians (reserved)

    func canvasToView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: offset.x + scale * p.x, y: offset.y + scale * p.y)
    }

    func viewToCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale)
    }

    /// Scale + translate so a `canvasSize` canvas is centered and fits within `viewSize` (with margin).
    static func fitting(canvasSize: CGSize, in viewSize: CGSize, margin: CGFloat = 24) -> CanvasTransform {
        guard canvasSize.width > 0, canvasSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return CanvasTransform() }
        let avail = CGSize(width: max(1, viewSize.width - margin * 2),
                           height: max(1, viewSize.height - margin * 2))
        let s = min(avail.width / canvasSize.width, avail.height / canvasSize.height)
        let drawn = CGSize(width: canvasSize.width * s, height: canvasSize.height * s)
        let offset = CGPoint(x: (viewSize.width - drawn.width) / 2,
                             y: (viewSize.height - drawn.height) / 2)
        return CanvasTransform(offset: offset, scale: s, rotation: 0)
    }

    /// MVP that maps a canvas-pixel position → clip space of a drawable of size `viewSize` (points·scaleFactor
    /// cancels out because we work in points and the ortho uses the same units). Canvas y=0 → top of screen.
    func mvp(viewSize: CGSize) -> simd_float4x4 {
        let w = Float(viewSize.width), h = Float(viewSize.height)
        let s = Float(scale)
        let ox = Float(offset.x), oy = Float(offset.y)
        // view = offset + s*canvasPx ; clip.x = 2*view.x/w - 1 ; clip.y = 1 - 2*view.y/h
        let ax = 2 * s / w
        let bx = 2 * ox / w - 1
        let ay = -2 * s / h
        let by = 1 - 2 * oy / h
        // column-major
        return simd_float4x4(columns: (
            SIMD4<Float>(ax, 0,  0, 0),
            SIMD4<Float>(0,  ay, 0, 0),
            SIMD4<Float>(0,  0,  1, 0),
            SIMD4<Float>(bx, by, 0, 1)
        ))
    }
}

/// Orthographic matrix mapping canvas-pixel coords → clip space of a render target of `size` pixels,
/// with canvas y=0 mapped to the **top** row (clip +1). Used by the stamp pass.
func canvasOrtho(size: CGSize) -> simd_float4x4 {
    let w = Float(size.width), h = Float(size.height)
    let ax = 2 / w
    let bx: Float = -1
    let ay = -2 / h
    let by: Float = 1
    return simd_float4x4(columns: (
        SIMD4<Float>(ax, 0,  0, 0),
        SIMD4<Float>(0,  ay, 0, 0),
        SIMD4<Float>(0,  0,  1, 0),
        SIMD4<Float>(bx, by, 0, 1)
    ))
}

extension CGPoint {
    func distance(to o: CGPoint) -> CGFloat { hypot(x - o.x, y - o.y) }
}

@inline(__always) func clampf(_ v: Float, _ lo: Float, _ hi: Float) -> Float { min(max(v, lo), hi) }
