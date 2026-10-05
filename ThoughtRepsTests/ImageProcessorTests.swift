import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import ThoughtReps

/// Builds an image in code: a two-tone gradient, so it isn't trivially compressible.
func makeTestImageData(
    width: Int, height: Int, type: UTType = .jpeg, properties: [CFString: Any] = [:]
) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    let colors = [CGColor(red: 1, green: 0.2, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.3, blue: 1, alpha: 1)]
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, properties as CFDictionary)
    precondition(CGImageDestinationFinalize(destination))
    return output as Data
}

private func properties(of data: Data) -> [CFString: Any]? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
}

private func pixelSize(of data: Data) -> (width: Int, height: Int)? {
    guard let found = properties(of: data),
          let width = found[kCGImagePropertyPixelWidth] as? Int,
          let height = found[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (width, height)
}

private func rgba(of image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
    var bytes = [UInt8](repeating: 0, count: 4)
    guard let context = CGContext(
        data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (bytes[0], bytes[1], bytes[2], bytes[3])
}

@Suite("ImageProcessor")
struct ImageProcessorTests {
    @Test func downscalesLargeImagesAndMakesAThumbnail() throws {
        let result = try ImageProcessor.process(makeTestImageData(width: 3000, height: 1500))
        #expect(result.width == 2048)
        #expect(result.height == 1024)
        let full = try #require(pixelSize(of: result.data))
        #expect(full.width == 2048 && full.height == 1024)
        let thumb = try #require(pixelSize(of: result.thumbnailData))
        #expect(thumb.width == 400 && thumb.height == 200)
    }

    @Test func neverUpscales() throws {
        let result = try ImageProcessor.process(makeTestImageData(width: 300, height: 200))
        #expect(result.width == 300 && result.height == 200)
        let thumb = try #require(pixelSize(of: result.thumbnailData))
        #expect(thumb.width == 300 && thumb.height == 200)
    }

    @Test func mediumImageKeepsItsSizeButGetsASmallerThumbnail() throws {
        let result = try ImageProcessor.process(makeTestImageData(width: 1000, height: 1600))
        #expect(result.width == 1000 && result.height == 1600)
        let thumb = try #require(pixelSize(of: result.thumbnailData))
        #expect(thumb.height == 400 && thumb.width == 250)
    }

    @Test func acceptsPNG() throws {
        let result = try ImageProcessor.process(makeTestImageData(width: 120, height: 80, type: .png))
        #expect(result.width == 120 && result.height == 80)
    }

    @Test func appliesOrientation() throws {
        // Orientation 6: stored landscape, displayed rotated to portrait.
        let input = makeTestImageData(width: 400, height: 200, properties: [kCGImagePropertyOrientation: 6])
        #expect(pixelSize(of: input)?.width == 400)
        let result = try ImageProcessor.process(input)
        #expect(result.width == 200 && result.height == 400)
        let full = try #require(pixelSize(of: result.data))
        #expect(full.width == 200 && full.height == 400)
        let thumb = try #require(pixelSize(of: result.thumbnailData))
        #expect(thumb.width == 200 && thumb.height == 400)
        #expect(properties(of: result.data)?[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
    }

    @Test func stripsLocationAndOtherMetadata() throws {
        let input = makeTestImageData(width: 200, height: 100, properties: [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.33,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.03,
                kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Acme"],
        ])
        let inputProperties = try #require(properties(of: input))
        #expect(inputProperties[kCGImagePropertyGPSDictionary] != nil)

        let result = try ImageProcessor.process(input)
        for output in [result.data, result.thumbnailData] {
            let found = try #require(properties(of: output))
            #expect(found[kCGImagePropertyGPSDictionary] == nil)
            let tiff = found[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            #expect(tiff?[kCGImagePropertyTIFFMake] == nil)
            let exif = found[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        }
    }

    @Test func opaqueSourcesDecodeWithoutAlpha() throws {
        for type in [UTType.jpeg, .png] {
            let data = makeTestImageData(width: 300, height: 400, type: type)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(ImageProcessor.decoded(source, longestEdge: 300))
            #expect(image.alphaInfo == .noneSkipLast || image.alphaInfo == .none)
        }
    }

    @Test func processedOpaquePNGHasExpectedThumbnail() throws {
        let result = try ImageProcessor.process(makeTestImageData(width: 600, height: 800, type: .png))
        let thumb = try #require(pixelSize(of: result.thumbnailData))
        #expect(thumb.width == 300 && thumb.height == 400)
    }

    @Test func flatteningKeepsOpaqueContent() throws {
        let data = makeTestImageData(width: 100, height: 100, type: .png)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(ImageProcessor.decoded(source, longestEdge: 100))
        let pixel = try #require(rgba(of: image, x: 50, y: 50))
        #expect(pixel.a == 255)
        #expect(Int(pixel.r) + Int(pixel.g) + Int(pixel.b) > 150)
    }

    @Test func grayscaleOpaqueSourceComesOutWithoutAlpha() throws {
        let context = try #require(CGContext(
            data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ))
        context.setFillColor(gray: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let source = try #require(CGImageSourceCreateWithData(output as Data as CFData, nil))
        let image = try #require(ImageProcessor.decoded(source, longestEdge: 80))
        #expect(image.alphaInfo == .noneSkipLast || image.alphaInfo == .none)
        let pixel = try #require(rgba(of: image, x: 10, y: 10))
        #expect(pixel.r > 100 && pixel.r < 210)
    }

    @Test func heicWithRealAlphaKeepsIt() throws {
        let context = try #require(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let source = try #require(CGImageSourceCreateWithData(output as Data as CFData, nil))
        let image = try #require(ImageProcessor.decoded(source, longestEdge: 100))
        #expect(image.alphaInfo != .noneSkipLast && image.alphaInfo != .none)
    }

    @Test func sourcesWithRealAlphaKeepIt() throws {
        let context = try #require(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))

        let source = try #require(CGImageSourceCreateWithData(output as Data as CFData, nil))
        let image = try #require(ImageProcessor.decoded(source, longestEdge: 100))
        #expect(image.alphaInfo != .noneSkipLast && image.alphaInfo != .none)
    }

    @Test func garbageThrows() {
        #expect(throws: ImageProcessingError.undecodable) {
            try ImageProcessor.process(Data("not an image".utf8))
        }
        #expect(throws: ImageProcessingError.undecodable) {
            try ImageProcessor.process(Data())
        }
    }

    @Test func runsOffTheMainActor() async throws {
        let input = makeTestImageData(width: 500, height: 500)
        let result = try await Task.detached { try ImageProcessor.process(input) }.value
        #expect(result.width == 500)
    }
}

@Suite("ImageToken")
struct ImageTokenTests {
    let a = UUID()
    let b = UUID()

    @Test func buildsAndParsesTokens() {
        let token = ImageToken.token(for: a)
        #expect(token == "![](img:\(a.uuidString))")
        #expect(ImageToken.references(in: token) == [a])
    }

    @Test func parsesInTextOrderWithAltText() {
        let body = "# T\n![photo](img:\(b.uuidString)) text\n![](img:\(a.uuidString))\n![x](img:\(b.uuidString))"
        #expect(ImageToken.references(in: body) == [b, a, b])
    }

    @Test func ignoresCodeAndOtherImages() {
        let body = """
        `![](img:\(a.uuidString))`
        ```
        ![](img:\(a.uuidString))
        ```
        ![](https://example.com/x.png) ![](img:not-a-uuid)
        ![](img:\(b.uuidString))
        """
        #expect(ImageToken.references(in: body) == [b])
    }

    @Test func resolvesURLs() {
        #expect(ImageToken.id(from: URL(string: "img:\(a.uuidString)")!) == a)
        #expect(ImageToken.id(from: URL(string: "IMG:\(a.uuidString.lowercased())")!) == a)
        #expect(ImageToken.id(from: URL(string: "https://example.com/\(a.uuidString)")!) == nil)
        #expect(ImageToken.id(from: URL(string: "img:nope")!) == nil)
    }
}
