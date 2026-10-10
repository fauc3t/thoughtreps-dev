import SwiftUI
import SwiftData

/// Picks a tag's color: Automatic (the name-based pick), one of `TagColor.swatches`, or Custom
/// (the system color picker; the pick saves when that picker closes).
struct TagColorSheet: View {
    let tag: Tag

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var dotSize = 44.0

    /// Its own error center because an alert on the root view doesn't show over a sheet.
    @State private var saveErrors = SaveErrorCenter()
    @State private var showsCustomPicker = false
    /// The color last chosen in the custom picker, saved when it closes. Only a @State write per
    /// drag step; the store is written once.
    @State private var customPick: UIColor?
    /// The tag's color as the picker opened, so a pick that changes nothing (or an echo of the
    /// initial color) doesn't pin an automatic color as custom.
    @State private var customStartHex: String?

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
                    customSwatch
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
        .sheet(isPresented: $showsCustomPicker, onDismiss: saveCustomPick) {
            CustomColorPicker(initial: UIColor(TagColor.color(for: tag)), selection: $customPick) {
                showsCustomPicker = false
            }
            .ignoresSafeArea()
        }
    }

    private func saveCustomPick() {
        guard let pick = customPick, let hex = TagColor.hex(for: pick) else { return }
        customPick = nil
        guard hex != customStartHex else { return }
        if store.setColor(tag, hex: hex, now: .now) { dismiss() }
    }

    /// Shows the saved custom color when there is one, otherwise a color wheel.
    private var customSwatch: some View {
        let isSelected = TagColor.isCustom(tag.colorHex)
        return Button {
            customPick = nil
            customStartHex = TagColor.hex(for: UIColor(TagColor.color(for: tag)))
            showsCustomPicker = true
        } label: {
            swatchLabel(name: "Custom", isSelected: isSelected, checkmark: isSelected ? TagColor.checkmarkColor(onHex: tag.colorHex) : .white) {
                if isSelected {
                    Circle().fill(TagColor.color(for: tag))
                } else {
                    Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                }
            }
        }
        .buttonStyle(SwatchButtonStyle())
        .accessibilityLabel("Custom")
        .accessibilityHint("Opens a color picker")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func swatch(name: String, color: Color, hex: String?, isSelected: Bool) -> some View {
        Button {
            if store.setColor(tag, hex: hex, now: .now) { dismiss() }
        } label: {
            swatchLabel(name: name, isSelected: isSelected, checkmark: .white) { Circle().fill(color) }
        }
        .buttonStyle(SwatchButtonStyle())
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func swatchLabel(name: String, isSelected: Bool, checkmark: Color, @ViewBuilder dot: () -> some View) -> some View {
        VStack(spacing: 6) {
            dot()
                .frame(width: dotSize, height: dotSize)
                .overlay {
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.headline)
                            .foregroundStyle(checkmark)
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
}

/// The system color picker (grid, spectrum, sliders, eyedropper) without opacity. `selection`
/// stays nil until the user picks something, so closing it untouched changes nothing; `onFinish`
/// runs when its close button is tapped.
private struct CustomColorPicker: UIViewControllerRepresentable {
    let initial: UIColor
    @Binding var selection: UIColor?
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.supportsAlpha = false
        picker.selectedColor = initial
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: CustomColorPicker

        init(parent: CustomColorPicker) { self.parent = parent }

        func colorPickerViewController(_ picker: UIColorPickerViewController, didSelect color: UIColor, continuously: Bool) {
            parent.selection = color
        }

        func colorPickerViewControllerDidFinish(_ picker: UIColorPickerViewController) {
            parent.onFinish()
        }
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
