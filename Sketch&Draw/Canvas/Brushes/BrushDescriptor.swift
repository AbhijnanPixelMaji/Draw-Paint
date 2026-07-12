import CoreGraphics
import simd

/// How stamps composite within a single stroke.
/// - `buildup`: stamps accumulate in the stroke scratch (pencil, ink); merged into the layer at 100%.
/// - `flat`: stamps max-blend in the scratch so overlap inside one stroke never darkens (marker);
///   merged into the layer at `strokeOpacity`, so *separate* strokes do darken each other.
enum StrokeCompositing: String, Codable {
    case buildup
    case flat
}

/// Which rendering path a brush takes through the engine.
enum BrushMedium: String, Codable {
    case standard     // stamp → stroke scratch → merge (pencil, ink, marker, acrylic, airbrush)
    case watercolor   // stamp → persistent wet buffer (diffusion + edge darkening + dry)
    case smudge       // pickup + restamp directly on the layer (pulls existing pixels)
    case eraser       // destination-out stamps directly on the layer (pressure-sensitive)
}

/// The stamp mask geometry.
enum StampShape: String, Codable {
    case round        // radial falloff controlled by hardness
    case bristle      // column of bristle dots; rotated along stroke direction → streaks
}

/// A simple parametric response curve: `out = minValue + (1 - minValue) * pow(input, gamma)`.
struct ResponseCurve: Equatable, Codable {
    var minValue: CGFloat   // output at input 0
    var gamma: CGFloat      // 1 = linear, >1 = soft start, <1 = fast start

    func apply(_ t: CGFloat) -> CGFloat {
        let x = max(0, min(1, t))
        return minValue + (1 - minValue) * pow(x, gamma)
    }

    static let linear = ResponseCurve(minValue: 0, gamma: 1)
    static let constant = ResponseCurve(minValue: 1, gamma: 1)
}

/// Generalized stamp-brush description. Custom user brushes (Phase 5) serialize this via Codable.
struct BrushDescriptor: Equatable, Codable {
    var name: String = "Brush"
    /// Tool family this brush belongs to (groups variants in the rack panel).
    var family: String = "Custom"

    // Geometry
    var baseRadius: CGFloat = 14        // canvas px at full pressure
    var spacing: CGFloat = 0.12         // fraction of diameter between stamps
    var hardness: CGFloat = 0.85        // stamp edge falloff (0 soft … 1 hard)
    var scatter: CGFloat = 0            // positional jitter as fraction of radius
    var randomRotation: Bool = false    // random stamp angle (breaks up grain repetition)

    // Ink & opacity
    var flow: CGFloat = 1.0             // per-stamp alpha multiplier
    var strokeOpacity: CGFloat = 1.0    // merge opacity (flat mode)
    var compositing: StrokeCompositing = .buildup

    // Dynamics
    var sizeCurve: ResponseCurve = ResponseCurve(minValue: 0.25, gamma: 1)
    var opacityCurve: ResponseCurve = .constant
    var velocityThinning: CGFloat = 0   // 0…1 — how much high speed thins the stroke (ink)
    var stabilization: CGFloat = 0.3    // 0…1 — input smoothing strength (exposed toolbar control)
    var tiltWidening: CGFloat = 0       // 0…1 — how much low altitude (tilted pencil) widens the stamp
    var tiltFading: CGFloat = 0         // 0…1 — how much tilt lowers opacity (graphite shading)

    // Texture
    var usesGrain: Bool = false         // multiply paper-grain into the stamp coverage
    var grainScale: CGFloat = 220       // canvas px per grain-texture repeat
    var grainAmount: CGFloat = 0.8      // 0…1 grain contrast

    // Medium / shape (Phase 4)
    var medium: BrushMedium = .standard
    var shape: StampShape = .round
    var directionalRotation: Bool = false   // rotate stamp along stroke direction (acrylic bristles)
    var dwellBuildup: Bool = false          // keep depositing while the touch dwells (airbrush)
    var smudgeStrength: CGFloat = 0.85      // pickup alpha for the smudge tool

