import Foundation
import Observation
import os
import SwiftData
import UIKit

/// The one-time export link: builds the export, encrypts it on device, uploads it, and keeps the link
/// (whose key lives only in the Keychain) so Settings can show it again until it expires or is revoked.
@MainActor
@Observable
final class ExportLinkModel {
    static let shared = ExportLinkModel()
    private static let log = Logger(subsystem: "com.thoughtreps", category: "ExportLink")

    enum Stage { case building, encrypting, uploading }

    private(set) var stage: Stage?
    private(set) var isRevoking = false
    private(set) var openLink: StoredExportLink?

    private let backup: BackupModel
    private let service: ExportLinkServing
    private let store: ExportLinkStoring

    init(
        backup: BackupModel = .shared,
        service: ExportLinkServing = ExportLinkService(),
        store: ExportLinkStoring = KeychainExportLinkStore()
    ) {
        self.backup = backup
        self.service = service
        self.store = store
    }

    var isWorking: Bool { stage != nil || isRevoking }

    func create(from container: ModelContainer) async {
        guard !isWorking else { return }
        guard !backup.isBusy else {
            backup.problem = BackupModel.busyMessage
            return
        }
        backup.isSharingLink = true
        stage = .building
        defer {
            stage = nil
            backup.isSharingLink = false
        }
        do {
            let archive = try await backup.buildArchive(from: container)
            try await publish(archive: archive)
        } catch is CancellationError {
        } catch {
            backup.problem = ExportLinkFailure(error).message
        }
    }

    /// Encrypts and uploads the archive, then removes its directory whatever happens.
    func publish(archive: URL) async throws {
        let directory = archive.deletingLastPathComponent()
        defer {
            try? FileManager.default.removeItem(at: directory)
            stage = nil
        }
        stage = .encrypting
        let key = ExportLinkCrypto.makeKey()
        let encrypted = directory.appendingPathComponent("export.encrypted")
        let prepared = try await Task.detached {
            try ExportLinkCrypto.encryptFile(at: archive, to: encrypted, key: key)
        }.value

        stage = .uploading
        let created = try await service.create(sizeBytes: prepared.sizeBytes, sha256: prepared.sha256)
        discardStoredLink()
        let background = BackgroundTask.begin()
        defer { background.end() }
        let summary: ExportLinkSummary
        do {
            try await service.upload(file: encrypted, to: created.upload)
            summary = try await service.complete(exportLinkId: created.exportLinkId)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExportLinkError.unfinished(replacedPrevious: created.replacedExportLinkId != nil, underlying: error)
        }

        let stored = StoredExportLink(
            exportLinkId: summary.exportLinkId, key: ExportLinkCrypto.base64URL(key), expiresAt: summary.expiresAt
        )
        do { try store.save(stored) } catch { Self.log.error("Couldn't keep the export link: \(error)") }
        openLink = stored
    }

    /// Loads the stored link, drops it if it has expired, then asks the server (silently) whether it is
    /// still the open one.
    func refresh(now: Date = .now) async {
        guard stage == nil else { return }
        openLink = (try? store.load()) ?? nil
        if let link = openLink, link.isExpired(now: now) { discardStoredLink() }
        guard let link = openLink else { return }
        let current: ExportLinkSummary?
        do { current = try await service.current() } catch { return }
        guard stage == nil, openLink?.exportLinkId == link.exportLinkId else { return }
        if current?.exportLinkId != link.exportLinkId { discardStoredLink() }
    }

    func revoke() async {
        guard let link = openLink, !isWorking else { return }
        isRevoking = true
        defer { isRevoking = false }
        do {
            try await service.revoke(exportLinkId: link.exportLinkId)
            discardStoredLink()
        } catch let error as APIError where error.meansLinkIsGone {
            discardStoredLink()
        } catch is CancellationError {
        } catch {
            backup.problem = ExportLinkFailure(error, revoking: true).message
        }
    }

    private func discardStoredLink() {
        store.clear()
        openLink = nil
    }

    /// "Expires today at 3:40 PM", "Expires tomorrow at 9:15 AM", or the full date further out.
    static func expiryText(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return "Expires today at \(time)" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Expires tomorrow at \(time)"
        }
        return "Expires \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

/// Failure after the server already created the link (and replaced the previous one).
enum ExportLinkError: Error {
    case unfinished(replacedPrevious: Bool, underlying: Error)
}

/// Keeps the upload running for a short while after the app leaves the foreground.
@MainActor
private final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    static func begin() -> BackgroundTask {
        let task = BackgroundTask()
        task.identifier = UIApplication.shared.beginBackgroundTask(withName: "ExportLinkUpload") {
            MainActor.assumeIsolated { task.end() }
        }
        return task
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

struct ExportLinkFailure: Equatable {
    let message: String

    init(_ error: Error, revoking: Bool = false) {
        if case let ExportLinkError.unfinished(replacedPrevious, underlying) = error {
            let reason = ExportLinkFailure(underlying).message
            message = replacedPrevious ? "Your previous link was replaced and no longer works. \(reason)" : reason
            return
        }
        if error as? ExportLinkCrypto.Failure == .tooLarge {
            message = "This export is too large to share as a link (the limit is 100 MB). Use Export… and send the file instead."
            return
        }
        switch error as? APIError {
        case .unsupported:
            message = "Export links need a real iPhone."
        case .offline:
            message = "You appear to be offline. Check your connection and try again."
        case .tooLarge:
            message = "This export is too large to share as a link (the limit is 100 MB). Use Export… and send the file instead."
        case .rateLimited:
            message = "You've reached today's limit for export links. Try again tomorrow."
        case .uploadMismatch:
            message = "The upload didn't arrive intact. Try again."
        case .notFound, .used, .expired, .revoked:
            message = "That link is no longer available."
        default:
            message = revoking ? "The link couldn't be revoked. Try again." : "The link couldn't be created. Try again."
        }
    }
}
