import SwiftUI
import UIKit

/// The share sheet, for a file that only exists after an export finishes.
struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Check, summarize and run an import. Presented by whichever view `model.host` names.
struct BackupImportSheet: View {
    let model: BackupModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch model.importPhase {
                case .idle:
                    EmptyView()
                case .preparing:
                    ProgressView("Checking file…")
                case .review(let summary, let hasWork):
                    Text(summary)
                        .multilineTextAlignment(.center)
                    if !hasWork {
                        Text("Everything in this file is already here.")
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        Task { await model.runImport() }
                    } label: {
                        Text("Import").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!hasWork)
                    .accessibilityHint("Adds the new and newer thoughts to this device")
                case .importing(let done, let total):
                    ProgressView(value: Double(done), total: Double(max(total, 1))) {
                        Text("Importing \(done.formatted()) of \(total.formatted())")
                    }
                    .accessibilityLabel("Importing thoughts")
                case .finished(let message), .failed(let message):
                    Text(message)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .frame(maxHeight: .infinity, alignment: .top)
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isFinished ? "Done" : "Cancel") { model.dismissImport() }
                        .disabled(isRunning)
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isRunning)
    }

    private var isRunning: Bool {
        switch model.importPhase {
        case .preparing, .importing: true
        default: false
        }
    }

    private var isFinished: Bool {
        switch model.importPhase {
        case .finished, .failed: true
        default: false
        }
    }
}

private struct BackupImportSheetModifier: ViewModifier {
    let model: BackupModel
    let host: BackupModel.Host

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { model.host == host && model.isPresentingImport },
            set: { if !$0 { model.dismissImport() } }
        )) {
            BackupImportSheet(model: model)
        }
    }
}

extension View {
    func backupImportSheet(_ model: BackupModel, host: BackupModel.Host) -> some View {
        modifier(BackupImportSheetModifier(model: model, host: host))
    }
}
