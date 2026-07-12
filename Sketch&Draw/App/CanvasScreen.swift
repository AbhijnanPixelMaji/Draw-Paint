import SwiftUI
import Combine

/// Full-screen drawing surface for one artwork: loads the document into an engine, autosaves on
/// dismiss and on backgrounding, and hosts the toolbar, brush controls, and layers panel.
struct CanvasScreen: View {
    let record: ArtworkRecord
    let store: DocumentStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = CanvasModel()
    @State private var showLayers =
        ProcessInfo.processInfo.environment["DRAWSY_DEBUG_SHOWLAYERS"] != nil
    @State private var isFullscreen =
        ProcessInfo.processInfo.environment["DRAWSY_DEBUG_FULLSCREEN"] != nil
    @State private var toolbarExpanded =
        ProcessInfo.processInfo.environment["DRAWSY_DEBUG_TOOLBAR"] != nil
    @State private var dockExpanded =
        ProcessInfo.processInfo.environment["DRAWSY_DEBUG_DOCK"] != nil
    @State private var showBackground =
        ProcessInfo.processInfo.environment["DRAWSY_DEBUG_BACKGROUND"] != nil

    var body: some View {
        ZStack {
            switch model.state {
            case .ready(let engine):
                CanvasView(engine: engine)
                    .ignoresSafeArea()
                // Scrim while any popup is open: the first touch outside lands here and dismisses
                // everything instead of painting a stroke.
                if !isFullscreen && (showLayers || toolbarExpanded || dockExpanded || showBackground) {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture { dismissPopups() }
                }
                if isFullscreen {
                    fullscreenExitButton
                } else {
                    VStack(spacing: 0) {
                        toolbar(engine)
                        Spacer()
                        BrushControlsView(engine: engine, expanded: $dockExpanded)
                            .padding(.bottom, 6)
                    }
                    .transition(.opacity)
                }
                if showLayers && !isFullscreen {
                    // Popover-style: hugs its content, anchored under the toolbar's layers button.
                    VStack {
                        HStack {
                            Spacer()
                            LayersPanel(engine: engine)
                                .padding(.trailing, 12)
                                .transition(.scale(scale: 0.9, anchor: .topTrailing)
                                    .combined(with: .opacity))
                        }
                        Spacer()
                    }
                    .padding(.top, 64)
                }
                if showBackground && !isFullscreen {
                    // Popover under the toolbar, centered (its button lives in the expanded set).
                    VStack {
                        BackgroundPickerView(engine: engine)
                            .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
                        Spacer()
                    }
                    .padding(.top, 64)
                }
            case .failed(let message):
                VStack(spacing: 16) {
                    ContentUnavailableView("Canvas unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                    Button("Back to gallery") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
            case .loading:
                ProgressView()
                    .controlSize(.large)
            }
        }
        .background(DrawsyTheme.desk.ignoresSafeArea())
        .tint(DrawsyTheme.accent)
        // The desk is a fixed light surface; keep the material chrome light for cohesion.
        .environment(\.colorScheme, .light)
        .statusBarHidden(isFullscreen)
        .persistentSystemOverlays(isFullscreen ? .hidden : .automatic)
        .task { model.start(record: record, store: store) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive { model.save(record: record, store: store) }
        }
        .onDisappear { model.save(record: record, store: store) }
    }

    /// One compact floating capsule with the three drawing essentials — undo · redo · layers — plus
    /// a "more" toggle that expands it in place to reveal gallery, zoom-to-fit, and fullscreen.
    private func toolbar(_ engine: CanvasEngine) -> some View {
        HStack(spacing: 4) {
            if toolbarExpanded {
                Group {
                    toolButton("square.grid.2x2") {
                        model.save(record: record, store: store)
                        dismiss()
                    }
                    toolButton("photo.artframe", active: showBackground) {
                        withAnimation(.spring(duration: 0.3)) {
                            showBackground.toggle()
                            showLayers = false
                        }
                    }
                    toolButton("viewfinder") { engine.zoomToFit() }
                    toolButton("arrow.up.left.and.arrow.down.right") {
                        withAnimation(.spring(duration: 0.3)) {
                            toolbarExpanded = false
                            isFullscreen = true
                        }
                    }
                    Divider().frame(height: 20)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            toolButton("arrow.uturn.backward", enabled: engine.canUndo) { engine.performUndo() }
            toolButton("arrow.uturn.forward", enabled: engine.canRedo) { engine.performRedo() }
            toolButton("square.3.layers.3d", active: showLayers) {
                withAnimation(.spring(duration: 0.3)) {
                    showLayers.toggle()
                    showBackground = false
                }
            }
            Divider().frame(height: 20)
            toolButton(toolbarExpanded ? "chevron.right" : "ellipsis", active: toolbarExpanded) {
                withAnimation(.spring(duration: 0.35, bounce: 0.25)) { toolbarExpanded.toggle() }
            }
        }
        .font(.system(size: 17, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .modifier(DrawsyTheme.card(Capsule()))
        .padding(.top, 8)
        .id(engine.revision)
    }

    private func dismissPopups() {
        withAnimation(.spring(duration: 0.3)) {
            showLayers = false
            toolbarExpanded = false
            dockExpanded = false
            showBackground = false
        }
    }

    /// Distraction-free drawing: all chrome hidden, one quiet control in the corner to come back.
    private var fullscreenExitButton: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    withAnimation(.spring(duration: 0.3)) { isFullscreen = false }
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.6))
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.plain)
                .modifier(DrawsyTheme.card(Circle()))
                .opacity(0.85)
                .padding(.trailing, 16)
                .padding(.top, 8)
            }
            Spacer()
        }
        .transition(.opacity)
    }

