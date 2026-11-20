import AVFoundation

/// Writes the edited project to an MP4 file (§9).
///
/// Uses the same `CompositionBuilder` output as the preview, so every frame
/// goes through `TitleCutCompositor` and titles export exactly as previewed.
public enum Exporter {
    public enum ExportError: Error, Equatable {
        /// The source has no video track, or could not be read.
        case sourceUnreadable
        /// The project has no segments.
        case nothingToExport
        /// This Mac cannot write `codec` to an MP4 with this composition.
        case codecUnavailable(Codec)
    }

    /// `export(_:sourceURLs:to:codec:watermark:progress:)` for a project
    /// whose clips all play its first video, at `sourceURL`.
    public static func export(_ project: Project, sourceURL: URL, to destination: URL,
                              codec: Codec, watermark: Bool,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        try await export(project, sourceURLs: [nil: sourceURL], to: destination, codec: codec,
                         watermark: watermark, progress: progress)
    }

    /// Exports `project` to `destination` as an MP4 at the project's output size.
    ///
    /// A file already at `destination` is replaced. On failure or cancellation
    /// nothing is left at `destination`.
    ///
    /// - Parameters:
    ///   - sourceURLs: The resolved videos, keyed by `VideoSegment.sourceID`.
    ///   - watermark: Draws the `Watermark` wordmark over every frame.
    ///   - progress: Called with the fraction completed, 0...1, from any thread.
    /// - Throws: `ExportError`, the session's error, or `CancellationError`
    ///   when the calling task is cancelled.
    ///   - size: `ExportSize.original` writes the project's size at the
    ///     highest quality; the others scale it down at a set data rate.
    public static func export(_ project: Project, sourceURLs: [UUID?: URL], to destination: URL,
                              codec: Codec, size: ExportSize = .original, watermark: Bool,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !project.segments.isEmpty else { throw ExportError.nothingToExport }
        if size != .original {
            try await exportScaled(size.scaled(project), size: size, sourceURLs: sourceURLs,
                                   to: destination, codec: codec, watermark: watermark,
                                   progress: progress)
            return
        }
        let sources = try await loadSources(of: project, from: sourceURLs)
        let music = await CompositionBuilder.MusicTracks.load(for: project)
        let built = try CompositionBuilder.build(project, sources: sources, music: music,
                                                 watermark: watermark)
        guard let videoComposition = built.videoComposition else {
            throw ExportError.nothingToExport
        }

        let preset = presetName(for: codec)
        guard await AVAssetExportSession.compatibility(ofExportPreset: preset,
                                                       with: built.composition,
                                                       outputFileType: .mp4),
              let session = AVAssetExportSession(asset: built.composition, presetName: preset)
        else { throw ExportError.codecUnavailable(codec) }
        session.videoComposition = videoComposition
        session.audioMix = built.audioMix

        // The session refuses to write over an existing file; the save panel
        // has already confirmed the replacement.
        try? FileManager.default.removeItem(at: destination)

        let states = session.states(updateInterval: 0.1)
        let observer = Task {
            for await state in states {
                if case .exporting(let fraction) = state {
                    progress(fraction.fractionCompleted)
                }
            }
        }
        defer { observer.cancel() }
        do {
            try await session.export(to: destination, as: .mp4)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        progress(1)
    }

    /// Writes `project` (already `ExportSize.scaled`) with an asset writer,
    /// at `size`'s video data rate and AAC sound.
    private static func exportScaled(_ project: Project, size: ExportSize,
                                     sourceURLs: [UUID?: URL], to destination: URL,
                                     codec: Codec, watermark: Bool,
                                     progress: @escaping @Sendable (Double) -> Void) async throws {
        let sources = try await loadSources(of: project, from: sourceURLs)
        let music = await CompositionBuilder.MusicTracks.load(for: project)
        let built = try CompositionBuilder.build(project, sources: sources, music: music,
                                                 watermark: watermark)
        guard let videoComposition = built.videoComposition,
              let bitRate = size.videoBitRate(for: project, codec: codec) else {
            throw ExportError.nothingToExport
        }
        let renderSize = CompositionBuilder.renderSize(project)
        let duration = built.composition.duration.seconds
        let rate = min(project.output.frameRate, ExportSize.maximumFrameRate)

        try? FileManager.default.removeItem(at: destination)
        let reader = try AVAssetReader(asset: built.composition)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoTracks = try await built.composition.loadTracks(withMediaType: .video)
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                                kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitRate,
            AVVideoExpectedSourceFrameRateKey: rate,
            AVVideoMaxKeyFrameIntervalKey: Int(rate * 2),
        ]
        if codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
            throw ExportError.codecUnavailable(codec)
        }
        reader.add(videoOutput)
        writer.add(videoInput)

        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        var audio: (output: AVAssetReaderAudioMixOutput, input: AVAssetWriterInput)?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
            ])
            output.audioMix = built.audioMix
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: ExportSize.audioBitRate,
            ])
            input.expectsMediaDataInRealTime = false
            if reader.canAdd(output), writer.canAdd(input) {
                reader.add(output)
                writer.add(input)
                audio = (output, input)
            }
        }

        guard reader.startReading(), writer.startWriting() else {
            try? FileManager.default.removeItem(at: destination)
            throw writer.error ?? reader.error ?? ExportError.sourceUnreadable
        }
        writer.startSession(atSourceTime: .zero)

        let video = Pump(output: videoOutput, input: videoInput, label: "video")
        let sound = audio.map { Pump(output: $0.output, input: $0.input, label: "audio") }
        let stopper = Stopper(reader: reader, writer: writer)
        do {
            try await withTaskCancellationHandler {
                async let videoDone: Void = video.run { time in
                    if duration > 0 { progress(min(time / duration, 0.99)) }
                }
                async let soundDone: Void = sound?.run { _ in } ?? ()
                _ = try await (videoDone, soundDone)
            } onCancel: {
                stopper.stop()
            }
            try Task.checkCancellation()
            guard reader.status != .failed else { throw reader.error ?? ExportError.sourceUnreadable }
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? ExportError.codecUnavailable(codec)
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        progress(1)
    }

    /// Stops a reader and writer from the cancellation handler, which may
    /// run on any thread; both calls are thread-safe.
    private final class Stopper: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter

        init(reader: AVAssetReader, writer: AVAssetWriter) {
            self.reader = reader
            self.writer = writer
        }

        func stop() {
            reader.cancelReading()
            writer.cancelWriting()
        }
    }

    /// Copies samples from a reader output to a writer input as the input
    /// asks for them, then marks the input finished.
    private final class Pump: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let queue: DispatchQueue
        /// Set once the input is finished or failed; touched only on `queue`.
        private var finished = false

        init(output: AVAssetReaderOutput, input: AVAssetWriterInput, label: String) {
            self.output = output
            self.input = input
            queue = DispatchQueue(label: "com.byteclub.titlecut.export.\(label)")
        }

        /// Returns when every sample is written. `time` gets each written
        /// sample's time in seconds.
        func run(time: @escaping @Sendable (Double) -> Void) async throws {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !finished else { return }
                    while input.isReadyForMoreMediaData {
                        guard let sample = output.copyNextSampleBuffer() else {
                            finished = true
                            input.markAsFinished()
                            done.resume()
                            return
                        }
                        if !input.append(sample) {
                            finished = true
                            done.resume(throwing: CancellationError())
                            return
                        }
                        time(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                    }
                }
            }
        }
    }

    /// The tracks of the first video and of every video `project`'s clips play.
    /// - Throws: `ExportError.sourceUnreadable` when one is missing from
    ///   `urls` or cannot be read.
    public static func loadSources(of project: Project, from urls: [UUID?: URL]) async throws
        -> [UUID?: CompositionBuilder.SourceTracks] {
        var keys: Set<UUID?> = [nil]
        for case .video(let video) in project.segments { keys.insert(video.sourceID) }
        var sources: [UUID?: CompositionBuilder.SourceTracks] = [:]
        for key in keys {
            guard let url = urls[key],
                  let tracks = try? await CompositionBuilder.SourceTracks.load(
                      from: AVURLAsset(url: url)) else { throw ExportError.sourceUnreadable }
            sources[key] = tracks
        }
        return sources
    }

    /// Highest-quality preset for `codec`; the render size comes from the
    /// video composition, which is the project's output size.
    static func presetName(for codec: Codec) -> String {
        switch codec {
        case .h264: AVAssetExportPresetHighestQuality
        case .hevc: AVAssetExportPresetHEVCHighestQuality
        }
    }
}
