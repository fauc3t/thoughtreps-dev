import SwiftData
import SwiftUI

/// Paste or open an export link, check it, and download it. The review sheet takes over from here.
struct ExportLinkImportSheet: View {
    @Bindable var model: ExportLinkImportModel
    let container: ModelContainer

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !model.isClaimed {
                        linkField
                    }
                    content
                    if let message = model.message {
                        Text(message)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(message)
                    }
                }
                .padding()
            }
            .navigationTitle("Import from Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if case .retry = model.phase { model.abandon() } else { model.dismiss() }
                    }
                    .disabled(model.isWorking)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(model.isWorking || model.isClaimed)
    }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Paste your export link", text: $model.text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .onSubmit { Task { await model.checkStatus() } }
                .disabled(model.isWorking)
                .accessibilityLabel("Export link")
            Button {
                model.paste()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .hoverEffect(.highlight)
            .disabled(model.isWorking)
            .accessibilityHint("Pastes the link from the clipboard")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .entry, .checking:
            Button {
                Task { await model.checkStatus() }
            } label: {
                HStack {
                    if model.phase == .checking { ProgressView() }
                    Text("Continue")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .hoverEffect(.highlight)
            .disabled(model.text.isEmpty || model.phase == .checking)
            .accessibilityHint("Checks the link without using it up")
        case .ready(let sizeBytes, let expiresAt):
            Text(ExportLinkImportModel.summary(sizeBytes: sizeBytes, expiresAt: expiresAt))
                .font(.headline)
            Text("This link works once. After you tap Import, it's used up.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                Task { await model.startImport(container: container) }
            } label: {
                Text("Import").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .hoverEffect(.highlight)
            .accessibilityHint("Downloads your thoughts and uses up the link")
        case .claiming:
            ProgressView("Starting…")
        case .downloading(let fraction):
            ProgressView(value: fraction) {
                Text("Downloading…")
            } currentValueLabel: {
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
            }
            .accessibilityLabel("Downloading")
        case .retry:
            Button {
                Task { await model.retryDownload(container: container) }
            } label: {
                Text("Try again").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .hoverEffect(.highlight)
        }
    }
}
