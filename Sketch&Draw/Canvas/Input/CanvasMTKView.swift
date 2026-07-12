import MetalKit
import UIKit

/// `MTKView` subclass that captures drawing touches (Pencil or single finger) and forwards them to the engine.
/// Two-finger pan/zoom is handled by gesture recognizers wired up in `CanvasView`.
final class CanvasMTKView: MTKView {
    weak var engine: CanvasEngine?

    /// The touch currently drawing a stroke (nil when idle or when a multi-touch gesture owns the view).
    private var drawingTouch: UITouch?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        isMultipleTouchEnabled = true
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not used") }

    private func sample(from touch: UITouch) -> InputSample {
        let maxForce = touch.maximumPossibleForce
        let pressure: CGFloat
        if touch.type == .pencil || maxForce > 0 {
            pressure = maxForce > 0 ? min(1, touch.force / maxForce) : 0.5
        } else {
            pressure = 0.5   // finger without force sensing
        }
        let altitude = touch.type == .pencil ? touch.altitudeAngle : .pi / 2
        return InputSample(viewPoint: touch.location(in: self),
                           pressure: pressure,
                           altitude: altitude,
                           timestamp: touch.timestamp)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Only start drawing on a lone touch; if more fingers are down, let pan/zoom take over.
        let active = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? touches
        guard drawingTouch == nil, active.count == 1, let touch = touches.first else {
            cancelDrawing()
            return
        }
        drawingTouch = touch
        engine?.strokeBegan(sample(from: touch))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        // Coalesced touches give full-fidelity intermediate samples between frame callbacks.
        let samples = event?.coalescedTouches(for: touch) ?? [touch]
        for s in samples {
            engine?.strokeMoved(sample(from: s))
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        engine?.strokeMoved(sample(from: touch))
        engine?.strokeEnded()
        drawingTouch = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        cancelDrawing()
    }

    /// Ends any in-progress stroke (e.g. when a second finger lands to pan/zoom).
    func cancelDrawing() {
        if drawingTouch != nil {
            engine?.strokeEnded()
            drawingTouch = nil
        }
    }
}
