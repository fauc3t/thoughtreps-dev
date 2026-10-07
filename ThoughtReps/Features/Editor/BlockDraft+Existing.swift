import Foundation

extension BlockDraft {
    /// Drafts for a thought's stored blocks. Gallery images come along as references to the stored
    /// images, because the store deletes any gallery image missing from its draft. A block still
    /// stored with the legacy "blurred" kind opens as blurred markdown.
    static func drafts(for thought: Thought) -> [BlockDraft] {
        thought.sortedBlocks.map {
            let resolved = BlockKind.resolve(raw: $0.kindRaw, isBlurred: $0.isBlurred) ?? (kind: $0.kind, isBlurred: $0.isBlurred)
            return BlockDraft(
                id: $0.id,
                kind: resolved.kind,
                title: $0.title ?? "",
                content: $0.content,
                isBlurred: resolved.isBlurred,
                images: $0.sortedImages.map { ImageDraft(existing: $0) }
            )
        }
    }
}
