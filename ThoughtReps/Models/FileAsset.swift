import Foundation
import SwiftData

/// A file attached to a thought by a file block, stored in the database (the bytes go to SwiftData's
/// external storage, and sync as CKAssets if iCloud is switched on). `thought` is the block's thought.
@Model
final class FileAsset {
    var id: UUID = UUID()
    @Attribute(.externalStorage) var data: Data? = nil
    /// A preview image made when the file was added; nil when the type has none, and the card shows the type's icon.
    @Attribute(.externalStorage) var thumbnailData: Data? = nil
    /// The original name with its extension, sanitized.
    var filename: String = ""
    /// A `UTType` identifier.
    var typeIdentifier: String = ""
    var byteCount: Int = 0
    var thought: Thought? = nil
    var block: Block? = nil

    init(id: UUID = UUID(), data: Data?, thumbnailData: Data?, filename: String, typeIdentifier: String, byteCount: Int) {
        self.id = id
        self.data = data
        self.thumbnailData = thumbnailData
        self.filename = filename
        self.typeIdentifier = typeIdentifier
        self.byteCount = byteCount
    }
}