    // MARK: Derived per-sample values

    func radius(pressure: CGFloat, velocityNorm: CGFloat, tilt: CGFloat) -> CGFloat {
        var r = baseRadius * sizeCurve.apply(pressure)
        r *= 1 - velocityThinning * 0.65 * max(0, min(1, velocityNorm))
        r *= 1 + tiltWidening * 1.6 * max(0, min(1, tilt))
        return max(0.5, r)
    }

    func alpha(pressure: CGFloat, tilt: CGFloat) -> CGFloat {
        var a = flow * opacityCurve.apply(pressure)
        a *= 1 - tiltFading * 0.6 * max(0, min(1, tilt))
        return max(0, min(1, a))
    }
}

// MARK: - Presets

extension BrushDescriptor {
    /// Hard graphite: grainy, pressure-driven opacity, tilt widens + fades (side-of-lead shading).
    static let pencil = BrushDescriptor(
        name: "Hard Graphite", family: "Pencil",
        baseRadius: 6, spacing: 0.08, hardness: 0.55, scatter: 0.08, randomRotation: true,
        flow: 0.45, strokeOpacity: 1, compositing: .buildup,
        sizeCurve: ResponseCurve(minValue: 0.55, gamma: 1.2),
        opacityCurve: ResponseCurve(minValue: 0.25, gamma: 1.4),
        velocityThinning: 0, stabilization: 0.25,
        tiltWidening: 0.9, tiltFading: 0.7,
        usesGrain: true, grainScale: 140, grainAmount: 0.85)

    /// Fineliner: crisp, velocity-thinned, heavily stabilized.
    static let ink = BrushDescriptor(
        name: "Fineliner", family: "Ink",
        baseRadius: 5, spacing: 0.05, hardness: 0.92, scatter: 0, randomRotation: false,
        flow: 1, strokeOpacity: 1, compositing: .buildup,
        sizeCurve: ResponseCurve(minValue: 0.6, gamma: 1),
        opacityCurve: .constant,
        velocityThinning: 0.75, stabilization: 0.6,
        tiltWidening: 0, tiltFading: 0,
        usesGrain: false)

    /// Felt marker: wide, semi-transparent, flat within a stroke, darkens across strokes.
    static let marker = BrushDescriptor(
        name: "Felt Marker", family: "Marker",
        baseRadius: 22, spacing: 0.08, hardness: 0.6, scatter: 0, randomRotation: false,
        flow: 1, strokeOpacity: 0.5, compositing: .flat,
        sizeCurve: ResponseCurve(minValue: 0.85, gamma: 1),
        opacityCurve: .constant,
        velocityThinning: 0, stabilization: 0.35,
        tiltWidening: 0, tiltFading: 0,
        usesGrain: false)

    /// Round watercolor: soft stamps into the wet buffer; diffusion + edge darkening + blooms on overlap.
    static let watercolor = BrushDescriptor(
        name: "Round Wash", family: "Watercolor",
        baseRadius: 26, spacing: 0.15, hardness: 0.12, scatter: 0.05, randomRotation: false,
        flow: 0.16, strokeOpacity: 1, compositing: .buildup,
        sizeCurve: ResponseCurve(minValue: 0.7, gamma: 1),
        opacityCurve: ResponseCurve(minValue: 0.5, gamma: 1.2),
        velocityThinning: 0, stabilization: 0.35,
        tiltWidening: 0.3, tiltFading: 0,
        usesGrain: true, grainScale: 260, grainAmount: 0.35,
        medium: .watercolor)

