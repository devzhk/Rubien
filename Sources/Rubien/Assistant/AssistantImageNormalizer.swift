#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct NormalizedAssistantImage: Sendable, Equatable {
    let data: Data
    let mediaType: String
    let pathExtension: String
    let width: Int
    let height: Int
    let thumbnailDataURL: String
}

enum AssistantImageNormalizer {
    static let maxPixelSize = 2_576
    static let maxBytes = Int(AssistantAttachmentPolicy.maximumFileBytes)

    private static let candidateEdges = [2_576, 2_048, 1_600, 1_280, 1_024, 768, 512]
    private static let jpegQualities: [Double] = [0.90, 0.82, 0.74, 0.64, 0.52]
    private static let thumbnailPixelSize = 160

    static func normalize(
        _ data: Data,
        displayName: String,
        maxPixelSize: Int = maxPixelSize,
        maxBytes: Int = maxBytes
    ) throws -> NormalizedAssistantImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw AssistantAttachmentStoreError.imageDecode(displayName)
        }
        return try normalize(
            source,
            displayName: displayName,
            maxPixelSize: maxPixelSize,
            maxBytes: maxBytes
        )
    }

    /// URL-backed ImageIO avoids materializing an arbitrarily large selected file
    /// before we know whether it is an image. ImageIO reads the metadata and decoded
    /// thumbnail it needs; Rubien only retains the bounded normalized result.
    static func normalize(
        fileURL: URL,
        displayName: String,
        maxPixelSize: Int = maxPixelSize,
        maxBytes: Int = maxBytes
    ) throws -> NormalizedAssistantImage {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, options) else {
            throw AssistantAttachmentStoreError.imageDecode(displayName)
        }
        return try normalize(
            source,
            displayName: displayName,
            maxPixelSize: maxPixelSize,
            maxBytes: maxBytes
        )
    }

    private static func normalize(
        _ source: CGImageSource,
        displayName: String,
        maxPixelSize: Int,
        maxBytes: Int
    ) throws -> NormalizedAssistantImage {
        guard
            maxPixelSize > 0,
            maxBytes > 0,
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
            let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
            sourceWidth > 0,
            sourceHeight > 0
        else {
            throw AssistantAttachmentStoreError.imageDecode(displayName)
        }

        let sourceMaximum = max(sourceWidth, sourceHeight)
        let edges = descendingEdges(sourceMaximum: sourceMaximum, limit: maxPixelSize)
        var decodedAnyCandidate = false

        var alphaImageDecoded = false
        for edge in edges {
            guard let image = thumbnail(from: source, edge: edge) else { continue }
            decodedAnyCandidate = true

            if hasAlpha(image) {
                alphaImageDecoded = true
                if let png = encode(image, type: .png, quality: nil),
                   png.count <= maxBytes {
                    return try result(
                        data: png,
                        image: image,
                        mediaType: "image/png",
                        pathExtension: "png",
                        displayName: displayName
                    )
                }
                continue
            }

            if let result = try jpegResult(
                image, maxBytes: maxBytes, displayName: displayName
            ) {
                return result
            }
        }

        if alphaImageDecoded {
            for edge in edges {
                guard
                    let image = thumbnail(from: source, edge: edge),
                    let opaqueImage = compositeOnWhite(image)
                else { continue }
                if let result = try jpegResult(
                    opaqueImage, maxBytes: maxBytes, displayName: displayName
                ) {
                    return result
                }
            }
        }

        guard decodedAnyCandidate else {
            throw AssistantAttachmentStoreError.imageDecode(displayName)
        }
        throw AssistantAttachmentStoreError.imageEncode(displayName)
    }

    private static func thumbnail(from source: CGImageSource, edge: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
            ] as CFDictionary
        )
    }

    private static func jpegResult(
        _ image: CGImage,
        maxBytes: Int,
        displayName: String
    ) throws -> NormalizedAssistantImage? {
        for quality in jpegQualities {
            guard let jpeg = encode(image, type: .jpeg, quality: quality) else { continue }
            if jpeg.count <= maxBytes {
                return try result(
                    data: jpeg,
                    image: image,
                    mediaType: "image/jpeg",
                    pathExtension: "jpg",
                    displayName: displayName
                )
            }
        }
        return nil
    }

    private static func descendingEdges(sourceMaximum: Int, limit: Int) -> [Int] {
        var seen = Set<Int>()
        return candidateEdges.compactMap { candidate in
            let edge = min(sourceMaximum, limit, candidate)
            guard edge > 0, seen.insert(edge).inserted else { return nil }
            return edge
        }
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        case .premultipliedLast, .premultipliedFirst, .last, .first, .alphaOnly:
            return true
        @unknown default:
            return true
        }
    }

    private static func compositeOnWhite(_ image: CGImage) -> CGImage? {
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else {
            return nil
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func encode(
        _ image: CGImage,
        type: UTType,
        quality: Double?
    ) -> Data? {
        let encoded = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                encoded,
                type.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        let properties = quality.map {
            [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }

    private static func result(
        data: Data,
        image: CGImage,
        mediaType: String,
        pathExtension: String,
        displayName: String
    ) throws -> NormalizedAssistantImage {
        let thumbnailEdge = min(max(image.width, image.height), thumbnailPixelSize)
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: thumbnailEdge,
                ] as CFDictionary
            )
        else {
            throw AssistantAttachmentStoreError.imageEncode(displayName)
        }

        let thumbnailType: UTType = pathExtension == "png" ? .png : .jpeg
        let thumbnailQuality = thumbnailType == .jpeg ? 0.74 : nil
        guard let thumbnailData = encode(
            thumbnail,
            type: thumbnailType,
            quality: thumbnailQuality
        ) else {
            throw AssistantAttachmentStoreError.imageEncode(displayName)
        }
        let prefix = thumbnailType == .png
            ? "data:image/png;base64,"
            : "data:image/jpeg;base64,"
        return NormalizedAssistantImage(
            data: data,
            mediaType: mediaType,
            pathExtension: pathExtension,
            width: image.width,
            height: image.height,
            thumbnailDataURL: prefix + thumbnailData.base64EncodedString()
        )
    }
}
#endif
