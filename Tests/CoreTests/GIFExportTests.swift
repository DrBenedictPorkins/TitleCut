import Foundation
import ImageIO
import Testing
@testable import TitleCutCore

/// GIF export through `GIFExporter`, read back with ImageIO.
@Suite(.serialized)
struct GIFExportTests {
    @Test func delaysAddUpToTheVideosLength() {
        // 15 fps: 6.67 hundredths a frame, carried so 15 frames last 1 s.
        let delays = GIFExporter.delays(count: 15, framesPerSecond: 15)
        #expect(Set(delays) == [6, 7])
        #expect(delays.reduce(0, +) == 100)
        #expect(GIFExporter.delays(count: 3, framesPerSecond: 10) == [10, 10, 10])
    }

    @Test func framesCoverTheOutput() {
        #expect(GIFExporter.frameTimes(duration: 600, framesPerSecond: 10)
                == [0, 60, 120, 180, 240, 300, 360, 420, 480, 540])
        // A part frame at the end still gets one.
        #expect(GIFExporter.frameTimes(duration: 610, framesPerSecond: 10).count == 11)
        #expect(GIFExporter.frameTimes(duration: 1, framesPerSecond: 24) == [0])
    }

    @Test func sizeKeepsTheShapeAndNeverGrows() {
        #expect(GIFExporter.pixelSize(of: CGSize(width: 1080, height: 1920), width: 480)
                == CGSize(width: 480, height: 853))
        #expect(GIFExporter.pixelSize(of: CGSize(width: 640, height: 360), width: 720)
                == CGSize(width: 640, height: 360))
    }

    /// A solid `width`x`height` image, with an optional white square.
    private func image(width: Int, height: Int, red: CGFloat, square: Bool = false) throws
        -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: red, green: 0.4, blue: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if square {
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: 10, y: 10, width: 8, height: 8))
        }
        return try #require(context.makeImage())
    }

    @Test func writerStoresOnlyWhatChanges() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlecut-writer-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        // An image a pixel short is drawn at exactly the GIF's size.
        let writer = try GIFWriter(width: 64, height: 48, loops: true, sink: .file(handle))
        try writer.add(try image(width: 63, height: 48, red: 0.8), delay: 10)
        let first = writer.byteCount
        try writer.add(try image(width: 64, height: 48, red: 0.8, square: true), delay: 10)
        try writer.add(try image(width: 64, height: 48, red: 0.8, square: true), delay: 10)
        try writer.finish()
        try handle.close()
        // The square's frame stores its 8x8 box; the unchanged one a single pixel.
        #expect(writer.byteCount - first < first)

        let file = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(file) == 3)
        let last = try #require(CGImageSourceCreateImageAtIndex(file, 2, nil))
        #expect(last.width == 64 && last.height == 48)
        // Composited: the background from frame 1 and the square from frame 2.
        let pixels = RenderFixture.pixels(of: last)
        let square = pixels.rgb(x: 14, y: 48 - 14)
        let background = pixels.rgb(x: 40, y: 24)
        #expect(square.r > 240 && square.g > 240 && square.b > 240, "square \(square)")
        #expect(abs(background.r - 204) < 10 && abs(background.g - 102) < 10,
                "background \(background)")
    }

    @Test func lzwRoundTrips() throws {
        // Long and repetitive enough to fill the table and clear it.
        var indices: [UInt8] = []
        for i in 0..<60_000 { indices.append(UInt8((i * 7 + i / 300) % 251)) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlecut-lzw-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        // A 300x200 frame of those indices through a minimal GIF.
        var data = Data("GIF89a".utf8)
        data.append(contentsOf: [44, 1, 200, 0, 0xF7, 0, 0])
        for entry in 0..<256 { data.append(contentsOf: [UInt8(entry), UInt8(255 - entry), 0]) }
        data.append(contentsOf: [0x2C, 0, 0, 0, 0, 44, 1, 200, 0, 0, 8])
        var blocks = LZW.encode(indices)
        while !blocks.isEmpty {
            let n = min(255, blocks.count)
            data.append(UInt8(n))
            data.append(contentsOf: blocks.prefix(n))
            blocks.removeFirst(n)
        }
        data.append(contentsOf: [0, 0x3B])
        try data.write(to: url)
        let file = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = RenderFixture.pixels(of: try #require(
            CGImageSourceCreateImageAtIndex(file, 0, nil)))
        for i in stride(from: 0, to: 60_000, by: 997) {
            let pixel = decoded.rgb(x: i % 300, y: i / 300)
            #expect(abs(pixel.r - Double(indices[i])) <= 2, "pixel \(i): \(pixel.r) vs \(indices[i])")
        }
    }

    @Test func estimateIsNearTheRealSize() async throws {
        let source = try await RenderFixture.numbered.value
        var project = Project.empty
        ProjectCommand.setSource(try await SourceVideo.load(from: source),
                                 segmentID: Fixture.id(1)).apply(to: &project)
        project.segments = [Fixture.video(1, start: 0, duration: 1800)]
        let settings = GIFExporter.Settings(width: 320, framesPerSecond: 10)
        let estimate = try await GIFExporter.estimatedSize(of: project, sourceURL: source,
                                                           settings: settings, watermark: false)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlecut-gif-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: output) }
        try await GIFExporter.export(project, sourceURL: source, to: output, settings: settings,
                                     watermark: false) { _ in }
        let actual = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as! Int
        #expect(Double(estimate) / Double(actual) > 0.5 && Double(estimate) / Double(actual) < 2,
                "estimate \(estimate), actual \(actual)")
    }

    private func export(loops: Bool) async throws -> URL {
        let source = try await RenderFixture.numbered.value
        var project = Project.empty
        ProjectCommand.setSource(try await SourceVideo.load(from: source),
                                 segmentID: Fixture.id(1)).apply(to: &project)
        // src [0, 2 s)
        project.segments = [Fixture.video(1, start: 0, duration: 1200)]
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlecut-gif-\(UUID().uuidString).gif")
        try await GIFExporter.export(project, sourceURL: source, to: output,
                                     settings: .init(width: 320, framesPerSecond: 10,
                                                     loops: loops),
                                     watermark: false) { _ in }
        return output
    }

    @Test func writesEveryFrameAtTheChosenSizeAndLoops() async throws {
        let output = try await export(loops: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let file = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(file) == 20)
        let properties = try #require(CGImageSourceCopyProperties(file, nil) as? [CFString: Any])
        let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        #expect(gif[kCGImagePropertyGIFLoopCount] as? Int == 0)

        let first = try #require(CGImageSourceCreateImageAtIndex(file, 0, nil))
        #expect(first.width == 320 && first.height == 180)
        let frame = try #require(CGImageSourceCopyPropertiesAtIndex(file, 0, nil)
                                 as? [CFString: Any])
        let delay = (frame[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[
            kCGImagePropertyGIFUnclampedDelayTime] as? Double
        #expect(delay == 0.1)

        // Frame 5 is source 0.5 s, fixture frame 15: its colour, within GIF palette error.
        let pixels = RenderFixture.pixels(of: try #require(
            CGImageSourceCreateImageAtIndex(file, 5, nil)))
        let pixel = pixels.rgb(x: 160, y: 90)
        let expected = RenderFixture.colour(forFrame: 15)
        #expect(abs(pixel.r - expected.r) < 20 && abs(pixel.g - expected.g) < 20
                && abs(pixel.b - expected.b) < 20, "got \(pixel), expected \(expected)")
    }

    @Test func playOnceHasNoLoopBlock() async throws {
        // Players loop only with a NETSCAPE2.0 block; ImageIO reads its absence as 1.
        let once = try await export(loops: false)
        let forever = try await export(loops: true)
        defer {
            try? FileManager.default.removeItem(at: once)
            try? FileManager.default.removeItem(at: forever)
        }
        let block = Data("NETSCAPE2.0".utf8)
        #expect(try Data(contentsOf: once).range(of: block) == nil)
        #expect(try Data(contentsOf: forever).range(of: block) != nil)
    }
}
