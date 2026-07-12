import simd

/// Per-stamp instance data. **Memory layout must match `StampInstance` in `Shaders.metal`.**
/// center@0 (8) · radius@8 (4) · angle@12 (4) · color@16 (16) → stride 32 (float4-aligned).
struct StampInstance {
    var center: SIMD2<Float>   // canvas pixels
    var radius: Float          // canvas pixels
    var angle: Float           // stamp rotation, radians
    var color: SIMD4<Float>    // straight rgba; a = per-stamp alpha
}

/// Fragment uniforms for the stamp pass. Matches `StampUniforms` in `Shaders.metal`.
struct StampUniforms {
    var useGrain: Int32 = 0
    var grainAmount: Float = 0
    var grainScale: Float = 220
    var _pad: Float = 0
}

/// One vertex of the composite quad. Matches `BlitVertex` in `Shaders.metal` (pos@0, uv@8, stride 16).
struct BlitVertex {
    var pos: SIMD2<Float>      // canvas pixels
    var uv: SIMD2<Float>
}

/// Uniforms for the layer blend pass. Matches `BlendUniforms` in `Shaders.metal`.
struct BlendUniforms {
    var mode: Int32
    var opacity: Float
    var _pad: SIMD2<Float> = .zero
}

/// Uniforms for the diffusion blur pass. Matches `BlurUniforms` in `Shaders.metal`.
struct BlurUniforms {
    var dir: SIMD2<Float>     // (1,0) horizontal, (0,1) vertical
    var texel: SIMD2<Float>   // 1/width, 1/height, scaled by diffusion radius
}

/// Uniforms for the wet composite pass. Matches `WetUniforms` in `Shaders.metal`.
struct WetUniforms {
    var texel: SIMD2<Float>
    var edgeGain: Float       // 0…1 edge-darkening strength
    var opacity: Float
}
