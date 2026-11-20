import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Frozen frames: grabbed from the source as PNGs, saved in the package at
/// `stills/<fileName>`, and read from a cache folder while a project is open,
/// as `MusicFiles` does for songs.
public enum StillFiles {
    public enum GrabError: LocalizedError, Equatable {
        case unreadable
        case unreadableImage

        public var errorDescription: String? {
            switch self {
            case .unreadable: "The frame could not be read from the video."
            case .unreadableImage: "The picture could not be read."
            }
        }
    }

    /// `~/Library/Caches/<bundle>/Stills`, created on demand.
    public static var cacheFolder: URL { PackageFiles.cacheFolder("Stills") }

    public static func url(for fileName: String) -> URL {
        cacheFolder.appending(path: fileName)
    }

    /// Grabs the frame at `sourceTime` of the video at `url`, upright and at
    /// full size, and stores it in the cache as `<id>.png`.
    ///
    /// - Parameter crop: The part to keep, normalised with a top-left origin;
    ///   see `visibleRect(sourceSize:renderSize:framing:)`.
    public static func grab(from url: URL, at sourceTime: Tick, id: UUID,
                            crop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) async throws
        -> StillImage {
        try await grab(from: url, at: sourceTime, id: id, crops: [crop], stacked: false)
    }

    /// As `grab(from:at:id:crop:)`, keeping each of `crops` and joining
    /// them at the first one's size: top to bottom when `stacked`, else
    /// left to right. See `visibleRects(sourceSize:renderSize:clip:)`.
    public static func grab(from url: URL, at sourceTime: Tick, id: UUID,
                            crops: [CGRect], stacked: Bool) async throws -> StillImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let whole: CGImage
        do {
            whole = try await generator.image(at: Ticks.cmTime(sourceTime)).image
        } catch {
            throw GrabError.unreadable
        }
        let parts = try crops.map { crop in
            let pixels = CGRect(x: crop.minX * CGFloat(whole.width),
                                y: crop.minY * CGFloat(whole.height),
                                width: crop.width * CGFloat(whole.width),
                                height: crop.height * CGFloat(whole.height)).integral
            guard let part = whole.cropping(to: pixels) else { throw GrabError.unreadable }
            return part
        }
        guard let image = parts.count == 1 ? parts.first : join(parts, stacked: stacked) else {
            throw GrabError.unreadable
        }
        let fileName = "\(id.uuidString).png"
        let destination = Self.url(for: fileName)
        guard let writer = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw GrabError.unreadable
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw GrabError.unreadable }
        return StillImage(id: id, fileName: fileName, capturedAt: sourceTime,
                          pixelSize: CGSize(width: image.width, height: image.height))
    }

    /// Longest side kept when importing a picture, in pixels.
    public static let maximumImportedSide = 4096

    /// Reads the picture at `url` (JPEG, PNG, HEIC or any type ImageIO
    /// reads), turned upright and no larger than `maximumImportedSide`, and
    /// stores it in the cache as `<id>.png`.
    public static func importImage(from url: URL, id: UUID) throws -> StillImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maximumImportedSide,
              ] as CFDictionary) else { throw GrabError.unreadableImage }
        let fileName = "\(id.uuidString).png"
        guard let writer = CGImageDestinationCreateWithURL(
            Self.url(for: fileName) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw GrabError.unreadableImage
        }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else { throw GrabError.unreadableImage }
        return StillImage(id: id, fileName: fileName, capturedAt: nil,
                          pixelSize: CGSize(width: image.width, height: image.height))
    }

    /// `parts` side by side, or top to bottom, each drawn at the first
    /// one's size.
    private static func join(_ parts: [CGImage], stacked: Bool) -> CGImage? {
        guard let first = parts.first else { return nil }
        let cell = CGSize(width: first.width, height: first.height)
        let size = stacked ? CGSize(width: cell.width, height: cell.height * CGFloat(parts.count))
                           : CGSize(width: cell.width * CGFloat(parts.count), height: cell.height)
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        for (index, part) in parts.enumerated() {
            // Core Graphics' origin is bottom-left: the first part is on top.
            let origin = stacked
                ? CGPoint(x: 0, y: size.height - cell.height * CGFloat(index + 1))
                : CGPoint(x: cell.width * CGFloat(index), y: 0)
            context.draw(part, in: CGRect(origin: origin, size: cell))
        }
        return context.makeImage()
    }

    /// The parts of a source frame of `sourceSize` that an output of
    /// `renderSize` shows of `clip`: one, or one per half when it is split
    /// screen (`SplitScreen.halves`). For `grab(from:at:id:crops:stacked:)`
    /// with `SplitScreen.isStacked(renderSize)`.
    public static func visibleRects(sourceSize: CGSize, renderSize: CGSize,
                                    clip: VideoSegment) -> [CGRect] {
        guard let split = clip.split else {
            return [clip.frame.visibleRect(sourceSize: sourceSize, in: renderSize)]
        }
        let half = SplitScreen.halfSize(of: renderSize)
        return [split.first, split.second].map {
            $0.visibleRect(sourceSize: sourceSize, in: half)
        }
    }

    /// The part of a source frame of `sourceSize` that an output of
    /// `renderSize` shows, with the clip's `framing` (`VideoSegment.framing`)
    /// across a wider picture, centred on a taller one, unzoomed. Normalised,
    /// top-left origin; the whole frame when the shapes match.
    public static func visibleRect(sourceSize: CGSize, renderSize: CGSize,
                                   framing: Double) -> CGRect {
        ClipFraming(x: framing).visibleRect(sourceSize: sourceSize, in: renderSize)
    }

    static func extract(from package: FileWrapper) {
        PackageFiles.extract(ProjectFile.stillsFolderName, from: package, to: cacheFolder)
    }

    /// The package's `stills/` folder with every still a segment shows.
    static func folder(for project: Project, existing: FileWrapper?) throws -> FileWrapper? {
        let used = Set(project.segments.compactMap { segment -> UUID? in
            if case .still(let still) = segment { still.stillID } else { nil }
        })
        let names = Set(project.stills.filter { used.contains($0.id) }.map(\.fileName))
        return try PackageFiles.folder(ProjectFile.stillsFolderName, names: names,
                                       existing: existing, cache: cacheFolder)
    }
}
