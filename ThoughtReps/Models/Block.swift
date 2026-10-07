import Foundation
import SwiftData

/// Kinds of extra content that can be attached under a thought.
/// Adding a kind = a new case here plus one view in Features/Blocks.
enum BlockKind: String, CaseIterable, Identifiable {
    case markdown
    case gallery

    var id: String { rawValue }

    /// What a markdown block that is blurred was stored and exported as before `Block.isBlurred`
    /// existed.
    static let legacyBlurredRaw = "blurred"

    /// The kind and blur state a stored or exported raw kind stands for, or nil if it is unknown.
    static func resolve(raw: String, isBlurred: Bool) -> (kind: BlockKind, isBlurred: Bool)? {
        if raw == legacyBlurredRaw { return (.markdown, true) }
        return BlockKind(rawValue: raw).map { ($0, $0 == .markdown && isBlurred) }
    }

    var label: String {
        switch self {
        case .markdown: "Text"
        case .gallery: "Image gallery"
        }
    }

    var systemImage: String {
        switch self {
        case .markdown: "text.alignleft"
        case .gallery: "photo.on.rectangle"
        }
    }
}

/// Extra content attached to a thought, rendered under its body. A markdown block has `content`
/// (Markdown, which can hold #tags and inline image tokens), an optional title, and stays hidden
/// until tapped when `isBlurred`. A gallery block has an optional title, no `content`, and its
/// `images`. The thought's own `body` acts as the first markdown block and is never a `Block`.
@Model
final class Block {
    var id: UUID = UUID()
    var kindRaw: String = BlockKind.markdown.rawValue
    var content: String = ""
    var title: String? = nil
    var isBlurred: Bool = false
    var order: Int = 0
    var thought: Thought? = nil

    @Relationship(deleteRule: .cascade, inverse: \ImageAsset.block)
    var images: [ImageAsset]? = []

    init(id: UUID = UUID(), kind: BlockKind, content: String, title: String? = nil, isBlurred: Bool = false, order: Int) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.content = content
        self.title = title
        self.isBlurred = isBlurred
        self.order = order
    }

    var kind: BlockKind {
        BlockKind(rawValue: kindRaw) ?? .markdown
    }

    var sortedImages: [ImageAsset] {
        (images ?? []).sorted { $0.order < $1.order }
    }
}
