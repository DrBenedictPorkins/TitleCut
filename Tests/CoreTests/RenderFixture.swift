import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import TitleCutCore

/// Test videos generated with `AVAssetWriter` at test time (§11.2).
/// No binary fixtures are committed.
enum RenderFixture {
    static let frameCount = 150
    static let fps: Int32 = 30
    static let size = CGSize(width: 640, height: 360)

    /// 6 levels per channel, 45 apart, so codec error cannot cross a level.
    static let levels: [Double] = [10, 55, 100, 145, 190, 235]

    /// The solid colour that encodes frame `n` (8-bit RGB).
    static func colour(forFrame n: Int) -> (r: Double, g: Double, b: Double) {
        (levels[n % 6], levels[(n / 6) % 6], levels[(n / 36) % 6])
    }

    /// 5 s, 640x360, 30 fps, each frame a solid colour encoding its number.
    static let numbered = Task { try await write(name: "numbered", transform: .identity) { n in
        let c = colour(forFrame: n)
        return { _ in c }
    } }

    /// 640x360 frames stored with a 90-degree preferred transform (portrait).
    /// Stored top half is red, bottom half is blue.
    static let rotated = Task {
        try await write(name: "rotated",
                        transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 360, ty: 0)) { _ in
            { y in y < 180 ? (230, 20, 20) : (20, 20, 230) }
        }
    }

    /// Writes an H.264 file. `paint(frame)` returns a colour per stored row (top = 0).
    private static func write(
        name: String, transform: CGAffineTransform,
        paint: @escaping (Int) -> (Int) -> (r: Double, g: Double, b: Double)
    ) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlecut-\(name)-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
            ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        for n in 0..<frameCount {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            fill(buffer, rows: paint(n))
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(n),
                                                                timescale: fps))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        return url
    }

    private static func fill(_ buffer: CVPixelBuffer,
                             rows: (Int) -> (r: Double, g: Double, b: Double)) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<CVPixelBufferGetHeight(buffer) {
            let c = rows(y)
            let row = base + y * stride
            for x in 0..<CVPixelBufferGetWidth(buffer) {
                row[x * 4] = UInt8(c.b); row[x * 4 + 1] = UInt8(c.g)
                row[x * 4 + 2] = UInt8(c.r); row[x * 4 + 3] = 255
            }
        }
    }

    // MARK: Reading frames

    /// A frame pulled through the video composition, as 8-bit RGBA rows (top = 0).
    struct Pixels {
        let width: Int
        let height: Int
        let data: [UInt8]

        func rgb(x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
            let i = (y * width + x) * 4
            return (Double(data[i]), Double(data[i + 1]), Double(data[i + 2]))
        }
    }

    static func pixels(of image: CGImage) -> Pixels {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        // Draw in the image's own colour space so values are not converted.
        let space = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        data.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(width: width, height: height, data: data)
    }

    /// Source frame `n` decoded directly from the file, without any composition.
    static func directFrame(_ n: Int, from url: URL) async throws -> Pixels {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: (Double(n) + 0.5) / Double(fps), preferredTimescale: 600)
        return pixels(of: try await generator.image(at: time).image)
    }

    /// Builds the composition for `project` and pulls the frame at output time `seconds`.
    static func frame(of project: Project, from url: URL, at seconds: Double,
                      watermark: Bool = false) async throws -> Pixels {
        let asset = AVURLAsset(url: url)
        let tracks = try #require(try await CompositionBuilder.SourceTracks.load(from: asset))
        let built = try CompositionBuilder.build(project, tracks: tracks, watermark: watermark)
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return pixels(of: try await generator.image(at: time).image)
    }
}

