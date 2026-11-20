import AVFoundation
import Foundation
import Testing
@testable import TitleCutCore

/// Record Screen: the captured region and the raw recording's audio mixdown.
struct ScreenRecordingTests {
    @Test func regionFlipsToTheDisplaysTopLeftAndStaysOnScreen() {
        let screen = CGSize(width: 1512, height: 982)
        let rect = ScreenRegion.displayRect(CGRect(x: 100, y: 200, width: 400, height: 300),
                                            screenSize: screen)
        #expect(rect == CGRect(x: 100, y: 482, width: 400, height: 300))
        // Past the top right corner it is cut at the screen's edge.
        let cut = ScreenRegion.displayRect(CGRect(x: 1400, y: 900, width: 300, height: 300),
                                           screenSize: screen)
        #expect(cut == CGRect(x: 1400, y: 0, width: 112, height: 82))
    }

    @Test func pixelSizeIsWholeAndEven() {
        #expect(ScreenRegion.pixelSize(CGSize(width: 400.3, height: 301), scale: 2)
            == CGSize(width: 800, height: 602))
        #expect(ScreenRegion.pixelSize(CGSize(width: 333, height: 0.4), scale: 1)
            == CGSize(width: 332, height: 2))
    }

    @Test func mixdownJoinsEveryAudioTrackIntoOne() async throws {
        let raw = try await Self.writeRaw()
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlecut-mixdown-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: raw)
            try? FileManager.default.removeItem(at: output)
        }
        try await RecordingMixdown.run(from: raw, to: output)

        let asset = AVURLAsset(url: output)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(audio.count == 1)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - Self.seconds) < 0.1)
        // Two in-phase tones of 0.25 each: the mix peaks near 0.5.
        let peak = try Self.peak(of: try #require(audio.first), in: asset)
        #expect(peak > 0.4 && peak < 0.6)
    }

    // MARK: Fixture

    static let seconds = 2.0
    private static let sampleRate = 48_000.0

    /// A raw recording: 2 s of 160x90 grey picture at 30 fps and two mono
    /// AAC tracks, each a 440 Hz tone at 0.25.
    private static func writeRaw() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlecut-raw-\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90,
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90,
            ])
        writer.add(video)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000,
        ]
        let tracks = (0..<2).map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        }
        for track in tracks {
            track.expectsMediaDataInRealTime = false
            writer.add(track)
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let frames = Int(seconds * 30)
        let chunk = 4800
        let chunks = Int(seconds * sampleRate) / chunk
        var frame = 0
        var written = [0, 0]
        while frame < frames || written.contains(where: { $0 < chunks }) {
            var progressed = false
            if frame < frames, video.isReadyForMoreMediaData {
                guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                let picture = try #require(buffer)
                CVPixelBufferLockBaseAddress(picture, [])
                memset(CVPixelBufferGetBaseAddress(picture), 128,
                       CVPixelBufferGetDataSize(picture))
                CVPixelBufferUnlockBaseAddress(picture, [])
                adaptor.append(picture, withPresentationTime: CMTime(value: CMTimeValue(frame),
                                                                     timescale: 30))
                frame += 1
                progressed = true
            }
            for (index, track) in tracks.enumerated()
            where written[index] < chunks && track.isReadyForMoreMediaData {
                track.append(try tone(from: written[index] * chunk, count: chunk))
                written[index] += 1
                // A track with nothing more must say so, or the writer waits for it.
                if written[index] == chunks { track.markAsFinished() }
                progressed = true
            }
            if !progressed { try await Task.sleep(for: .milliseconds(2)) }
        }
        video.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// `count` samples of the tone, starting at sample `first`.
    private static func tone(from first: Int, count: Int) throws -> CMSampleBuffer {
        var samples = (0..<count).map { n in
            Float(0.25 * sin(2 * .pi * 440 * Double(first + n) / sampleRate))
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0,
                                       layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &format)
        let length = count * 4
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length,
                                           blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: length,
                                           flags: kCMBlockBufferAssureMemoryNowFlag,
                                           blockBufferOut: &block)
        let data = try #require(block)
        samples.withUnsafeMutableBytes { bytes in
            _ = CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: data,
                                              offsetIntoDestination: 0, dataLength: length)
        }
        var buffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: data, formatDescription: try #require(format),
            sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(first),
                                          timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer)
        return try #require(buffer)
    }

    /// The largest sample of `track`, ignoring the first and last 0.2 s.
    private static func peak(of track: AVAssetTrack, in asset: AVAsset) throws -> Float {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: 0.2, preferredTimescale: 600),
                                       duration: CMTime(seconds: seconds - 0.4,
                                                        preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var peak: Float = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / 4)
            data.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                               destination: bytes.baseAddress!)
            }
            peak = max(peak, data.map(abs).max() ?? 0)
        }
        return peak
    }
}
