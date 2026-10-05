import UIKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// Principal class of the share extension: gathers the shared text/URL and hosts the compose sheet.
final class ShareViewController: UIViewController {
    private struct ReadFailure: Error { let reason: String }
    private static let log = Logger(subsystem: "com.thoughtreps.share", category: "share")

    override func viewDidLoad() {
        super.viewDidLoad()
        Task { @MainActor in
            let (initial, fileError) = await loadSharedContent()
            present(initialText: initial, fileError: fileError)
        }
    }

    private func present(initialText: String, fileError: String?) {
        let compose = ComposeView(
            initialText: initialText,
            fileError: fileError,
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

    private func loadSharedContent() async -> (text: String, fileError: String?) {
        var text: String?
        var url: URL?
        var fileText: String?
        var fileError: String?
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers {
            let ids = provider.registeredTypeIdentifiers
            let textType = SharedContent.textType(in: ids)
            var isFile = textType != nil && SharedContent.isFile(typeIdentifiers: ids)
            if !isFile, text == nil, let textType {
                let value = await loadValue(textType, from: provider)
                if let fileURL = value as? URL, fileURL.isFileURL {
                    isFile = true
                } else {
                    text = Self.string(from: value)
                }
            }
            if isFile, let textType {
                if fileText == nil, fileError == nil {
                    switch await readFile(textType, from: provider) {
                    case .success(let contents): fileText = contents
                    case .failure(let failure): fileError = failure.reason
                    }
                }
                continue
            }
            if url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                let found = await load(UTType.url, from: provider) { value -> URL? in
                    if let url = value as? URL { return url }
                    if let data = value as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
                    return nil
                }
                if let found, !found.isFileURL { url = found }
            }
        }
        if let fileText { return (fileText, nil) }
        return (SharedContent.merge(text: text, url: url), fileError)
    }

    private static func string(from value: NSSecureCoding?) -> String? {
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let data = value as? Data { return String(data: data, encoding: .utf8) }
        return nil
    }

    private func loadValue(_ type: UTType, from provider: NSItemProvider) async -> NSSecureCoding? {
        await load(type, from: provider) { $0 }
    }

    /// Failure carries the user-facing reason. Logs the error case or code only, never file names or content.
    private func readFile(_ type: UTType, from provider: NSItemProvider) async -> Result<String, ReadFailure> {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    let code = (error as NSError?).map { "\($0.domain) \($0.code)" } ?? "unknown"
                    Self.log.error("Couldn't load shared file: \(code)")
                    continuation.resume(returning: .failure(ReadFailure(reason: "It couldn't be opened.")))
                    return
                }
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= SharedContent.maxFileBytes else { throw SharedContent.FileError.tooLarge }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    continuation.resume(returning: .success(try SharedContent.text(fromFileData: data)))
                } catch let error as SharedContent.FileError {
                    Self.log.error("Couldn't read shared file: \(String(describing: error))")
                    continuation.resume(returning: .failure(ReadFailure(reason: error.reason)))
                } catch {
                    let nsError = error as NSError
                    Self.log.error("Couldn't read shared file: \(nsError.domain) \(nsError.code)")
                    continuation.resume(returning: .failure(ReadFailure(reason: "It couldn't be opened.")))
                }
            }
        }
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
    let onCancel: () -> Void
    let onSave: (String) throws -> Void

    @State private var text: String
    @State private var errorMessage: String?
    @State private var errorTitle: String
    @FocusState private var focused: Bool

    init(initialText: String, fileError: String? = nil, onCancel: @escaping () -> Void, onSave: @escaping (String) throws -> Void) {
        self.onCancel = onCancel
        self.onSave = onSave
        _text = State(initialValue: initialText)
        _errorMessage = State(initialValue: fileError)
        _errorTitle = State(initialValue: fileError == nil ? "Couldn't save" : "Couldn't read the file")
    }

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
            focused = true
        }
        .alert(errorTitle, isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save() {
        do {
            try onSave(trimmed)
        } catch {
            errorTitle = "Couldn't save"
            errorMessage = error.localizedDescription
        }
    }
}
