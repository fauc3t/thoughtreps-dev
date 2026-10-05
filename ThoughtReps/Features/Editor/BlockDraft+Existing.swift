import Foundation

extension BlockDraft {
    /// Drafts for a thought's stored blocks. Gallery images come along as references to the stored
    /// images, because the store deletes any gallery image missing from its draft.
    static func drafts(for thought: Thought) -> [BlockDraft] {
        thought.sortedBlocks.map {
            BlockDraft(
                id: $0.id,
                kind: $0.kind,
                title: $0.title ?? "",
                content: $0.content,
                images: $0.sortedImages.map { ImageDraft(existing: $0) }
            )
        }
    }
}
