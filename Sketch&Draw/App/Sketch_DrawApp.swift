import SwiftUI
import SwiftData

@main
struct Sketch_DrawApp: App {
    var body: some Scene {
        WindowGroup {
            GalleryView()
                .persistentSystemOverlays(.hidden)
        }
        .modelContainer(for: ArtworkRecord.self)
    }
}
