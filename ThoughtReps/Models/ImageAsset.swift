import Foundation
import SwiftData

/// An image attached to a thought, stored in the database (large blobs go to SwiftData's external
/// storage, and sync as CKAssets if iCloud is switched on).
///
/// With no `block` it is inline: the thought's body references it as `![](img:<id>)`. With a
/// `block` it belongs to that gallery block, and `thought` is the block's thought.
@Model
final class ImageAsset {
    var id: UUID = UUID()
    /// The processed image shown full screen (see `ImageProcessor`).
    @Attribute(.externalStorage) var data: Data? = nil
    /// Small version for cards and gallery grids.
    @Attribute(.externalStorage) var thumbnailData: Data? = nil
    var width: Int = 0
    var height: Int = 0
    /// Position within a gallery block; unused for inline images.
    var order: Int = 0
    var thought: Thought? = nil
    var block: Block? = nil

    init(id: UUID = UUID(), data: Data?, thumbnailData: Data?, width: Int, height: Int, order: Int = 0) {
        self.id = id
        self.data = data
        self.thumbnailData = thumbnailData
        self.width = width
        self.height = height
        self.order = order
    }

    var isInline: Bool { block == nil }
}
