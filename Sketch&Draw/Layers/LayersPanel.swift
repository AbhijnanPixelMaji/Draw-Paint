import SwiftUI

/// Compact layers popup anchored under the toolbar's layers button: reorder (drag),
/// add/duplicate/delete/merge-down, visibility, opacity, blend mode, live thumbnails, and paper
/// color. Sized to hug its content so it reads as a popover, not a sheet — designed phone-first.
struct LayersPanel: View {
    @ObservedObject var engine: CanvasEngine

    private let paperChoices: [(String, PaintColor)] = [
        ("Warm", PaintColor(r: 0.98, g: 0.97, b: 0.94, a: 1)),
        ("White", PaintColor(r: 1, g: 1, b: 1, a: 1)),
        ("Gray", PaintColor(r: 0.85, g: 0.85, b: 0.86, a: 1)),
        ("Kraft", PaintColor(r: 0.85, g: 0.73, b: 0.55, a: 1)),
        ("Night", PaintColor(r: 0.16, g: 0.16, b: 0.19, a: 1)),
    ]

    private let rowHeight: CGFloat = 46

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Layers")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    engine.addLayer()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .foregroundStyle(engine.canAddLayer ? DrawsyTheme.accent : Color.secondary.opacity(0.4))
                .disabled(!engine.canAddLayer)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            List {
                // Top of list = top of stack.
                ForEach(Array(engine.layers.enumerated()).reversed(), id: \.element.id) { index, layer in
                    row(index: index, layer: layer)
                        .listRowInsets(EdgeInsets(top: 3, leading: 10, bottom: 3, trailing: 4))
                        .listRowBackground(
                            index == engine.activeIndex ? DrawsyTheme.accent.opacity(0.12) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { engine.selectLayer(index) }
                }
                .onMove { offsets, dest in
                    // List shows reversed indices; map back to stack order.
                    let count = engine.layers.count
                    let src = IndexSet(offsets.map { count - 1 - $0 })
                    let to = count - dest
                    engine.moveLayer(fromOffsets: src, toOffset: max(0, to))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))   // always draggable
            // Hug the rows instead of stretching; scrolls only once the stack outgrows the cap.
            .frame(height: min(CGFloat(engine.layers.count) * rowHeight, rowHeight * 5) + 6)

            Divider().padding(.horizontal, 10)

            // Controls for the active layer.
            VStack(spacing: 7) {
                HStack(spacing: 12) {
                    Menu {
                        ForEach(BlendMode.allCases) { mode in
                            Button(mode.displayName) {
                                engine.setLayerBlendMode(mode, at: engine.activeIndex)
                            }
                        }
                    } label: {
                        Label(engine.activeLayer.blendMode.displayName, systemImage: "drop.halffull")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Spacer()
                    Button {
                        engine.duplicateLayer(at: engine.activeIndex)
                    } label: { Image(systemName: "plus.square.on.square") }
                        .disabled(!engine.canAddLayer)
                    Button {
                        engine.mergeDown(at: engine.activeIndex)
                    } label: { Image(systemName: "arrow.merge") }
                        .disabled(engine.activeIndex == 0)
                    Button(role: .destructive) {
                        engine.deleteLayer(at: engine.activeIndex)
                    } label: { Image(systemName: "trash") }
                        .disabled(engine.layers.count <= 1)
                }
                .font(.system(size: 13))

                HStack(spacing: 8) {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Slider(value: opacityBinding, in: 0...1)
                }

                HStack(spacing: 7) {
                    Text("Paper")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    ForEach(paperChoices, id: \.0) { name, c in
                        Button {
                            engine.paper = c
                        } label: {
                            Circle()
                                .fill(Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)))
                                .frame(width: 19, height: 19)
                                .overlay(Circle().strokeBorder(
                                    engine.paper == c ? DrawsyTheme.accent : Color.primary.opacity(0.2),
                                    lineWidth: engine.paper == c ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(name)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .frame(width: 248)
        .modifier(DrawsyTheme.card(RoundedRectangle(cornerRadius: 20, style: .continuous)))
        .id(engine.revision)   // refresh rows + thumbnails on structural changes
    }

    private func row(index: Int, layer: PaintLayer) -> some View {
        HStack(spacing: 8) {
            Button {
                engine.setLayerVisible(!layer.isVisible, at: index)
            } label: {
                Image(systemName: layer.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(layer.isVisible ? Color.primary.opacity(0.7) : Color.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)

            thumbnail(index: index)
                .frame(width: 32, height: 32)
                .background(
                    Image(systemName: "checkerboard.rectangle").resizable().opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))

            VStack(alignment: .leading, spacing: 1) {
                Text(layer.name).font(.system(size: 12, weight: .medium))
                Text(layer.blendMode.displayName + " · \(Int(layer.opacity * 100))%")
                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func thumbnail(index: Int) -> some View {
        if let cg = engine.layerThumbnail(at: index) {
            Image(decorative: cg, scale: 1).resizable().scaledToFit()
        } else {
            Color.clear
        }
    }

    private var opacityBinding: Binding<Float> {
        Binding(get: { engine.activeLayer.opacity },
                set: { engine.setLayerOpacity($0, at: engine.activeIndex) })
    }
}
