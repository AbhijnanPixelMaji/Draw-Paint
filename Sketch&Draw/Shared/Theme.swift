import SwiftUI

/// Drawsy visual language: warm "studio desk" neutrals around the paper, one coral accent for
/// selection/tint, and floating chrome on soft material cards. Keep every screen on this palette.
enum DrawsyTheme {
    /// Workspace color behind the paper. Must mirror the MTKView clear color set in
    /// `CanvasEngine.configure` so SwiftUI chrome and the Metal backdrop read as one surface.
    static let desk = Color(red: 0.90, green: 0.885, blue: 0.86)

    /// Single brand accent used for selected tools, sliders, and highlights.
    static let accent = Color(red: 0.93, green: 0.42, blue: 0.28)
    static let accentSoft = Color(red: 0.97, green: 0.56, blue: 0.40)

    /// Card treatment shared by the toolbar clusters, brush dock, and layers panel.
    static func card<S: InsettableShape>(_ shape: S) -> some ViewModifier {
        CardModifier(shape: shape)
    }

    private struct CardModifier<S: InsettableShape>: ViewModifier {
        let shape: S
        func body(content: Content) -> some View {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.55), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.10), radius: 16, y: 7)
        }
    }
}
