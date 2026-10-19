#if DEBUG
import Foundation
import UIKit

/// DEBUG only: creates deterministic thoughts through `ThoughtStore` for the two-device harness, where XCUITest can't reach
/// (the photo and file pickers) or typing would take too long. The writes are real: stamped, indexed and enqueued like any
/// other. Runs at launch when the arguments hold `-TRSeedSyncTestData <kind>[,<kind>...][:<nonce>]`, once the outbox is on.
///
/// A seeded thought's first line names it ("Seed image") and its second line is the tag the harness opens
/// (`#syncprobe`; `#syncbulk` for the bulk kind, which would flood that list).
enum SyncTestSeed {
    static let launchArgument = "-TRSeedSyncTestData"
    /// Run records are kept here, so a relaunch with the same kind and nonce seeds nothing again.
    static let appliedKey = "syncTestSeedApplied"

    static let bulkCount = 500
    static let largeBodyBytes = 150_000
    static let probeTag = "syncprobe"
    static let bulkTag = "syncbulk"

    enum Kind: String, CaseIterable {
        case image, gallery, file, bulk, large
        /// A Learn-mode thought that is already due, so a test can press Got it without waiting a day.
        case learn

        var title: String {
            switch self {
            case .image: "Seed image"
            case .gallery: "Seed gallery"
            case .file: "Seed file"
            case .bulk: "Seed bulk"
            case .large: "Seed large"
            case .learn: "Seed learn"
            }
        }
    }

    struct Request: Equatable {
        var kind: Kind
        var nonce: String

        var key: String { "\(kind.rawValue):\(nonce)" }
    }

    /// The requests after the launch argument (`kind[,kind...]` or with `:nonce`), or none when the argument is missing. A
    /// name that is no kind is skipped.
    static func requests(in arguments: [String]) -> [Request] {
        guard let index = arguments.firstIndex(of: launchArgument), arguments.indices.contains(index + 1) else { return [] }
        let parts = arguments[index + 1].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let nonce = parts.count > 1 ? String(parts[1]) : ""
        return (parts.first ?? "").split(separator: ",").compactMap { Kind(rawValue: String($0)) }.map { Request(kind: $0, nonce: nonce) }
    }

    /// Seeds the request unless this install already did. Returns true if it created anything.
    @MainActor
    @discardableResult
    static func run(_ request: Request, store: ThoughtStore, now: Date, defaults: UserDefaults = .standard) async -> Bool {
        var applied = defaults.stringArray(forKey: appliedKey) ?? []
        guard !applied.contains(request.key) else { return false }
        applied.append(request.key)
        defaults.set(applied, forKey: appliedKey)
        switch request.kind {
        case .image:
            store.create(
                body: "\(request.kind.title)\n#\(probeTag)\n\n\(ImageToken.token(for: imageID(0)))", images: [ImageDraft(id: imageID(0), processed: image(0))], now: now
            )
        case .gallery:
            store.create(
                body: "\(request.kind.title)\n#\(probeTag)",
                blocks: [BlockDraft(kind: .gallery, images: (1...3).map { ImageDraft(id: imageID($0), processed: image($0)) })], now: now
            )
        case .file:
            let bytes = fileBytes()
            let file = FileDraft(
                id: fileID, filename: "seed-notes.txt", typeIdentifier: "public.plain-text", byteCount: bytes.count, thumbnailData: nil, data: bytes
            )
            store.create(body: "\(request.kind.title)\n#\(probeTag)", blocks: [BlockDraft(kind: .file, file: file)], now: now)
        case .bulk:
            for number in 1...bulkCount {
                store.create(body: bulkBody(number), now: now)
                if number.isMultiple(of: 20) { await Task.yield() }
            }
        case .large:
            store.create(body: largeBody(), now: now)
        case .learn:
            let thought = store.create(body: "\(request.kind.title)\n#\(probeTag)", learn: true, now: now)
            store.overrideSchedule(thought, nextDueAt: now.addingTimeInterval(-3600), lastViewedAt: nil, viewCount: 0, now: now)
        }
        return true
    }

    static func bulkBody(_ number: Int) -> String {
        "\(Kind.bulk.title) \(String(format: "%04d", number))\n#\(bulkTag)"
    }

    static func largeBody() -> String {
        var body = "\(Kind.large.title)\n#\(probeTag)\n\n"
        var line = 0
        while body.utf8.count < largeBodyBytes {
            line += 1
            body += "Line \(line): the quick brown fox \(line * 7919 % 10007) jumps over lazy dog \(line * 104_729 % 99_991).\n"
        }
        return body
    }

    static func fileBytes() -> Data {
        Data((1...200).map { "Seed file line \($0): \($0 * 31 % 97)\n" }.joined().utf8)
    }

    /// Deterministic ids, so a seeded thought looks the same on every run.
    static func imageID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "5EED0000-0000-4000-8000-%012d", index + 1)) ?? UUID()
    }

    private static let fileID = UUID(uuidString: "5EED0000-0000-4000-9000-000000000001") ?? UUID()

    /// A small coloured picture whose bytes differ per index.
    static func image(_ index: Int) -> ProcessedImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: 160, height: 100)
        let hue = CGFloat(index % 8) / 8
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            for stripe in 0...index { context.fill(CGRect(x: 10 + stripe * 18, y: 10, width: 8, height: 80)) }
        }
        guard let processed = try? ImageProcessor.process(png) else {
            return ProcessedImage(data: png, thumbnailData: png, width: Int(size.width), height: Int(size.height))
        }
        return processed
    }
}
#endif
