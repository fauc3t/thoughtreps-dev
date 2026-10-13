import SwiftUI
import UniformTypeIdentifiers

/// Where new files come from (the file picker and drops) and the processing that follows.
/// The editor owns one and attaches `.imageIntake(_:files:onAdd:)` (drops) and `.fileIntake(_:onAdd:)` (picker).
@MainActor
@Observable
final class FileIntake {
    enum Failure: Error, Equatable {
        case tooLarge, unreadable

        var message: String {
            switch self {
            case .tooLarge: FileAttachment.tooLargeMessage
            case .unreadable: "That file couldn't be read."
            }
        }
    }

    var isImporting = false
    var failure: Failure?
    private(set) var pendingCount = 0

    @ObservationIgnored var onAdd: ([FileDraft]) -> Void = { _ in }

    var isProcessing: Bool { pendingCount > 0 }

    /// Picked files; each is read inside its security scope.
    func ingest(_ urls: [URL]) {
        pendingCount += urls.count
        Task {
            var added: [FileDraft] = []
            for url in urls {
                let result = await Task.detached(priority: .userInitiated) { Self.load(url, scoped: true) }.value
                finish(result, into: &added)
            }
            if !added.isEmpty { onAdd(added) }
        }
    }

    /// Whether the dropped item is a file to attach: not an image (`ImageIntake` takes those), not a
    /// web link, not text.
    nonisolated static func isDroppedFile(_ provider: NSItemProvider) -> Bool {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        if types.contains(where: { $0.conforms(to: .image) }) { return false }
        if types.contains(where: { $0.conforms(to: .fileURL) }) { return true }
        return types.contains { $0.conforms(to: .data) && !$0.conforms(to: .text) && !$0.conforms(to: .url) }
    }

    /// Takes dropped files; nothing is downloaded, so a web link is never accepted.
    @discardableResult
    func ingestDropped(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter(Self.isDroppedFile)
        guard !files.isEmpty else { return false }
        pendingCount += files.count
        Task {
            var added: [FileDraft] = []
            for provider in files {
                finish(await Self.loadDropped(provider), into: &added)
            }
            if !added.isEmpty { onAdd(added) }
        }
        return true
    }

    private func finish(_ result: Result<FileDraft, Failure>, into added: inout [FileDraft]) {
        pendingCount -= 1
        switch result {
        case let .success(draft): added.append(draft)
        case let .failure(failure): self.failure = failure
        }
    }

    nonisolated static func load(_ url: URL, scoped: Bool) -> Result<FileDraft, Failure> {
        let accessing = scoped && url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= FileAttachment.maxBytes else { return .failure(.tooLarge) }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return .success(try FileProcessor.process(data: data, filename: url.lastPathComponent))
        } catch FileProcessingError.tooLarge {
            return .failure(.tooLarge)
        } catch {
            return .failure(.unreadable)
        }
    }

    private static func loadDropped(_ provider: NSItemProvider) async -> Result<FileDraft, Failure> {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, _ in
                // The copy at `url` is deleted when this returns, so it is read here.
                guard let url else {
                    continuation.resume(returning: .failure(.unreadable))
                    return
                }
                continuation.resume(returning: load(url, scoped: false))
            }
        }
    }
}

private struct FileIntakeModifier: ViewModifier {
    @Bindable var intake: FileIntake
    let onAdd: ([FileDraft]) -> Void

    func body(content: Content) -> some View {
        // Reassigned on every update so a finished file is delivered to the current handler.
        let _ = intake.onAdd = onAdd
        content
            .fileImporter(isPresented: $intake.isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case let .success(urls): intake.ingest(urls)
                case .failure: intake.failure = .unreadable
                }
            }
            .alert("Couldn't add file", isPresented: Binding(get: { intake.failure != nil }, set: { if !$0 { intake.failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(intake.failure?.message ?? "")
            }
    }
}

extension View {
    func fileIntake(_ intake: FileIntake, onAdd: @escaping ([FileDraft]) -> Void) -> some View {
        modifier(FileIntakeModifier(intake: intake, onAdd: onAdd))
    }
}