    /// Acrylic flat brush: bristle streaks along the stroke direction, dense pigment.
    static let acrylic = BrushDescriptor(
        name: "Flat Bristle", family: "Acrylic",
        baseRadius: 18, spacing: 0.06, hardness: 0.7, scatter: 0, randomRotation: false,
        flow: 0.9, strokeOpacity: 1, compositing: .buildup,
        sizeCurve: ResponseCurve(minValue: 0.75, gamma: 1),
        opacityCurve: ResponseCurve(minValue: 0.7, gamma: 1),
        velocityThinning: 0, stabilization: 0.3,
        tiltWidening: 0, tiltFading: 0,
        usesGrain: true, grainScale: 90, grainAmount: 0.25,
        medium: .standard, shape: .bristle, directionalRotation: true)

    /// Airbrush: very soft falloff, gentle flow, keeps depositing while held in place.
    static let airbrush = BrushDescriptor(
        name: "Soft Spray", family: "Airbrush",
        baseRadius: 44, spacing: 0.12, hardness: 0.03, scatter: 0, randomRotation: false,
        flow: 0.06, strokeOpacity: 1, compositing: .buildup,
        sizeCurve: ResponseCurve(minValue: 0.6, gamma: 1),
        opacityCurve: ResponseCurve(minValue: 0.3, gamma: 1.5),
        velocityThinning: 0, stabilization: 0.2,
        tiltWidening: 0, tiltFading: 0,
        usesGrain: false,
        medium: .standard, dwellBuildup: true)

    /// Smudge: pulls existing layer pixels along the stroke. Color is ignored.
    static let smudge = BrushDescriptor(
        name: "Blender", family: "Smudge",
        baseRadius: 20, spacing: 0.22, hardness: 0.25, scatter: 0, randomRotation: false,
        flow: 1, strokeOpacity: 1, compositing: .buildup,
        sizeCurve: ResponseCurve(minValue: 0.8, gamma: 1),
        opacityCurve: .constant,
        velocityThinning: 0, stabilization: 0.4,
        tiltWidening: 0, tiltFading: 0,
        usesGrain: false,
        medium: .smudge, smudgeStrength: 0.85)

    /// Soft graphite: wider, darker, heavier grain.
    static let softPencil = BrushDescriptor(
        name: "Soft Graphite", family: "Pencil",
        baseRadius: 10, spacing: 0.09, hardness: 0.35, scatter: 0.12, randomRotation: true,
        flow: 0.6, strokeOpacity: 1, compositing: .buildup,
        sizeCurve: ResponseCurve(minValue: 0.5, gamma: 1.1),
        opacityCurve: ResponseCurve(minValue: 0.3, gamma: 1.2),
        velocityThinning: 0, stabilization: 0.25,
        tiltWidening: 1, tiltFading: 0.75,
        usesGrain: true, grainScale: 150, grainAmount: 0.9)

    /// Brush pen: ink that swells hard with pressure.
    static let brushPen = BrushDescriptor(
        name: "Brush Pen", family: "Ink",
        baseRadius: 11, spacing: 0.05, hardness: 0.85, scatter: 0, randomRotation: false,
        flow: 1, strokeOpacity: 1, compositing: .buildup,
        sizeCurve: ResponseCurve(minValue: 0.15, gamma: 1.6),
        opacityCurve: .constant,
        velocityThinning: 0.35, stabilization: 0.5,
        tiltWidening: 0, tiltFading: 0,
        usesGrain: false)

    /// Felt tip: narrower marker for writing.
    static let feltTip = BrushDescriptor(
        name: "Felt Tip", family: "Marker",
        baseRadius: 9, spacing: 0.07, hardness: 0.75, scatter: 0, randomRotation: false,
        flow: 1, strokeOpacity: 0.85, compositing: .flat,
        sizeCurve: ResponseCurve(minValue: 0.9, gamma: 1),
        opacityCurve: .constant,
        velocityThinning: 0.15, stabilization: 0.35,
        tiltWidening: 0, tiltFading: 0,
        usesGrain: false)

