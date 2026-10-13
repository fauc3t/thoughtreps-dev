import Foundation
import os
@preconcurrency import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

enum FileProcessingError: Error, Equatable {
    case tooLarge
    /// Backup data that doesn't match its record.
    case sizeMismatch
}

/// Turns the bytes of a picked, dropped, shared or imported file into a draft ready to store: a
/// sanitized name, a type, and a preview image when Quick Look can make one. Thread-safe, so call it
/// from a background task. Reads only the data's length, never file dates.
enum FileProcessor {
    static let thumbnailSide: CGFloat = 240
    private static let thumbnailTimeout: DispatchTimeInterval = .seconds(5)

    static func process(data: Data, filename: String, typeIdentifier: String? = nil) throws -> FileDraft {
        guard data.count <= FileAttachment.maxBytes else { throw FileProcessingError.tooLarge }
        let name = FileAttachment.sanitizedFilename(filename)
        let type = typeIdentifier.flatMap { UTType($0) }
            ?? UTType(filenameExtension: (name as NSString).pathExtension)
            ?? .data
        return FileDraft(
            filename: name, typeIdentifier: type.identifier, byteCount: data.count,
            thumbnailData: thumbnail(of: data, named: name), data: data
        )
    }

    /// A JPEG preview from Quick Look, or nil when it has none for this type or takes too long.
    /// Blocks until Quick Look answers, so never call it on the main actor.
    static func thumbnail(of data: Data, named name: String) -> Data? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThoughtRepsThumbnail-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: thumbnailSide, height: thumbnailSide), scale: 2, representationTypes: .thumbnail
        )
        let result = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let answered = DispatchSemaphore(value: 0)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            result.withLock { $0 = representation.flatMap { flattened($0.uiImage) } }
            answered.signal()
        }
        guard answered.wait(timeout: .now() + thumbnailTimeout) == .success else { return nil }
        return result.withLock { $0 }
    }

    /// Drawn on white first, so a transparent image doesn't come out black as a JPEG.
    private static func flattened(_ image: UIImage) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = image.scale
        let flat = UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: image.size))
            image.draw(at: .zero)
        }
        return flat.jpegData(compressionQuality: 0.8)
    }
}
