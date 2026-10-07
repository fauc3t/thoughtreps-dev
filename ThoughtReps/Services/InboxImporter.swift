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
@MainActor
final class InboxImporter {
    static let importedIDsKey = "InboxImporter.importedIDs"
    private static let log = Logger(subsystem: "com.thoughtreps", category: "InboxImporter")

    private let defaults: UserDefaults
    private let removeFile: (URL) throws -> Void

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

    /// Returns the number of thoughts imported.
    @discardableResult
    func importPending(from directory: URL, store: ThoughtStore, fileManager: FileManager = .default) -> Int {
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

        let previousNote = store.saveErrors.note
        store.saveErrors.note = "Couldn't import a shared thought."
        defer {
            store.saveErrors.note = previousNote
            importedIDs = remembered
        }

        var imported = 0
        for (url, item) in pending {
            let id = item.id.uuidString
            if !remembered.contains(id) {
                let thought = store.create(body: item.body, now: item.createdAt)
                guard thought.modelContext != nil else { break }
                remembered.insert(id)
                imported += 1
            }
            do {
                try removeFile(url)
                remembered.remove(id)
            } catch {
                Self.log.error("Couldn't delete \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return imported
    }
}
