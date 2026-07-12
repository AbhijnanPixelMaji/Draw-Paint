#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// Stamp pass: draws brush stamps (instanced quads) into the stroke scratch texture.
// Layouts mirror `StampInstance` / `StampUniforms` in GPUTypes.swift.
// ---------------------------------------------------------------------------
struct StampInstance {
    float2 center;   // canvas pixels
    float  radius;   // canvas pixels
    float  angle;    // stamp rotation, radians
    float4 color;    // straight rgba; a = per-stamp alpha
};

struct StampUniforms {
    int   useGrain;
    float grainAmount;
    float grainScale;
    float _pad;
};

struct StampVSOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float2 canvasPos;   // for canvas-anchored grain sampling
};

constant float2 kCorners[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
constant float2 kUV[4]      = { float2( 0, 0), float2(1, 0), float2( 0, 1), float2(1, 1) };

vertex StampVSOut stamp_vertex(uint vid                        [[vertex_id]],
                               uint iid                        [[instance_id]],
                               const device StampInstance* ins [[buffer(0)]],
                               constant float4x4& proj         [[buffer(1)]])
{
    StampInstance s = ins[iid];
    float2 c = kCorners[vid] * s.radius;
    float ca = cos(s.angle), sa = sin(s.angle);
    float2 rotated = float2(c.x * ca - c.y * sa, c.x * sa + c.y * ca);
    float2 pos = s.center + rotated;
    StampVSOut out;
    out.position  = proj * float4(pos, 0.0, 1.0);
    out.uv        = kUV[vid];
    out.color     = s.color;
    out.canvasPos = pos;
    return out;
}

fragment float4 stamp_fragment(StampVSOut in               [[stage_in]],
                               texture2d<float> mask        [[texture(0)]],
                               texture2d<float> grain       [[texture(1)]],
                               sampler maskSamp             [[sampler(0)]],
                               sampler grainSamp            [[sampler(1)]],
                               constant StampUniforms& u    [[buffer(0)]])
{
    float m = mask.sample(maskSamp, in.uv).r;    // 0..1 coverage
    if (u.useGrain != 0) {
        // Grain is anchored to the canvas (paper tooth), not the stamp.
        float g = grain.sample(grainSamp, in.canvasPos / u.grainScale).r;
        m *= mix(1.0, g, u.grainAmount);
    }
    float alpha = in.color.a * m;
    return float4(in.color.rgb * alpha, alpha);  // premultiplied
}

// ---------------------------------------------------------------------------
// Composite/merge pass: draws a texture quad (layer or stroke scratch) with an opacity.
// ---------------------------------------------------------------------------
struct BlitVertex { float2 pos; float2 uv; };
struct BlitVSOut  { float4 position [[position]]; float2 uv; };

vertex BlitVSOut blit_vertex(uint vid                    [[vertex_id]],
                             const device BlitVertex* v   [[buffer(0)]],
                             constant float4x4& mvp       [[buffer(1)]])
{
    BlitVSOut out;
    out.position = mvp * float4(v[vid].pos, 0.0, 1.0);
    out.uv       = v[vid].uv;
    return out;
}

fragment float4 blit_fragment(BlitVSOut in            [[stage_in]],
                              texture2d<float> tex      [[texture(0)]],
                              sampler samp              [[sampler(0)]],
                              constant float& opacity   [[buffer(0)]])
{
    return tex.sample(samp, in.uv) * opacity;   // premultiplied, scaled by opacity
}

// ---------------------------------------------------------------------------
// Watercolor support (Phase 4).
// ---------------------------------------------------------------------------

// Separable 9-tap gaussian used as the pigment diffusion step. `dir` selects the axis
// ((1,0) then (0,1) ping-pong), scaled by the diffusion radius in texels.
struct BlurUniforms { float2 dir; float2 texel; };

constant float kBlurWeights[5] = { 0.227027, 0.194594, 0.121621, 0.054054, 0.016216 };

fragment float4 blur_fragment(BlitVSOut in            [[stage_in]],
                              texture2d<float> tex      [[texture(0)]],
                              sampler samp              [[sampler(0)]],
                              constant BlurUniforms& u  [[buffer(0)]])
{
    float2 step = u.dir * u.texel;
    float4 acc = tex.sample(samp, in.uv) * kBlurWeights[0];
    for (int i = 1; i < 5; i++) {
        acc += tex.sample(samp, in.uv + step * float(i)) * kBlurWeights[i];
        acc += tex.sample(samp, in.uv - step * float(i)) * kBlurWeights[i];
    }
    return acc;   // premultiplied in, premultiplied out
}

// Draws the wet buffer with pigment edge darkening: where the alpha gradient is steep
// (stroke rims), the straight color is darkened — the classic dried-watercolor edge.
struct WetUniforms { float2 texel; float edgeGain; float opacity; };

fragment float4 wet_fragment(BlitVSOut in            [[stage_in]],
                             texture2d<float> tex      [[texture(0)]],
                             sampler samp              [[sampler(0)]],
                             constant WetUniforms& u   [[buffer(0)]])
{
    float4 c = tex.sample(samp, in.uv);
    if (c.a < 0.002) { return float4(0.0); }
    float aL = tex.sample(samp, in.uv - float2(u.texel.x, 0)).a;
    float aR = tex.sample(samp, in.uv + float2(u.texel.x, 0)).a;
    float aT = tex.sample(samp, in.uv - float2(0, u.texel.y)).a;
    float aB = tex.sample(samp, in.uv + float2(0, u.texel.y)).a;
    float grad = length(float2(aR - aL, aB - aT));
    float darken = 1.0 - u.edgeGain * smoothstep(0.02, 0.35, grad);
    float3 s = c.rgb / max(c.a, 0.002);          // straight color
    s *= darken;                                  // more pigment at the rim
    float a = c.a * u.opacity;
    return float4(s * a, a);                      // premultiplied source-over input
}

// Smudge stamp: draws the picked-up pixels (copied from under the previous stamp position)
// at the new position, masked by the soft brush mask. Pulls pigment along the stroke.
// Only the top-left `color.r` fraction of the pickup texture holds valid pixels (the blit
// copies a side×side region into a fixed 256² texture), so uv is rescaled before sampling.
fragment float4 smudge_fragment(StampVSOut in            [[stage_in]],
                                texture2d<float> pickup   [[texture(0)]],
                                texture2d<float> mask     [[texture(1)]],
                                sampler samp              [[sampler(0)]])
{
    float m = mask.sample(samp, in.uv).r;
    float4 c = pickup.sample(samp, in.uv * in.color.r);   // premultiplied pickup pixels
    return c * (m * in.color.a);                          // color.a carries smudge strength
}

// ---------------------------------------------------------------------------
// Layer blend pass: accum(N+1) = blend(accum(N), layer). The accumulator is always
// OPAQUE (it starts as the paper color), which keeps every formula simple:
// out = mix(base, blend(base, src), srcAlpha·layerOpacity), alpha = 1.
// `mode` indices must match `BlendMode.shaderIndex` in BlendMode.swift.
// ---------------------------------------------------------------------------
struct BlendUniforms { int mode; float opacity; float2 _pad; };

fragment float4 blend_fragment(BlitVSOut in              [[stage_in]],
                               texture2d<float> base      [[texture(0)]],
                               texture2d<float> layerTex  [[texture(1)]],
                               sampler samp               [[sampler(0)]],
                               constant BlendUniforms& u  [[buffer(0)]])
{
    float3 b = base.sample(samp, in.uv).rgb;      // opaque accumulator
    float4 l = layerTex.sample(samp, in.uv);      // premultiplied layer
    float sa = l.a * u.opacity;
    float3 s = l.a > 0.0001 ? l.rgb / l.a : float3(0.0);   // un-premultiply
    float3 blended;
    switch (u.mode) {
        case 1:  blended = b * s;                              break;  // multiply
        case 2:  blended = 1.0 - (1.0 - b) * (1.0 - s);        break;  // screen
        case 3:  blended = select(1.0 - 2.0 * (1.0 - b) * (1.0 - s),
                                  2.0 * b * s,
                                  b < 0.5);                    break;  // overlay
        default: blended = s;                                  break;  // normal
    }
    return float4(mix(b, blended, sa), 1.0);
}
