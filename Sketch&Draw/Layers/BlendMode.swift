/// Layer blend modes. Raw values are stored in document manifests; `shaderIndex` must match the
/// switch in `blend_fragment` (Shaders.metal).
enum BlendMode: String, Codable, CaseIterable, Identifiable {
    case normal
    case multiply
    case screen
    case overlay

    var id: String { rawValue }

    var shaderIndex: Int32 {
        switch self {
        case .normal: 0
        case .multiply: 1
        case .screen: 2
        case .overlay: 3
        }
    }

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .multiply: "Multiply"
        case .screen: "Screen"
        case .overlay: "Overlay"
        }
    }
}
