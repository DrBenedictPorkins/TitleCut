import AVFoundation
import Foundation

/// Turns a raw screen recording, whose system sound and microphone are
/// separate tracks, into a movie with one audio track: the rest of TitleCut
/// plays only a video's first audio track. The picture is copied as is.
public enum RecordingMixdown {
    public enum Failure: LocalizedError {
        case noVideo
        case failed

        public var errorDescription: String? {
            switch self {
            case .noVideo: "The recording has no picture."
            case .failed: "The recording could not be written."
            }
        }
    }

    /// Writes `raw` to `output` as a QuickTime movie: its first video track
    /// unchanged and every audio track mixed into one stereo AAC track.
    public static func run(from raw: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: raw)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.noVideo
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let (formats, transform) = try await videoTrack.load(.formatDescriptions,
                                                             .preferredTransform)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let mix = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            mix.alwaysCopiesSampleData = false
            reader.add(mix)
            audioOutput = mix
        }

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                            sourceFormatHint: formats.first)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        }

        guard reader.startReading() else { throw reader.error ?? Failure.failed }
        guard writer.startWriting() else { throw writer.error ?? Failure.failed }
        guard let first = videoOutput.copyNextSampleBuffer() else { throw Failure.noVideo }
        writer.startSession(atSourceTime: first.presentationTimeStamp)

        // Feeds whichever input has room, so neither waits on the other.
        var pendingVideo: CMSampleBuffer? = first
        var videoDone = false
        var audioDone = audioInput == nil
        while !videoDone || !audioDone {
            try Task.checkCancellation()
            var progressed = false
            if !videoDone, videoInput.isReadyForMoreMediaData {
                if let buffer = pendingVideo ?? videoOutput.copyNextSampleBuffer() {
                    pendingVideo = nil
                    guard videoInput.append(buffer) else { throw writer.error ?? Failure.failed }
                } else {
                    videoInput.markAsFinished()
                    videoDone = true
                }
                progressed = true
            }
            if !audioDone, let audioInput, let audioOutput, audioInput.isReadyForMoreMediaData {
                if let buffer = audioOutput.copyNextSampleBuffer() {
                    guard audioInput.append(buffer) else { throw writer.error ?? Failure.failed }
                } else {
                    audioInput.markAsFinished()
                    audioDone = true
                }
                progressed = true
            }
            if !progressed { try await Task.sleep(for: .milliseconds(2)) }
        }
        if reader.status == .failed { throw reader.error ?? Failure.failed }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.failed }
    }
}
