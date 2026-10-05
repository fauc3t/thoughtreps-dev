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
              let full = downscaled(source, longestEdge: min(maxDimension, original)),
              let thumbnail = downscaled(source, longestEdge: min(thumbnailDimension, original))
        else { throw ImageProcessingError.undecodable }

        return ProcessedImage(
            data: try encode(full),
            thumbnailData: try encode(thumbnail),
            width: full.width,
            height: full.height
        )
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
