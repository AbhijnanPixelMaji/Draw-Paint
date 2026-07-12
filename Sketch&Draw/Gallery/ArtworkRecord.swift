import Foundation
import SwiftData

/// Gallery metadata for one artwork. The pixels live in the document bundle on disk
/// (`DocumentStore`); SwiftData stores only what the grid needs.
@Model
final class ArtworkRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var modifiedAt: Date
    var bundleName: String

    init(id: UUID = UUID(), title: String, bundleName: String,
         createdAt: Date = .now, modifiedAt: Date = .now) {
        self.id = id
        self.title = title
        self.bundleName = bundleName
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }
}
