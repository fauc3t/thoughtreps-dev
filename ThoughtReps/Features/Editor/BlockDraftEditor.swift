import SwiftUI

/// Editing row for one attached block in the editor.
struct BlockDraftEditor: View {
    @Binding var draft: BlockDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(draft.kind.label, systemImage: draft.kind.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Label (optional), e.g. Answer", text: $draft.title)
                .font(.subheadline.weight(.semibold))
            TextField("Hidden text", text: $draft.content, axis: .vertical)
                .lineLimit(2...8)
        }
        .padding(.vertical, 4)
    }
}
