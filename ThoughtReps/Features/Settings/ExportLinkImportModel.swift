import Foundation
import Observation
import SwiftData
import UIKit

/// Importing from someone's export link: checks the link, claims it when the user taps Import, downloads
/// and decrypts, then hands the file to `BackupModel` so its review sheet and import run unchanged.
/// Shared, so a Universal Link can open the same sheet the Settings menu does.
@MainActor
@Observable
final class ExportLinkImportModel {
    static let shared = ExportLinkImportModel()

    enum Phase: Equatable {
        case entry
        case checking
        case ready(sizeBytes: Int, expiresAt: Date)
        case claiming
        case downloading(Double)
        /// The download failed but the claim's URL is still good, so trying again doesn't need a new claim.
        case retry
    }

    static let invalidLinkMessage = "This doesn't look like a Thought Reps export link."
    static let damagedMessage = "The downloaded file was damaged."
    static let networkMessage = "Couldn't reach Thought Reps. Check your connection and try again."

    var isPresented = false
    var text = "" {
        didSet {
            guard text != oldValue, !isWorking else { return }
            phase = .entry
            message = nil
        }
    }
    private(set) var phase = Phase.entry {
        didSet { backup.isImportingLink = isWorking || isClaimed }
    }
    private(set) var message: String?

    private let service: ExportLinkImportService
    private let backup: BackupModel
    private let now: @Sendable () -> Date
    private var claim: ExportLinkClaim?

    init(service: ExportLinkImportService = ExportLinkImportService(), backup: BackupModel = .shared, now: @escaping @Sendable () -> Date = { .now }) {
        self.service = service
        self.backup = backup
        self.now = now
    }

    var link: ParsedExportLink? { ParsedExportLink.parse(text) }

    var isWorking: Bool {
        switch phase {
        case .checking, .claiming, .downloading: true
        default: false
        }
    }

    /// Whether leaving the sheet would lose a claimed link's download.
    var isClaimed: Bool {
        switch phase {
        case .downloading, .retry: true
        default: false
        }
    }

    static func handles(_ url: URL) -> Bool {
        url.scheme == "https" && url.host() == "transfer.thoughtreps.com"
    }

    /// Opens the sheet, optionally prefilled and checked. Never claims.
    func present(opening url: URL? = nil) async {
        guard !isClaimed, !backup.isPresentingImport else { return }
        if let url {
            text = url.absoluteString
        }
        isPresented = true
        if url != nil { await checkStatus() }
    }

    func paste() {
        if let pasted = UIPasteboard.general.string { text = pasted }
    }

    func checkStatus() async {
        guard !isWorking else { return }
        guard let link else {
            message = Self.invalidLinkMessage
            return
        }
        phase = .checking
        message = nil
        do {
            let status = try await service.status(id: link.id)
            guard self.link == link else { return await recheck() }
            switch status {
            case .ready(let sizeBytes, let expiresAt):
                phase = .ready(sizeBytes: sizeBytes, expiresAt: expiresAt)
            case .used: fail(ExportLinkImportError.used)
            case .expired: fail(ExportLinkImportError.expired)
            case .revoked: fail(ExportLinkImportError.revoked)
            }
        } catch {
            guard self.link == link else { return await recheck() }
            fail(error)
        }
    }

    /// The text changed while a check was in flight, so its answer is for another link.
    private func recheck() async {
        phase = .entry
        if link != nil { await checkStatus() }
    }

    func startImport(container: ModelContainer) async {
        guard case .ready = phase, let link else { return }
        guard !backup.isBusy else {
            message = BackupModel.busyMessage
            return
        }
        let ready = phase
        phase = .claiming
        message = nil
        do {
            claim = try await service.claim(id: link.id)
        } catch {
            fail(error, restoring: ready)
            return
        }
        await download(link: link, container: container)
    }

    func retryDownload(container: ModelContainer) async {
        guard case .retry = phase, let link else { return }
        await download(link: link, container: container)
    }

    func dismiss() {
        guard !isWorking, !isClaimed else { return }
        reset()
    }

    /// Gives up on a claimed link, which can't be claimed again.
    func abandon() {
        guard !isWorking else { return }
        reset()
    }

    private func reset() {
        isPresented = false
        claim = nil
        phase = .entry
        message = nil
        text = ""
    }

    private func download(link: ParsedExportLink, container: ModelContainer) async {
        guard let claim else { return }
        phase = .downloading(0)
        message = nil
        let file: URL
        do {
            file = try await service.retrieve(claim, link: link) { fraction in
                Task { @MainActor in self.updateProgress(fraction) }
            }
        } catch ExportLinkImportError.downloadFailed {
            failDownload(claim, "The download didn't finish. Try again.")
            return
        } catch ExportLinkImportError.damaged {
            failDownload(claim, Self.damagedMessage)
            return
        } catch {
            self.claim = nil
            phase = .entry
            message = Self.networkMessage
            return
        }
        self.claim = nil
        phase = .entry
        if backup.beginImport(from: file, container: container, consuming: true) {
            reset()
        } else {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            message = BackupModel.busyMessage
        }
    }

    private func failDownload(_ claim: ExportLinkClaim, _ retryMessage: String) {
        if claim.download.expiresAt > now() {
            phase = .retry
            message = retryMessage
        } else {
            self.claim = nil
            phase = .entry
            message = retryMessage == Self.damagedMessage
                ? "\(Self.damagedMessage) This link is now used up. Make a new link in Thought Reps on your other device."
                : "The download didn't finish, and this link is now used up. Make a new link in Thought Reps on your other device."
        }
    }

    private func updateProgress(_ fraction: Double) {
        if case .downloading = phase { phase = .downloading(fraction) }
    }

    private func fail(_ error: Error, restoring previous: Phase = .entry) {
        let known = error as? ExportLinkImportError
        phase = known == .network || known == nil ? previous : .entry
        switch known {
        case .used: message = "This link was already used."
        case .expired: message = "This link has expired."
        case .revoked: message = "This link was turned off."
        case .notFound: message = "We couldn't find this link."
        case .claimUnreadable: message = "Something went wrong, and this link may be used up. Make a new link in Thought Reps on your other device."
        default: message = Self.networkMessage
        }
    }

    static func summary(sizeBytes: Int, expiresAt: Date, now: Date = .now) -> String {
        "\(ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)) · \(ExportLinkModel.expiryText(expiresAt, now: now))"
    }
}
