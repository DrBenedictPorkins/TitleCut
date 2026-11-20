import AVFoundation

/// Writes the edited project to an animated GIF: the same frames as the
/// MP4 export, scaled down, without sound, through `GIFWriter` one frame at
/// a time.
public enum GIFExporter {
    public struct Settings: Sendable, Equatable {
        /// Width of the GIF in pixels; never more than the project's width.
        public var width: Int
        public var framesPerSecond: Int
        /// Plays forever when `true`; once when `false`.
        public var loops: Bool

        public init(width: Int = 480, framesPerSecond: Int = 15, loops: Bool = true) {
            self.width = width
            self.framesPerSecond = framesPerSecond
            self.loops = loops
        }

        public static let widths = [320, 480, 720]
        public static let framesPerSecondChoices = [10, 15, 24]
    }

    /// Length above which the export sheet warns that the GIF will be large.
    public static let longDuration: Tick = Ticks.perSecond * 15

    /// `export(_:sourceURLs:to:settings:watermark:progress:)` for a project
    /// whose clips all play its first video, at `sourceURL`.
    public static func export(_ project: Project, sourceURL: URL, to destination: URL,
                              settings: Settings, watermark: Bool,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        try await export(project, sourceURLs: [nil: sourceURL], to: destination,
                         settings: settings, watermark: watermark, progress: progress)
    }

    /// Exports `project` to `destination` as a GIF. A file already there is
    /// replaced; on failure or cancellation nothing is left there.
    ///
    /// - Parameters:
    ///   - sourceURLs: The resolved videos, keyed by `VideoSegment.sourceID`.
    ///   - watermark: Draws the `Watermark` wordmark over every frame.
    ///   - progress: Called with the fraction completed, 0...1, from any thread.
    /// - Throws: `Exporter.ExportError`, a frame's error, or
    ///   `CancellationError` when the calling task is cancelled.
    public static func export(_ project: Project, sourceURLs: [UUID?: URL], to destination: URL,
                              settings: Settings, watermark: Bool,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let frames = try await Frames(project, sourceURLs: sourceURLs, settings: settings,
                                      watermark: watermark)
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            let writer = try frames.writer(loops: settings.loops, sink: .file(handle))
            for (index, time) in frames.times.enumerated() {
                try Task.checkCancellation()
                try writer.add(try await frames.image(at: time), delay: frames.delays[index])
                progress(Double(index + 1) / Double(frames.times.count))
            }
            try writer.finish()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        progress(1)
    }

    /// About how many bytes `export` would write: the first frame of three
    /// pairs of frames spread over the video stands for a full frame, the
    /// second for each frame after it.
    /// - Throws: As `export`.
    public static func estimatedSize(of project: Project, sourceURL: URL, settings: Settings,
                                     watermark: Bool) async throws -> Int {
        try await estimatedSize(of: project, sourceURLs: [nil: sourceURL], settings: settings,
                                watermark: watermark)
    }

    /// `estimatedSize(of:sourceURL:settings:watermark:)` with every video's
    /// file, keyed by `VideoSegment.sourceID`.
    public static func estimatedSize(of project: Project, sourceURLs: [UUID?: URL],
                                     settings: Settings, watermark: Bool) async throws -> Int {
        let frames = try await Frames(project, sourceURLs: sourceURLs, settings: settings,
                                      watermark: watermark)
        let count = frames.times.count
        guard count > 1 else {
            let writer = try frames.writer(loops: settings.loops, sink: .count)
            try writer.add(try await frames.image(at: frames.times[0]), delay: frames.delays[0])
            try writer.finish()
            return writer.byteCount
        }
        var full = 0, change = 0, header = 0
        let samples = [count / 6, count / 2, count * 5 / 6].map { min($0, count - 2) }
        for sample in samples {
            try Task.checkCancellation()
            let writer = try frames.writer(loops: settings.loops, sink: .count)
            header = writer.byteCount
            let time = frames.times[sample]
            try writer.add(try await frames.image(at: time), delay: frames.delays[sample])
            let afterFirst = writer.byteCount
            try writer.add(try await frames.image(at: frames.times[sample + 1]),
                           delay: frames.delays[sample + 1])
            full += afterFirst - header
            change += writer.byteCount - afterFirst
        }
        return header + full / samples.count + (count - 1) * change / samples.count + 1
    }

    /// The composition's frames at the GIF's size and rate.
    private struct Frames {
        let generator: AVAssetImageGenerator
        let size: CGSize
        let times: [Tick]
        let delays: [Int]

        init(_ project: Project, sourceURLs: [UUID?: URL], settings: Settings,
             watermark: Bool) async throws {
            guard !project.segments.isEmpty else { throw Exporter.ExportError.nothingToExport }
            let sources = try await Exporter.loadSources(of: project, from: sourceURLs)
            let built = try CompositionBuilder.build(project, sources: sources,
                                                     watermark: watermark)
            guard let videoComposition = built.videoComposition else {
                throw Exporter.ExportError.nothingToExport
            }
            size = GIFExporter.pixelSize(of: CompositionBuilder.renderSize(project),
                                         width: settings.width)
            generator = AVAssetImageGenerator(asset: built.composition)
            generator.videoComposition = videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            // A pixel larger, so rounding never leaves the frame short; the
            // writer draws it at exactly `size`.
            generator.maximumSize = CGSize(width: size.width + 1, height: size.height + 1)
            times = GIFExporter.frameTimes(duration: TimelineMath.outputDuration(project),
                                           framesPerSecond: settings.framesPerSecond)
            delays = GIFExporter.delays(count: times.count,
                                        framesPerSecond: settings.framesPerSecond)
        }

        func writer(loops: Bool, sink: GIFWriter.Sink) throws -> GIFWriter {
            try GIFWriter(width: Int(size.width), height: Int(size.height), loops: loops,
                          sink: sink)
        }

        func image(at time: Tick) async throws -> CGImage {
            try await generator.image(at: Ticks.cmTime(time)).image
        }
    }

    /// The GIF's size: `width` (no wider than `renderSize`), keeping the
    /// shape, in whole pixels.
    static func pixelSize(of renderSize: CGSize, width: Int) -> CGSize {
        let w = min(Double(width), renderSize.width.rounded())
        return CGSize(width: w, height: max((w * renderSize.height / renderSize.width).rounded(), 1))
    }

    /// Output times of the frames: one every 1/`framesPerSecond`, from 0,
    /// at least one.
    static func frameTimes(duration: Tick, framesPerSecond: Int) -> [Tick] {
        let fps = Tick(max(framesPerSecond, 1))
        let count = max(Int((duration * fps + Ticks.perSecond - 1) / Ticks.perSecond), 1)
        return (0..<count).map { Tick($0) * Ticks.perSecond / fps }
    }

    /// Each frame's delay in hundredths of a second, the GIF's unit. Rounding
    /// is carried from frame to frame so the total stays on time.
    static func delays(count: Int, framesPerSecond: Int) -> [Int] {
        let fps = max(framesPerSecond, 1)
        func at(_ frame: Int) -> Int { (frame * 100 + fps / 2) / fps }
        return (0..<count).map { at($0 + 1) - at($0) }
    }
}
