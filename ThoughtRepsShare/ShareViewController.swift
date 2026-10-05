import UIKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// Principal class of the share extension: gathers the shared text/URL and hosts the compose sheet.
final class ShareViewController: UIViewController {
    private static let log = Logger(subsystem: "com.thoughtreps.share", category: "share")

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in
            let initial = await loadSharedContent()
            present(initialText: initial)
        }
    }

    private func present(initialText: String) {
        let compose = ComposeView(
            initialText: initialText,
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
            },
            onSave: { [weak self] text in
                let item = InboxItem(id: UUID(), body: text, createdAt: Date())
                try Inbox.write(item, to: try Inbox.directoryURL())
                self?.extensionContext?.completeRequest(returningItems: nil)
            }
        )
        let host = UIHostingController(rootView: compose)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func loadSharedContent() async -> String {
        var text: String?
        var url: URL?
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers {
            if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let found = await load(UTType.url, from: provider) { value -> URL? in
                    if let url = value as? URL { return url }
                    if let data = value as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
                    return nil
                }
                if let found, !found.isFileURL { url = found }
            }
            if text == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                text = await load(UTType.plainText, from: provider) { value -> String? in
                    if let string = value as? String { return string }
                    if let attributed = value as? NSAttributedString { return attributed.string }
                    if let data = value as? Data { return String(data: data, encoding: .utf8) }
                    return nil
                }
            }
        }
        return SharedContent.merge(text: text, url: url)
    }

    private func load<T>(_ type: UTType, from provider: NSItemProvider, convert: (NSSecureCoding) -> T?) async -> T? {
        do {
            return convert(try await provider.loadItem(forTypeIdentifier: type.identifier))
        } catch {
            Self.log.error("Couldn't load \(type.identifier): \(error.localizedDescription)")
            return nil
        }
    }
}

struct ComposeView: View {
    let initialText: String
    let onCancel: () -> Void
    let onSave: (String) throws -> Void

    @State private var text = ""
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($focused)
                .padding(.horizontal)
                .navigationTitle("New Thought")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save).disabled(trimmed.isEmpty)
                    }
                }
        }
        .onAppear {
            text = initialText
            focused = true
        }
        .alert("Couldn't save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        do {
            try onSave(trimmed)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
