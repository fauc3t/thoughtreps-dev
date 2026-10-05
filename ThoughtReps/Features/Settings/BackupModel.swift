import Foundation
import Observation
import SwiftData

/// A finished export waiting in the share sheet. Its directory is deleted when the sheet closes.
struct ExportedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// State of the export and import flows. Shared, so a file opened from Files or AirDrop starts the
/// same flow as the Settings buttons.
@MainActor
@Observable
final class BackupModel {
    static let shared = BackupModel()

    /// Which view presents the import sheet: Settings is itself a sheet, and a sheet can't present over it.
    enum Host { case root, settings }

    enum ImportPhase {
        case idle
        case preparing
        case review(summary: String, hasWork: Bool)
        case importing(done: Int, total: Int)
        case finished(String)
        case failed(String)
    }

    var host: Host = .root
    private(set) var importPhase = ImportPhase.idle
    private(set) var exportProgress: Double?
    var exportedFile: ExportedFile?
    var problem: String?

    private var plan: BackupPlan?
    private var container: ModelContainer?

    var isBusy: Bool {
        exportProgress != nil || isPresentingImport
    }

    var isPresentingImport: Bool {
        if case .idle = importPhase { false } else { true }
    }

    // MARK: Export

    func export(from container: ModelContainer) async {
        guard !isBusy else { return }
        exportProgress = 0
        let info = Bundle.main.infoDictionary
        let exporter = BackupExporter(
            container: container,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?"
        )
        let now = Date.now
        do {
            let url = try await Task.detached {
                try exporter.export(now: now) { fraction in
                    Task { @MainActor in BackupModel.shared.exportProgress = fraction }
                }
            }.value
            exportProgress = nil
            exportedFile = ExportedFile(url: url)
        } catch {
            exportProgress = nil
            problem = error.localizedDescription
        }
    }

    func finishSharing() {
        if let file = exportedFile {
            try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent())
        }
        exportedFile = nil
    }

    // MARK: Import

    /// Copies the file to a temporary location first (a picked file is security-scoped and one opened
    /// from Files or AirDrop sits in the app's Inbox), then checks it and compares it with the store.
    func beginImport(from url: URL, container: ModelContainer) {
        guard !isBusy else {
            problem = "Wait for the current export or import to finish."
            return
        }
        importPhase = .preparing
        self.container = container
        Task {
            do {
                let plan = try await Task.detached {
                    let local = try Self.copyToTemporaryFile(url)
                    do {
                        return try BackupImporter.plan(try BackupImporter.preflight(fileURL: local), container: container)
                    } catch {
                        try? FileManager.default.removeItem(at: local.deletingLastPathComponent())
                        throw error
                    }
                }.value
                self.plan = plan
                importPhase = .review(summary: Self.summary(of: plan), hasWork: !plan.toImport.isEmpty)
            } catch {
                importPhase = .failed(error.localizedDescription)
            }
        }
    }

    func runImport() async {
        guard let plan, let container, case .review = importPhase else { return }
        let total = plan.toImport.count
        importPhase = .importing(done: 0, total: total)
        let context = container.mainContext
        let store = ThoughtStore(context: context)
        let previousNote = store.saveErrors.note
        store.saveErrors.note = "Couldn't import your thoughts."
        defer { store.saveErrors.note = previousNote }

        var tally = ImportTally()
        var unreadable = 0
        var failure: String?
        do {
            for try await batch in BackupImporter.batches(for: plan) {
                guard store.importThoughts(batch.thoughts, tags: plan.preflight.tags, tally: &tally) else {
                    failure = ""
                    break
                }
                unreadable += batch.unreadable
                importPhase = .importing(done: tally.added + tally.replaced + unreadable, total: total)
            }
        } catch {
            failure = " \(error.localizedDescription)"
        }
        await NotificationScheduler.reschedule(context: context, now: .now)

        let imported = tally.added + tally.replaced
        let skipped = unreadable + tally.rejected + plan.preflight.unimportable
        if let failure {
            importPhase = .failed("Imported \(imported.formatted()) of \(total.formatted()). Import the file again to continue.\(failure)")
        } else {
            let note = skipped > 0 ? " \(skipped.formatted()) couldn't be imported." : ""
            importPhase = .finished("Imported \(Self.count(imported, "thought")).\(note)")
        }
        removeTemporaryFile()
    }

    func dismissImport() {
        guard !isImporting else { return }
        removeTemporaryFile()
        importPhase = .idle
    }

    private var isImporting: Bool {
        if case .importing = importPhase { true } else { false }
    }

    private func removeTemporaryFile() {
        if let plan {
            try? FileManager.default.removeItem(at: plan.preflight.fileURL.deletingLastPathComponent())
        }
        plan = nil
    }

    private nonisolated static func copyToTemporaryFile(_ url: URL) throws -> URL {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(BackupFormat.importDirectoryPrefix)\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let local = directory.appendingPathComponent("import.\(BackupFormat.fileExtension)")
        try FileManager.default.copyItem(at: url, to: local)
        if isInOpenInInbox(url) {
            try? FileManager.default.removeItem(at: url)
        }
        return local
    }

    /// Files opened from Files or AirDrop are copied into the app's Documents/Inbox and nothing else removes them.
    /// Picked files are the user's own and are never deleted.
    nonisolated static func isInOpenInInbox(_ url: URL) -> Bool {
        guard let documents = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else {
            return false
        }
        let inbox = documents.appendingPathComponent("Inbox", isDirectory: true).resolvingSymlinksInPath().path + "/"
        return url.resolvingSymlinksInPath().path.hasPrefix(inbox)
    }

    /// Removes export and import folders an earlier run left behind (the app was killed mid-flow). Call at
    /// launch; does nothing while a flow is running or an export awaits sharing.
    func removeStaleTemporaryFiles() {
        guard !isBusy, exportedFile == nil else { return }
        let temporary = FileManager.default.temporaryDirectory
        let contents = (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
        for url in contents where url.lastPathComponent.hasPrefix(BackupFormat.exportDirectoryPrefix) || url.lastPathComponent.hasPrefix(BackupFormat.importDirectoryPrefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func summary(of plan: BackupPlan) -> String {
        var text = "\(count(plan.thoughtCount, "thought")) · \(count(plan.imageCount, "image")) — "
            + "\(plan.new.formatted()) new, \(plan.newer.formatted()) newer, \(plan.upToDate.formatted()) already up to date"
        if plan.preflight.unimportable > 0 {
            text += ". \(count(plan.preflight.unimportable, "thought")) can't be imported."
        }
        return text
    }

    private static func count(_ number: Int, _ noun: String) -> String {
        "\(number.formatted()) \(noun)\(number == 1 ? "" : "s")"
    }
}
