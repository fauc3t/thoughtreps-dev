import Foundation
import os

/// Turns files left in the share-extension inbox into thoughts, through `ThoughtStore.create`.
///
/// Files are processed oldest first. A file is deleted only after its create succeeds; a failed
/// create stops the run and leaves that file and the later ones for next time, so order is kept.
/// Undecodable `.json` files are logged and deleted (writes are atomic, so they can't be completed);
/// ones that can't be read are logged and left for the next run.
/// Anything that isn't `*.json` is ignored.
///
/// An item's ID is remembered between a successful create and a successful delete, so a file
/// that couldn't be deleted is never imported twice.
///
/// An item may name a shared file (`<id>.attachment` beside it). A photo is processed like one from the
/// picker into a gallery block; anything else becomes a file block. A missing or unusable attachment
/// leaves the thought without it. The attachment is deleted with its item. One whose item is gone is an
/// orphan, deleted once two runs in a row have seen it, so a share still being written is never touched.
@MainActor
final class InboxImporter {
    static let importedIDsKey = "InboxImporter.importedIDs"
    static let orphansKey = "InboxImporter.orphanAttachments"
    private static let log = Logger(subsystem: "com.thoughtreps", category: "InboxImporter")

    private let defaults: UserDefaults
    private let removeFile: (URL) throws -> Void
    private var isRunning = false
    private var rerunRequested = false

    init(
        defaults: UserDefaults = .standard,
        removeFile: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        self.defaults = defaults
        self.removeFile = removeFile
    }

    private var importedIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.importedIDsKey) ?? []) }
        set { defaults.set(Array(newValue), forKey: Self.importedIDsKey) }
    }

    /// Returns the number of thoughts imported. A call made while a run is going returns 0 and asks that
    /// run to look at the inbox again before it finishes, so a share that just arrived isn't left waiting.
    @discardableResult
    func importPending(from directory: URL, store: ThoughtStore, fileManager: FileManager = .default) async -> Int {
        guard !isRunning else {
            rerunRequested = true
            return 0
        }
        isRunning = true
        defer { isRunning = false }
        var total = 0
        repeat {
            rerunRequested = false
            let (imported, failed) = await runOnce(from: directory, store: store, fileManager: fileManager)
            total += imported
            if failed { break }
        } while rerunRequested
        return total
    }

    private func runOnce(from directory: URL, store: ThoughtStore, fileManager: FileManager) async -> (imported: Int, failed: Bool) {
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let jsonURLs = urls.filter { $0.pathExtension == "json" }
        var remembered = importedIDs
        remembered.formIntersection(jsonURLs.map { $0.deletingPathExtension().lastPathComponent.uppercased() })

        var pending: [(url: URL, item: InboxItem)] = []
        for url in jsonURLs {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                Self.log.error("Couldn't read inbox file \(url.lastPathComponent), leaving it for next time: \(error.localizedDescription)")
                continue
            }
            do {
                pending.append((url, try InboxItem.decoder().decode(InboxItem.self, from: data)))
            } catch {
                Self.log.error("Deleting undecodable inbox file \(url.lastPathComponent): \(error.localizedDescription)")
                try? removeFile(url)
            }
        }
        pending.sort { ($0.item.createdAt, $0.item.id.uuidString) < ($1.item.createdAt, $1.item.id.uuidString) }

        defer { importedIDs = remembered }

        var imported = 0
        var failed = false
        for (url, item) in pending {
            let id = item.id.uuidString
            if !remembered.contains(id) {
                let blocks = await attachmentBlocks(for: item, in: directory)
                let previousNote = store.saveErrors.note
                store.saveErrors.note = "Couldn't import a shared thought."
                let thought = store.create(body: item.body, blocks: blocks, now: item.createdAt)
                store.saveErrors.note = previousNote
                guard thought.modelContext != nil else {
                    failed = true
                    break
                }
                remembered.insert(id)
                imported += 1
            }
            do {
                try removeFile(url)
                remembered.remove(id)
            } catch {
                Self.log.error("Couldn't delete \(url.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            if let attachment = item.attachment {
                try? removeFile(directory.appendingPathComponent(attachment.path))
            }
        }
        removeOrphanAttachments(in: directory, urls: urls)
        return (imported, failed)
    }

    private enum Loaded: Sendable {
        case photo(ProcessedImage)
        case file(FileDraft)
    }

    private func attachmentBlocks(for item: InboxItem, in directory: URL) async -> [BlockDraft] {
        guard let attachment = item.attachment, attachment.path == (attachment.path as NSString).lastPathComponent else { return [] }
        let url = directory.appendingPathComponent(attachment.path)
        let loaded = await Task.detached(priority: .userInitiated) { Self.load(attachment, at: url) }.value
        switch loaded {
        case let .photo(processed)?:
            return [BlockDraft(kind: .gallery, images: [ImageDraft(processed: processed)])]
        case let .file(draft)?:
            return [BlockDraft(kind: .file, file: draft)]
        case nil:
            Self.log.error("Importing inbox item \(item.id.uuidString) without its attachment")
            return []
        }
    }

    private nonisolated static func load(_ attachment: InboxItem.Attachment, at url: URL) -> Loaded? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        if SharedContent.isImage(typeIdentifier: attachment.typeIdentifier), let processed = try? ImageProcessor.process(data) {
            return .photo(processed)
        }
        return (try? FileProcessor.process(data: data, filename: attachment.filename, typeIdentifier: attachment.typeIdentifier)).map(Loaded.file)
    }

    private func removeOrphanAttachments(in directory: URL, urls: [URL]) {
        let itemIDs = Set(urls.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent.uppercased() })
        let orphans = Set(urls.filter { $0.pathExtension == "attachment" && !itemIDs.contains($0.deletingPathExtension().lastPathComponent.uppercased()) }
            .map(\.lastPathComponent))
        let seenBefore = Set(defaults.stringArray(forKey: Self.orphansKey) ?? [])
        var remaining = Set<String>()
        for name in orphans {
            if seenBefore.contains(name), (try? removeFile(directory.appendingPathComponent(name))) != nil {
                continue
            }
            remaining.insert(name)
        }
        defaults.set(Array(remaining), forKey: Self.orphansKey)
    }
}
