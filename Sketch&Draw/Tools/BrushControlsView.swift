import SwiftUI

/// Floating brush dock: icon tool cards, a curated swatch row, and size/stabilizer sliders with a
/// live size preview. Interim UI — replaced by the skeuomorphic tool rack + color system in Phase 5.
struct BrushControlsView: View {
    @ObservedObject var engine: CanvasEngine
    /// Collapsed = a small pill with the three essentials (tool · color · size); expanded = the full
    /// dock. Owned by CanvasScreen so tap-outside-to-dismiss can collapse it with the other popups.
    @Binding var expanded: Bool

    private static let familyIcons: [String: String] = [
        "Pencil": "pencil",
        "Ink": "pencil.tip",
        "Marker": "highlighter",
        "Watercolor": "drop.fill",
        "Acrylic": "paintbrush.fill",
        "Airbrush": "aqi.medium",
        "Smudge": "hand.draw.fill",
        "Pastel": "scribble.variable",
        "Eraser": "eraser.fill",
    ]

    private let palette: [(String, PaintColor)] = [
        ("Ink", .black),
        ("Graphite", PaintColor(r: 0.45, g: 0.45, b: 0.48, a: 1)),
        ("Crimson", .red),
        ("Tangerine", PaintColor(r: 0.94, g: 0.52, b: 0.16, a: 1)),
        ("Sunflower", PaintColor(r: 0.93, g: 0.75, b: 0.10, a: 1)),
        ("Forest", .green),
        ("Ultramarine", .blue),
        ("Sky", PaintColor(r: 0.35, g: 0.63, b: 0.88, a: 1)),
        ("Violet", PaintColor(r: 0.48, g: 0.28, b: 0.72, a: 1)),
        ("Cocoa", PaintColor(r: 0.45, g: 0.30, b: 0.20, a: 1)),
    ]

    var body: some View {
        ZStack {
            if expanded {
                expandedDock
                    .transition(.scale(scale: 0.92, anchor: .bottom).combined(with: .opacity))
            } else {
                collapsedPill
                    .transition(.scale(scale: 0.8, anchor: .bottom).combined(with: .opacity))
            }
        }
    }

    /// The three essentials at a glance — current tool, color, and stroke size — one tap to open.
    private var collapsedPill: some View {
        Button {
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) { expanded = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: Self.familyIcons[engine.brush.family] ?? "paintbrush")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(LinearGradient(colors: [DrawsyTheme.accentSoft, DrawsyTheme.accent],
                                                 startPoint: .top, endPoint: .bottom))
                    )
                Circle()
                    .fill(Color(red: Double(engine.color.r), green: Double(engine.color.g),
                                blue: Double(engine.color.b)))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
                sizePreview
                if engine.hasWetPaint {
                    Divider().frame(height: 20)
                    Button {
                        engine.dryWetPaint()
                    } label: {
                        Image(systemName: "wind")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DrawsyTheme.accent)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                }
                Divider().frame(height: 20)
                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(.plain)
        .modifier(DrawsyTheme.card(Capsule()))
        .accessibilityLabel("Open brush controls")
    }

    private var expandedDock: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.spring(duration: 0.35, bounce: 0.2)) { expanded = false }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Collapse brush controls")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(BrushDescriptor.allPresets, id: \.name) { preset in
                        toolCard(preset)
                    }
                }
                .padding(.horizontal, 2)
            }

            HStack(spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 11) {
                        ForEach(palette, id: \.0) { name, c in
                            swatch(name, c)
                        }
                    }
                    .padding(.horizontal, 3)
                    .padding(.vertical, 4)   // room for the selected swatch to scale up
                }
                if engine.hasWetPaint {
                    Button {
                        engine.dryWetPaint()
                    } label: {
                        Label("Dry", systemImage: "wind")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                sizePreview
                Slider(value: sizeBinding, in: 2...60)
                Divider().frame(height: 20)
                Image(systemName: "scribble.variable")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Slider(value: stabilizerBinding, in: 0...1)
                    .frame(maxWidth: 96)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .modifier(DrawsyTheme.card(RoundedRectangle(cornerRadius: 26, style: .continuous)))
        .padding(.horizontal, 14)
    }

    // MARK: - Pieces

    private func toolCard(_ preset: BrushDescriptor) -> some View {
        let selected = engine.brush.name == preset.name
        return Button {
            // Preserve the user's size/stabilizer tweaks across preset switches.
            var b = preset
            b.baseRadius = engine.brush.baseRadius
            b.stabilization = engine.brush.stabilization
            withAnimation(.spring(duration: 0.25)) { engine.brush = b }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: Self.familyIcons[preset.family] ?? "paintbrush")
                    .font(.system(size: 17, weight: .medium))
                Text(preset.family)
                    .font(.system(size: 10, weight: .semibold))
            }
            .frame(width: 60, height: 54)
            .foregroundStyle(selected ? .white : Color.primary.opacity(0.7))
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(selected
                          ? AnyShapeStyle(LinearGradient(colors: [DrawsyTheme.accentSoft, DrawsyTheme.accent],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Color.primary.opacity(0.05)))
            )
            .shadow(color: selected ? DrawsyTheme.accent.opacity(0.35) : .clear, radius: 6, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(preset.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func swatch(_ name: String, _ c: PaintColor) -> some View {
        let selected = engine.color == c
        return Button {
            withAnimation(.spring(duration: 0.25)) { engine.color = c }
        } label: {
            Circle()
                .fill(Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)))
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 2.5 : 0))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.10), lineWidth: 0.5))
                .shadow(color: .black.opacity(selected ? 0.25 : 0.12), radius: selected ? 3 : 1.5, y: 1)
                .scaleEffect(selected ? 1.18 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Dot that tracks the current brush size and color, so the slider has a live anchor.
    private var sizePreview: some View {
        let c = engine.color
        // Map baseRadius 2…60 onto a 5…24pt dot.
        let d = 5 + (engine.brush.baseRadius - 2) / 58 * 19
        return ZStack {
            Circle().fill(Color.primary.opacity(0.05)).frame(width: 30, height: 30)
            Circle()
                .fill(Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)))
                .frame(width: d, height: d)
        }
    }

    private var sizeBinding: Binding<CGFloat> {
        Binding(get: { engine.brush.baseRadius }, set: { engine.brush.baseRadius = $0 })
    }

    private var stabilizerBinding: Binding<CGFloat> {
        Binding(get: { engine.brush.stabilization }, set: { engine.brush.stabilization = $0 })
    }
}
