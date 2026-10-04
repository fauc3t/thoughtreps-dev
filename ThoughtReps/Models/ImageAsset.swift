import Foundation
import SwiftData

/// An image attached to a thought. The pixels live on disk in
/// Application Support/Images/<thought id>/<filename>; the body references it as `![](img:<id>)`.
/// Image capture arrives in Milestone 3; the model exists now so the schema is stable.
@Model
final class ImageAsset {
    var id: UUID = UUID()
    var filename: String = ""
    var width: Int = 0
    var height: Int = 0
    var thought: Thought? = nil

    init(filename: String, width: Int, height: Int) {
        self.id = UUID()
        self.filename = filename
        self.width = width
        self.height = height
    }
}
