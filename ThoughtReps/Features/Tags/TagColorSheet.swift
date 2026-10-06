import SwiftUI

/// Picks a tag's color: Automatic (the name-based pick) or one of `TagColor.swatches`.
struct TagColorSheet: View {
    let tag: Tag

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var dotSize = 44.0

    /// Its own error center because an alert on the root view doesn't show over a sheet.
    @State private var saveErrors = SaveErrorCenter()

    private var store: ThoughtStore { ThoughtStore(context: context, saveErrors: saveErrors) }

    private var selectedHex: String? {
        tag.colorHex.flatMap(TagColor.normalizedHex)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: max(88, dotSize * 1.8)), spacing: 8)], spacing: 8) {
                    swatch(name: "Automatic", color: TagColor.automaticColor(for: tag), hex: nil, isSelected: tag.colorHex == nil)
                    ForEach(TagColor.swatches) { item in
                        swatch(name: item.name, color: item.color, hex: item.hex, isSelected: selectedHex == item.hex)
                    }
                }
                .padding()
            }
            .navigationTitle("Color")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .saveErrorAlert(saveErrors)
        .presentationDetents([.medium, .large])
    }

    private func swatch(name: String, color: Color, hex: String?, isSelected: Bool) -> some View {
        Button {
            if store.setColor(tag, hex: hex) { dismiss() }
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.headline)
                                .foregroundStyle(.white)
                        }
                    }
                Text(name)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(SwatchButtonStyle())
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SwatchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

#Preview {
    TagColorSheet(tag: Tag(name: "swift", displayName: "swift"))
        .modelContainer(PreviewData.container)
}