    /// Oil pastel: thick, waxy, heavy grain, near-opaque buildup.
    static let pastel = BrushDescriptor(
        name: "Oil Pastel", family: "Pastel",
        baseRadius: 16, spacing: 0.07, hardness: 0.45, scatter: 0.15, randomRotation: true,
        flow: 0.85, strokeOpacity: 1, compositing: .buildup,
        sizeCurve: ResponseCurve(minValue: 0.8, gamma: 1),
        opacityCurve: ResponseCurve(minValue: 0.6, gamma: 1.2),
        velocityThinning: 0, stabilization: 0.2,
        tiltWidening: 0.4, tiltFading: 0.3,
        usesGrain: true, grainScale: 110, grainAmount: 0.75)

    /// Wide flat wash.
    static let flatWash = BrushDescriptor(
        name: "Flat Wash", family: "Watercolor",
        baseRadius: 44, spacing: 0.18, hardness: 0.08, scatter: 0.03, randomRotation: false,
        flow: 0.12, strokeOpacity: 1, compositing: .buildup,
        sizeCurve: ResponseCurve(minValue: 0.85, gamma: 1),
        opacityCurve: ResponseCurve(minValue: 0.6, gamma: 1),
        velocityThinning: 0, stabilization: 0.4,
        tiltWidening: 0.2, tiltFading: 0,
        usesGrain: true, grainScale: 260, grainAmount: 0.3,
        medium: .watercolor)

    /// Pressure-sensitive eraser (destination-out).
    static let eraser = BrushDescriptor(
        name: "Eraser", family: "Eraser",
        baseRadius: 18, spacing: 0.08, hardness: 0.7, scatter: 0, randomRotation: false,
        flow: 1, strokeOpacity: 1, compositing: .buildup,
        sizeCurve: ResponseCurve(minValue: 0.4, gamma: 1),
        opacityCurve: .constant,
        velocityThinning: 0, stabilization: 0.2,
        tiltWidening: 0, tiltFading: 0,
        usesGrain: false,
        medium: .eraser)

    /// Precision eraser tip.
    static let eraserPrecise = BrushDescriptor(
        name: "Precision Tip", family: "Eraser",
        baseRadius: 5, spacing: 0.06, hardness: 0.95, scatter: 0, randomRotation: false,
        flow: 1, strokeOpacity: 1, compositing: .buildup,
        sizeCurve: ResponseCurve(minValue: 0.6, gamma: 1),
        opacityCurve: .constant,
        velocityThinning: 0, stabilization: 0.4,
        tiltWidening: 0, tiltFading: 0,
        usesGrain: false,
        medium: .eraser)

    static let phase2Presets: [BrushDescriptor] = [.pencil, .ink, .marker]
    static let allPresets: [BrushDescriptor] = [.pencil, .ink, .marker, .watercolor, .acrylic, .airbrush, .smudge]

    /// Built-in variants per family, shown in the variants panel (customs are appended by BrushLibrary).
    static let familyVariants: [String: [BrushDescriptor]] = [
        "Pencil": [.pencil, .softPencil],
        "Ink": [.ink, .brushPen],
        "Marker": [.marker, .feltTip],
        "Pastel": [.pastel],
        "Acrylic": [.acrylic],
        "Watercolor": [.watercolor, .flatWash],
        "Airbrush": [.airbrush],
        "Smudge": [.smudge],
        "Eraser": [.eraser, .eraserPrecise],
    ]
}

/// RGBA color in straight (non-premultiplied) form, 0…1.
struct PaintColor: Equatable, Codable {
    var r: Float, g: Float, b: Float, a: Float
    var simd: SIMD4<Float> { SIMD4(r, g, b, a) }
    static let black = PaintColor(r: 0.1, g: 0.1, b: 0.12, a: 1)
    static let blue = PaintColor(r: 0.16, g: 0.32, b: 0.75, a: 1)
    static let red = PaintColor(r: 0.82, g: 0.18, b: 0.19, a: 1)
    static let green = PaintColor(r: 0.16, g: 0.55, b: 0.3, a: 1)
}
