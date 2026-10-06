import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

/// One sheet for both stages: the link sheet, which gives way to the review sheet in place when the file arrives.
private struct BackupImportSheetModifier: ViewModifier {
    let model: BackupModel
    let linkImport: ExportLinkImportModel
    let host: BackupModel.Host
    @Environment(\.modelContext) private var context

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { model.host == host && (model.isPresentingImport || linkImport.isPresented) },
            set: {
                if !$0 {
                    model.dismissImport()
                    linkImport.dismiss()
                }
            }
        )) {
            if model.isPresentingImport {
                BackupImportSheet(model: model)
            } else {
                ExportLinkImportSheet(model: linkImport, container: context.container)
            }
        }
    }
}

extension View {
    func backupImportSheet(_ model: BackupModel, linkImport: ExportLinkImportModel = .shared, host: BackupModel.Host) -> some View {
        modifier(BackupImportSheetModifier(model: model, linkImport: linkImport, host: host))
    }
}

/// The "Share export as link" row, and the open link with Copy, Share and Revoke while it is unexpired.
struct ExportLinkRows: View {
    let backup: BackupModel
    let exportLink: ExportLinkModel
    let container: ModelContainer
    @State private var confirmReplace = false
    @State private var copied = false

    var body: some View {
        Button {
            if exportLink.openLink == nil { start() } else { confirmReplace = true }
        } label: {
            HStack {
                Label("Share export as link", systemImage: "link")
                if let stage = exportLink.stage {
                    Spacer()
                    stageIndicator(stage)
                }
            }
        }
        .disabled(backup.isBusy || exportLink.isWorking)
        .accessibilityHint("Creates a one-time link that expires in 24 hours")
        .confirmationDialog("Replace your open link?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Replace link", role: .destructive) { start() }
        } message: {
            Text("The current link stops working as soon as the new one is ready.")
        }

        if let link = exportLink.openLink {
            VStack(alignment: .leading, spacing: 4) {
                Text(link.link)
                    .font(.footnote.monospaced())
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(ExportLinkModel.expiryText(link.expiresAt))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Button {
                // The link carries the key, so it leaves the clipboard when the link expires.
                UIPasteboard.general.setItems(
                    [[UTType.utf8PlainText.identifier: link.link]],
                    options: [.expirationDate: link.expiresAt]
                )
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy link", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            ShareLink(item: link.link) {
                Label("Share link", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                Task { await exportLink.revoke() }
            } label: {
                HStack {
                    Label("Revoke link", systemImage: "xmark.circle")
                    if exportLink.isRevoking {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(exportLink.isWorking)
            .accessibilityHint("Stops the link from working")
        }
    }

    private func start() {
        Task { await exportLink.create(from: container) }
    }

    @ViewBuilder
    private func stageIndicator(_ stage: ExportLinkModel.Stage) -> some View {
        switch stage {
        case .building:
            ProgressView(value: backup.exportProgress ?? 0)
                .frame(width: 80)
                .accessibilityLabel("Export progress")
        case .encrypting:
            ProgressView()
                .accessibilityLabel("Encrypting")
        case .uploading:
            ProgressView()
                .accessibilityLabel("Uploading")
        }
    }
}
