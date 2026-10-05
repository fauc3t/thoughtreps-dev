import SwiftUI
import UIKit
import ImageIO

enum ImageDecoding {
    /// Longest edge, in pixels, for images shown in a thought's body.
    static let bodyMaxPixel = 1200
    /// Longest edge for an image placed inside a line of text.
    static let inlineMaxPixel = 400

    /// Decodes off the main thread, downsampled so the longest edge is at most `maxPixel`
    /// (nil decodes at full size). Cancelling the caller cancels the work between steps.
    static func decode(_ data: Data?, maxPixel: Int?) async -> UIImage? {
        guard let data else { return nil }
        let work = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel ?? ImageProcessor.maxDimension
            guard !Task.isCancelled,
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            else { return nil }
            return UIImage(cgImage: cgImage)
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
}

/// Decoded images, evictable under memory pressure. Keyed by image id and pixel size.
final class DecodedImageCache: @unchecked Sendable {
    /// Shared by timeline cards, gallery tiles and editor thumbnails, so rows that scroll back in don't re-decode.
    static let thumbnails = DecodedImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private func key(_ id: UUID, _ maxPixel: Int?) -> NSString {
        "\(id.uuidString)-\(maxPixel ?? 0)" as NSString
    }

    func image(_ id: UUID, maxPixel: Int?) -> UIImage? { cache.object(forKey: key(id, maxPixel)) }

    func store(_ image: UIImage, _ id: UUID, maxPixel: Int?) { cache.setObject(image, forKey: key(id, maxPixel)) }
}

/// An image decoded off the main thread from stored bytes. Shows a placeholder until it loads.
/// `data` is read on the main actor when the task runs, so reading a model's blob stays safe.
/// Pass `cache: nil` for images that shouldn't be kept (the full-screen viewer).
struct DataImage: View {
    let id: UUID
    var contentMode: ContentMode = .fill
    var maxPixel: Int? = ImageProcessor.thumbnailDimension
    var cache: DecodedImageCache? = .thumbnails
    let data: @MainActor () -> Data?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            }
        }
        .task(id: id) {
            if let cached = cache?.image(id, maxPixel: maxPixel) {
                image = cached
                return
            }
            let decoded = await ImageDecoding.decode(data(), maxPixel: maxPixel)
            guard !Task.isCancelled, let decoded else { return }
            cache?.store(decoded, id, maxPixel: maxPixel)
            image = decoded
        }
    }
}

/// Images of one thought, resolvable by id for the Markdown renderer. Decoded images are cached
/// for as long as the owning view lives, at the downsampled size they're shown at.
@MainActor
final class ImageLibrary {
    private(set) var assets: [UUID: ImageAsset] = [:]
    private(set) var altTexts: [UUID: String] = [:]
    let cache = DecodedImageCache()

    init(images: [ImageAsset] = [], markdown: String = "") {
        update(images, markdown: markdown)
    }

    func update(_ images: [ImageAsset], markdown: String) {
        assets = Dictionary(images.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        altTexts = ImageToken.altTexts(in: markdown)
    }

    func image(for id: UUID, maxPixel: Int) async -> UIImage? {
        if let cached = cache.image(id, maxPixel: maxPixel) { return cached }
        guard let asset = assets[id], let image = await ImageDecoding.decode(asset.data, maxPixel: maxPixel) else { return nil }
        cache.store(image, id, maxPixel: maxPixel)
        return image
    }
}
