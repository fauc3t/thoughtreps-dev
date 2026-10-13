import SwiftUI
import UniformTypeIdentifiers

/// What a file card shows, from either a stored file or a draft.
struct FileCardModel: Equatable {
    let id: UUID
    let filename: String
    let typeIdentifier: String
    let byteCount: Int
    let thumbnailData: Data?

    init(_ file: FileAsset) {
        id = file.id
        filename = file.filename
        typeIdentifier = file.typeIdentifier
        byteCount = file.byteCount
        thumbnailData = file.thumbnailData
    }

    init(_ draft: FileDraft) {
        id = draft.id
        filename = draft.filename
        typeIdentifier = draft.typeIdentifier
        byteCount = draft.byteCount
        thumbnailData = draft.thumbnailData
    }

    private var type: UTType? { UTType(typeIdentifier) }

    var typeDescription: String { type?.localizedDescription?.localizedCapitalized ?? "File" }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file) }

    var subtitle: String { "\(typeDescription) · \(sizeText)" }

    var accessibilityLabel: String { "File: \(filename), \(typeDescription), \(sizeText)" }

    /// The SF Symbol shown when there is no preview image.
    var symbolName: String {
        guard let type else { return "doc" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "waveform" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        if type.conforms(to: .text) { return "doc.text" }
        return "doc"
    }
}

/// The inside of a file card: a preview or the type's icon, the name and a type and size line. It
/// stacks vertically at accessibility text sizes.
struct FileCardContent: View {
    let model: FileCardModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let previewSide: CGFloat = 52

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            preview
            VStack(alignment: .leading, spacing: 2) {
                Text(model.filename)
                    .font(.archivo(15))
                    .foregroundStyle(Color.ink)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(model.subtitle)
                    .font(.mono(12, relativeTo: .footnote))
                    .foregroundStyle(Color.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var preview: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        Group {
            if model.thumbnailData != nil {
                DataImage(id: model.id) { model.thumbnailData }
            } else {
                Image(systemName: model.symbolName)
                    .font(.title2)
                    .foregroundStyle(Color.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.hl.opacity(0.4))
            }
        }
        .frame(width: Self.previewSide, height: Self.previewSide)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.hl, lineWidth: 1) }
        .accessibilityHidden(true)
    }
}

/// A file block in a thought: a card that opens the file in Quick Look.
struct FileBlockView: View {
    let file: FileAsset?

    @State private var preview: QuickLookItem?
    @State private var failed = false

    var body: some View {
        if let file, file.modelContext != nil, !file.isDeleted {
            let model = FileCardModel(file)
            Button { open(file) } label: {
                FileCardContent(model: model)
                    .inkCard()
            }
            .buttonStyle(InkPressStyle())
            .accessibilityLabel(model.accessibilityLabel)
            .accessibilityHint("Double tap to open")
            .fullScreenCover(item: $preview) { item in
                QuickLookPreview(url: item.url) {
                    QuickLookFiles.remove(item.url)
                    preview = nil
                }
                .ignoresSafeArea()
            }
            .alert("Couldn't open file", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This file couldn't be read.")
            }
        }
    }

    private func open(_ file: FileAsset) {
        do {
            preview = QuickLookItem(url: try QuickLookFiles.prepare(file))
        } catch {
            failed = true
        }
    }
}
