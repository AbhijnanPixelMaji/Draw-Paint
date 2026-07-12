import SwiftUI
import MetalKit

/// Bridges the Metal `CanvasMTKView` into SwiftUI and wires two-finger pan/zoom gesture recognizers.
struct CanvasView: UIViewRepresentable {
    let engine: CanvasEngine

    func makeCoordinator() -> Coordinator { Coordinator(engine: engine) }

    func makeUIView(context: Context) -> CanvasMTKView {
        let view = CanvasMTKView(frame: .zero, device: engine.ctx.device)
        view.engine = engine
        engine.configure(view)

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.delegate = context.coordinator

        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePinch(_:)))
        pinch.delegate = context.coordinator

        // A second finger landing should abort the current stroke so it doesn't smear during pan/zoom.
        pan.cancelsTouchesInView = false
        pinch.cancelsTouchesInView = false

        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)
        return view
    }

    func updateUIView(_ uiView: CanvasMTKView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let engine: CanvasEngine
        private var lastPan: CGPoint = .zero

        init(engine: CanvasEngine) { self.engine = engine }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let view = g.view as? CanvasMTKView else { return }
            switch g.state {
            case .began:
                view.cancelDrawing()
                lastPan = .zero
            case .changed:
                let t = g.translation(in: view)
                engine.pan(by: CGPoint(x: t.x - lastPan.x, y: t.y - lastPan.y))
                lastPan = t
            default:
                lastPan = .zero
            }
        }

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let view = g.view as? CanvasMTKView else { return }
            switch g.state {
            case .began:
                view.cancelDrawing()
            case .changed:
                engine.zoom(by: g.scale, around: g.location(in: view))
                g.scale = 1
            default:
                break
            }
        }
    }
}