    private func toolButton(_ system: String, enabled: Bool = true, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .frame(width: 34, height: 34)
                .background(active ? DrawsyTheme.accent.opacity(0.15) : .clear, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .foregroundStyle(active ? DrawsyTheme.accent
                         : enabled ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.35))
    }
}

/// Owns engine creation/loading and document saving off the view lifecycle.
@MainActor
final class CanvasModel: ObservableObject {
    enum State {
        case loading
        case ready(CanvasEngine)
        case failed(String)
    }
    @Published var state: State = .loading

    func start(record: ArtworkRecord, store: DocumentStore) {
        guard case .loading = state else { return }
        do {
            let engine: CanvasEngine
            if FileManager.default.fileExists(
                atPath: store.url(forBundleNamed: record.bundleName).path) {
                engine = try CanvasEngine(document: store.load(bundleName: record.bundleName))
            } else {
                engine = try CanvasEngine(canvasSize: Self.defaultCanvasSize())
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["DRAWSY_DEBUG_STROKE"] != nil {
                engine.debugStroke()
                // Persist immediately so kill/relaunch verification works without UI interaction.
                try? store.save(engine.snapshotDocument(), bundleName: record.bundleName)
                record.modifiedAt = .now
                engine.markSaved()
            }
            #endif
            state = .ready(engine)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    /// New canvases match the device screen's aspect ratio (long side 2048px) so the paper fills the
    /// workspace instead of floating as a square with desk gaps above and below. Existing documents
    /// keep the size stored in their manifest.
    static func defaultCanvasSize() -> CGSize {
        let screen = UIScreen.main.bounds.size
        guard screen.width > 0, screen.height > 0 else { return CGSize(width: 2048, height: 2048) }
        let aspect = screen.width / screen.height
        return aspect < 1
            ? CGSize(width: (2048 * aspect).rounded(), height: 2048)
            : CGSize(width: 2048, height: (2048 / aspect).rounded())
    }

    func save(record: ArtworkRecord, store: DocumentStore) {
        guard case .ready(let engine) = state, engine.hasUnsavedChanges else { return }
        do {
            try store.save(engine.snapshotDocument(), bundleName: record.bundleName)
            record.modifiedAt = .now
            engine.markSaved()
        } catch {
            // Keep hasUnsavedChanges set so the next save attempt retries.
            print("Drawsy: save failed — \(error)")
        }
    }
}
