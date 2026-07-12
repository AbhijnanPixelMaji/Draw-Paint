import CoreGraphics

/// A fully-resolved stamp request: canvas position + the radius/alpha the engine computed for the
/// input sample it came from (interpolated between samples during tessellation).
struct StampPoint {
    var position: CGPoint
    var radius: CGFloat
    var alpha: CGFloat
}

/// Turns raw (already canvas-space) input samples into evenly spaced stamp points:
/// 1. **Stabilizer** — exponential follow toward the raw point (strength 0…1).
/// 2. **Catmull-Rom** — smoothed control points are tessellated into a curve (segment p1→p2 of each
///    sliding 4-point window, so emission lags one sample; `finish()` flushes the tail).
/// 3. **Arc-length spacing** — stamps are laid every `spacing×diameter`, carrying leftover distance
///    across segments so density is velocity-independent.
@MainActor
final class StrokeBuilder {
    private var stabilization: CGFloat
    private var spacingFraction: CGFloat

    private var smoothed = CGPoint.zero
    private var control: [StampPoint] = []
    private var leftover: CGFloat = 0

    init(stabilization: CGFloat, spacingFraction: CGFloat) {
        self.stabilization = max(0, min(1, stabilization))
        self.spacingFraction = spacingFraction
    }

    func begin(_ p: StampPoint) -> [StampPoint] {
        smoothed = p.position
        control = [p, p]           // duplicated head anchors the start tangent
        leftover = spacing(for: p.radius)   // the begin stamp itself covers position 0
        return [p]
    }

    func add(_ raw: StampPoint) -> [StampPoint] {
        // Stabilize: high stabilization → the emitted point trails the raw input.
        let k = 1 - 0.93 * stabilization
        smoothed.x += (raw.position.x - smoothed.x) * k
        smoothed.y += (raw.position.y - smoothed.y) * k
        let pt = StampPoint(position: smoothed, radius: raw.radius, alpha: raw.alpha)
        control.append(pt)
        let n = control.count
        guard n >= 4 else { return [] }
        return tessellate(control[n - 4], control[n - 3], control[n - 2], control[n - 1])
    }

    /// Flushes the trailing segment (Catmull-Rom emission lags one control point).
    func finish() -> [StampPoint] {
        let n = control.count
        guard n >= 3 else { return [] }
        let last = control[n - 1]
        control.append(last)       // duplicated tail anchors the end tangent
        return tessellate(control[n - 3], control[n - 2], control[n - 1], last)
    }

    private func spacing(for radius: CGFloat) -> CGFloat {
        max(0.75, spacingFraction * radius * 2)
    }

    /// Emits stamps along the Catmull-Rom segment p1→p2.
    private func tessellate(_ p0: StampPoint, _ p1: StampPoint, _ p2: StampPoint, _ p3: StampPoint) -> [StampPoint] {
        let chord = p1.position.distance(to: p2.position)
        guard chord > 0.01 else { return [] }
        var out: [StampPoint] = []
        let subdivisions = max(4, Int(chord / 1.5))
        var prev = p1.position
        for i in 1...subdivisions {
            let t = CGFloat(i) / CGFloat(subdivisions)
            let pos = catmullRom(p0.position, p1.position, p2.position, p3.position, t)
            var segLen = prev.distance(to: pos)
            // Walk this sub-segment placing stamps every `spacing` px.
            while leftover <= segLen {
                let f = segLen > 0 ? leftover / segLen : 0
                let stampPos = CGPoint(x: prev.x + (pos.x - prev.x) * f,
                                       y: prev.y + (pos.y - prev.y) * f)
                let radius = p1.radius + (p2.radius - p1.radius) * t
                let alpha = p1.alpha + (p2.alpha - p1.alpha) * t
                out.append(StampPoint(position: stampPos, radius: radius, alpha: alpha))
                segLen -= leftover
                prev = stampPos
                leftover = spacing(for: radius)
            }
            leftover -= segLen
            prev = pos
        }
        return out
    }

    private func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let t2 = t * t, t3 = t2 * t
        func axis(_ a0: CGFloat, _ a1: CGFloat, _ a2: CGFloat, _ a3: CGFloat) -> CGFloat {
            0.5 * ((2 * a1)
                   + (-a0 + a2) * t
                   + (2 * a0 - 5 * a1 + 4 * a2 - a3) * t2
                   + (-a0 + 3 * a1 - 3 * a2 + a3) * t3)
        }
        return CGPoint(x: axis(p0.x, p1.x, p2.x, p3.x), y: axis(p0.y, p1.y, p2.y, p3.y))
    }
}
