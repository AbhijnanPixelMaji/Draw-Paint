import SwiftUI
import SwiftData
import Combine

/// Artwork grid: thumbnails, create, rename, duplicate, delete. Tapping opens the canvas full-screen.
struct GalleryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ArtworkRecord.modifiedAt, order: .reverse) private var artworks: [ArtworkRecord]

    private let store = DocumentStore.standard()
    @State private var openRecord: ArtworkRecord?
    @State private var renameTarget: ArtworkRecord?
    @State private var renameText = ""

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(artworks) { record in
                        cell(record)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Drawsy")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        createArtwork()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .overlay {
                if artworks.isEmpty {
                    ContentUnavailableView(
                        "No artworks yet",
                        systemImage: "paintbrush.pointed",
                        description: Text("Tap + to start drawing."))
                }
            }
        }
        .fullScreenCover(item: $openRecord) { record in
            CanvasScreen(record: record, store: store)
        }
        .task {
            #if DEBUG
            // Simulator-only drive hooks (no touch injection available from the CLI):
            // DRAWSY_DEBUG_AUTO=create → new artwork + open; =open → open most recent.
            switch ProcessInfo.processInfo.environment["DRAWSY_DEBUG_AUTO"] {
            case "create": createArtwork()
            case "open": openRecord = artworks.first
            default: break
            }
            #endif
        }
        .alert("Rename artwork", isPresented: renameAlertBinding) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                if let target = renameTarget {
                    target.title = renameText
                    target.modifiedAt = .now
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
    }

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private func cell(_ record: ArtworkRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail(record)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color(white: 0.96))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
            Text(record.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
            Text(record.modifiedAt, style: .date).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { openRecord = record }
        .contextMenu {
            Button {
                renameText = record.title
                renameTarget = record
            } label: { Label("Rename", systemImage: "pencil") }
            Button {
                duplicate(record)
            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button(role: .destructive) {
                store.delete(bundleName: record.bundleName)
                modelContext.delete(record)
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private func thumbnail(_ record: ArtworkRecord) -> some View {
        // modifiedAt in the id forces a reload after edits.
        if let ui = UIImage(contentsOfFile: store.thumbnailURL(bundleName: record.bundleName).path) {
            Image(uiImage: ui).resizable().scaledToFill()
                .id(record.modifiedAt)
        } else {
            Image(systemName: "paintbrush.pointed")
                .font(.largeTitle).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func createArtwork() {
        let record = ArtworkRecord(title: "Untitled \(artworks.count + 1)",
                                   bundleName: store.newBundleName())
        modelContext.insert(record)
        openRecord = record
    }

    private func duplicate(_ record: ArtworkRecord) {
        guard let newBundle = try? store.duplicate(bundleName: record.bundleName) else { return }
        let copy = ArtworkRecord(title: record.title + " copy", bundleName: newBundle)
        modelContext.insert(copy)
    }
}
