import QuickLook
import SwiftUI

struct QuickLookItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Temporary copies of attached files for Quick Look, one folder per file so the original name is kept.
enum QuickLookFiles {
    static let directoryName = "ThoughtRepsQuickLook"

    static func root(in temporary: URL = FileManager.default.temporaryDirectory) -> URL {
        temporary.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Writes the file's bytes under its own name and returns the copy's URL.
    @MainActor
    static func prepare(_ file: FileAsset, in temporary: URL = FileManager.default.temporaryDirectory) throws -> URL {
        guard let data = file.data else { throw CocoaError(.fileReadUnknown) }
        let directory = root(in: temporary).appendingPathComponent(file.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(FileAttachment.sanitizedFilename(file.filename))
        try data.write(to: url)
        return url
    }

    /// Removes the copy and its folder.
    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// Removes copies an earlier run left behind. Call at launch.
    static func removeAll(in temporary: URL = FileManager.default.temporaryDirectory) {
        try? FileManager.default.removeItem(at: root(in: temporary))
    }
}

/// Quick Look on one file, with its own Done button; the share button in its bar offers Save to Files and Open in.
struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in onDone() })
        return UINavigationController(rootViewController: preview)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
