import SwiftUI
import PhotosUI

/// Popover for choosing the canvas background: plain paper colors, procedural paper textures,
/// or a photo (library / camera). Colors set `engine.paper` (and drop any image background);
/// textures and photos are written into the engine's bottom "Background" layer.
struct BackgroundPickerView: View {
    @ObservedObject var engine: CanvasEngine

    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false

    private let paperColors: [(String, PaintColor)] = [
        ("White", PaintColor(r: 1, g: 1, b: 1, a: 1)),
        ("Warm", PaintColor(r: 0.98, g: 0.97, b: 0.94, a: 1)),
        ("Cream", PaintColor(r: 0.97, g: 0.92, b: 0.82, a: 1)),
        ("Gray", PaintColor(r: 0.85, g: 0.85, b: 0.86, a: 1)),
        ("Kraft", PaintColor(r: 0.85, g: 0.73, b: 0.55, a: 1)),
        ("Night", PaintColor(r: 0.16, g: 0.16, b: 0.19, a: 1)),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background")
                .font(.system(size: 13, weight: .semibold))

            sectionLabel("Paper")
            HStack(spacing: 11) {
                ForEach(paperColors, id: \.0) { name, c in
                    colorSwatch(name, c)
                }
                Spacer(minLength: 0)
            }

            sectionLabel("Texture")
            HStack(spacing: 11) {
                ForEach(PaperTexture.allCases, id: \.self) { texture in
                    textureSwatch(texture)
                }
                Spacer(minLength: 0)
            }

            sectionLabel("Photo")
            HStack(spacing: 8) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Library", systemImage: "photo.on.rectangle")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!engine.canSetBackgroundImage)

                Button {
                    showCamera = true
                } label: {
                    Label("Camera", systemImage: "camera")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!engine.canSetBackgroundImage
                          || !UIImagePickerController.isSourceTypeAvailable(.camera))

                if engine.backgroundLayer != nil {
                    Spacer(minLength: 0)
                    Button {
                        withAnimation { engine.clearBackgroundImage() }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.8))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove photo background")
                }
            }
        }
        .padding(14)
        .frame(width: 262)
        .modifier(DrawsyTheme.card(RoundedRectangle(cornerRadius: 20, style: .continuous)))
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data),
                   let cg = Self.normalizedCGImage(ui) {
                    engine.setBackgroundImage(cg)
                }
                photoItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                if let cg = Self.normalizedCGImage(image) {
                    engine.setBackgroundImage(cg)
                }
            }
            .ignoresSafeArea()
        }
        .id(engine.revision)
    }

    // MARK: - Pieces

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func colorSwatch(_ name: String, _ c: PaintColor) -> some View {
        let selected = engine.paper == c && engine.backgroundLayer == nil
        return Button {
            withAnimation {
                engine.clearBackgroundImage()
                engine.paper = c
            }
        } label: {
            Circle()
                .fill(Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)))
                .frame(width: 27, height: 27)
                .overlay(Circle().strokeBorder(
                    selected ? DrawsyTheme.accent : Color.primary.opacity(0.15),
                    lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func textureSwatch(_ texture: PaperTexture) -> some View {
        Button {
            if let tile = texture.tile {
                engine.setBackgroundImage(tile, tiled: true)
            }
        } label: {
            VStack(spacing: 3) {
                Group {
                    if let tile = texture.tile {
                        Image(decorative: tile, scale: 2)
                            .resizable()
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15)))
                Text(texture.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!engine.canSetBackgroundImage)
    }

    /// UIImage → CGImage with orientation baked in (camera images are often rotated via metadata).
    private static func normalizedCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }.cgImage
    }
}

/// Procedurally generated, tileable 256² paper textures — original art, no bundled assets.
enum PaperTexture: CaseIterable {
    case grain
    case canvas

    var displayName: String {
        switch self {
        case .grain: return "Grain"
        case .canvas: return "Canvas"
        }
    }

    /// Cached tile (cheap to build, but no reason to rebuild per popover open).
    var tile: CGImage? { Self.tileCache[self] }

    private static let tileCache: [PaperTexture: CGImage] = {
        var cache: [PaperTexture: CGImage] = [:]
        for texture in PaperTexture.allCases {
            if let tile = texture.makeTile() { cache[texture] = tile }
        }
        return cache
    }()

    private func makeTile() -> CGImage? {
        let n = 256
        var bytes = [UInt8](repeating: 255, count: n * n * 4)

        // Deterministic lattice hash → 0…1 (wraps at `cells`, so the noise tiles seamlessly).
        func hash(_ x: Int, _ y: Int) -> CGFloat {
            var h = UInt64(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
            h = (h ^ (h >> 13)) &* 1_274_126_177
            h ^= h >> 16
            return CGFloat(h & 0xFFFF) / 65535
        }
        func noise(_ u: CGFloat, _ v: CGFloat, cells: Int) -> CGFloat {
            let fx = u * CGFloat(cells), fy = v * CGFloat(cells)
            let x0 = Int(fx) % cells, y0 = Int(fy) % cells
            let x1 = (x0 + 1) % cells, y1 = (y0 + 1) % cells
            let tx = fx - fx.rounded(.down), ty = fy - fy.rounded(.down)
            let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
            let a = hash(x0, y0), b = hash(x1, y0), c = hash(x0, y1), d = hash(x1, y1)
            return a + (b - a) * sx + (c - a) * sy + (a - b - c + d) * sx * sy
        }

        for py in 0..<n {
            for px in 0..<n {
                let u = CGFloat(px) / CGFloat(n), v = CGFloat(py) / CGFloat(n)
                let base: (r: CGFloat, g: CGFloat, b: CGFloat)
                let shade: CGFloat   // 0…1, multiplied into the base color
                switch self {
                case .grain:
                    // Warm paper with soft multi-scale grain.
                    let g = 0.5 * noise(u, v, cells: 32) + 0.3 * noise(u, v, cells: 64)
                          + 0.2 * noise(u, v, cells: 128)
                    base = (0.97, 0.955, 0.915)
                    shade = 1 - 0.06 * g
                case .canvas:
                    // Woven cloth: fine crosshatch modulated by noise so it doesn't read mechanical.
                    let wx = 0.5 + 0.5 * sin(u * 2 * .pi * 64)
                    let wy = 0.5 + 0.5 * sin(v * 2 * .pi * 64)
                    let weave = wx * wy + (1 - wx) * (1 - wy)   // peaks on both thread directions
                    let irregular = 0.6 + 0.4 * noise(u, v, cells: 32)
                    base = (0.96, 0.945, 0.905)
                    shade = 1 - 0.07 * weave * irregular
                }
                let i = (py * n + px) * 4
                bytes[i] = UInt8(max(0, min(255, base.r * shade * 255)))
                bytes[i + 1] = UInt8(max(0, min(255, base.g * shade * 255)))
                bytes[i + 2] = UInt8(max(0, min(255, base.b * shade * 255)))
                bytes[i + 3] = 255
            }
        }

        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress, width: n, height: n,
                                      bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }
}

/// Minimal UIImagePickerController wrapper for camera capture (PhotosPicker covers the library).
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage, dismiss: { dismiss() }) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage) -> Void
        let dismiss: () -> Void

        init(onImage: @escaping (UIImage) -> Void, dismiss: @escaping () -> Void) {
            self.onImage = onImage
            self.dismiss = dismiss
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onImage(image) }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
