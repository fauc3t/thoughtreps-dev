import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image ready to store: downscaled, upright, with all metadata removed.
struct ProcessedImage: Equatable, Sendable {
    /// Longest edge at most `ImageProcessor.maxDimension`.
    let data: Data
    /// Longest edge at most `ImageProcessor.thumbnailDimension`.
    let thumbnailData: Data
    /// Pixel size of `data`.
    let width: Int
    let height: Int
}

enum ImageProcessingError: Error, Equatable {
    case undecodable
    case encodingFailed
}

/// Turns the raw bytes of a photo (HEIC, JPEG, PNG, from Photos, the camera or the pasteboard)
/// into what the store keeps. Pure and thread-safe, so call it from a background task.
enum ImageProcessor {
    static let maxDimension = 2048
    static let thumbnailDimension = 400
    static let quality = 0.75

    static func process(_ input: Data) throws -> ProcessedImage {
        guard let source = CGImageSourceCreateWithData(input as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let original = longestEdge(of: source),
              let full = decoded(source, longestEdge: min(maxDimension, original)),
              let thumbnail = decoded(source, longestEdge: min(thumbnailDimension, original))
        else { throw ImageProcessingError.undecodable }

        return ProcessedImage(
            data: try encode(full),
            thumbnailData: try encode(thumbnail),
            width: full.width,
            height: full.height
        )
    }

    /// Just the thumbnail of an image already stored, for rebuilding one from the original bytes.
    static func thumbnail(of input: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(input as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let original = longestEdge(of: source),
              let thumbnail = decoded(source, longestEdge: min(thumbnailDimension, original))
        else { throw ImageProcessingError.undecodable }
        return try encode(thumbnail)
    }

    /// EXIF orientation only swaps the edges, so the longest edge needs no orientation handling.
    private static func longestEdge(of source: CGImageSource) -> Int? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return max(width, height)
    }

    /// Like `downscaled`, but redrawn into an opaque bitmap when the source image has no alpha channel.
    /// ImageIO thumbnails come back premultiplied even for opaque sources, and encoding those logs a warning.
    static func decoded(_ source: CGImageSource, longestEdge: Int) -> CGImage? {
        guard let image = downscaled(source, longestEdge: longestEdge) else { return nil }
        switch CGImageSourceCreateImageAtIndex(source, 0, nil)?.alphaInfo {
        case .some(.none), .some(.noneSkipFirst), .some(.noneSkipLast): return opaque(image) ?? image
        default: return image
        }
    }

    private static func opaque(_ image: CGImage) -> CGImage? {
        let spaces = [image.colorSpace, CGColorSpace(name: CGColorSpace.sRGB)].compactMap { $0 }
        for space in spaces {
            guard let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { continue }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return context.makeImage()
        }
        return nil
    }

    /// Decodes upright (orientation applied) at no more than `longestEdge`; metadata is not carried.
    private static func downscaled(_ source: CGImageSource, longestEdge: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestEdge,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// HEIC, or JPEG where the device can't encode it.
    private static func encode(_ image: CGImage) throws -> Data {
        for type in [UTType.heic, UTType.jpeg] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else {
                continue
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination) {
                return output as Data
            }
        }
        throw ImageProcessingError.encodingFailed
    }
}
