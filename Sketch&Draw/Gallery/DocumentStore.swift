import Foundation

/// Owns the on-disk location of artwork bundles: `Documents/Artworks/<uuid>.drawsy`.
struct DocumentStore {
    let baseDirectory: URL

    /// Default store rooted in the app's Documents directory.
    static func standard() -> DocumentStore {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return DocumentStore(baseDirectory: docs.appendingPathComponent("Artworks", isDirectory: true))
    }

    func url(forBundleNamed name: String) -> URL {
        baseDirectory.appendingPathComponent(name, isDirectory: true)
    }

    func newBundleName(id: UUID = UUID()) -> String { "\(id.uuidString).drawsy" }

    func save(_ document: ArtworkDocument, bundleName: String) throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try document.save(to: url(forBundleNamed: bundleName))
    }

    func load(bundleName: String) throws -> ArtworkDocument {
        try ArtworkDocument.load(from: url(forBundleNamed: bundleName))
    }

    func delete(bundleName: String) {
        try? FileManager.default.removeItem(at: url(forBundleNamed: bundleName))
    }

    /// Copies a bundle for "duplicate artwork"; returns the new bundle name.
    func duplicate(bundleName: String) throws -> String {
        let newName = newBundleName()
        try FileManager.default.copyItem(at: url(forBundleNamed: bundleName),
                                         to: url(forBundleNamed: newName))
        return newName
    }

    func thumbnailURL(bundleName: String) -> URL {
        url(forBundleNamed: bundleName).appendingPathComponent("thumb.png")
    }
}
