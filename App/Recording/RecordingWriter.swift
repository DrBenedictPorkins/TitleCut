import AVFoundation
import ScreenCaptureKit
import TitleCutCore

/// Writes a screen capture to a raw movie: the picture at a steady 30 frames
/// a second, system sound and the microphone as separate audio tracks
/// (`RecordingMixdown` joins them). Everything after `init` runs on `queue`.
final class RecordingWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let frameRate: Int32 = 30

    let queue = DispatchQueue(label: "com.byteclub.titlecut.recording")
    let url: URL
    /// Called on `queue` when the system ends the capture on its own.
    var stoppedBySystem: (@Sendable () -> Void)?

    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let systemAudio: AVAssetWriterInput
    private let microphone: AVAssetWriterInput?
    /// The first frame's time; the recording's time zero.
    private var start: CMTime?
    /// The next frame slot to fill, counted from `start`.
    private var nextFrame: Int64 = 0
    /// The last frame written, repeated while the screen is unchanged.
    private var lastPicture: CVPixelBuffer?

    init(url: URL, pixelSize: CGSize, microphone withMicrophone: Bool) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 6, 2_000_000),
                AVVideoExpectedSourceFrameRateKey: Self.frameRate,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
                                                       sourcePixelBufferAttributes: nil)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        systemAudio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        systemAudio.expectsMediaDataInRealTime = true
        microphone = withMicrophone
            ? AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings) : nil
        microphone?.expectsMediaDataInRealTime = true
        super.init()
        writer.add(video)
        writer.add(systemAudio)
        if let microphone { writer.add(microphone) }
        guard writer.startWriting() else {
            throw writer.error ?? RecordingMixdown.Failure.failed
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard buffer.isValid, writer.status == .writing else { return }
        switch type {
        case .screen: appendPicture(buffer)
        case .audio: appendSound(buffer, to: systemAudio)
        case .microphone: if let microphone { appendSound(buffer, to: microphone) }
        @unknown default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stoppedBySystem?()
    }

    /// A new picture: repeats the last one into any slots it missed, then
    /// takes the slot nearest its time. Frames the encoder has no room for
    /// are dropped.
    private func appendPicture(_ buffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
                  buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: raw) == .complete,
              let picture = buffer.imageBuffer else { return }
        let time = buffer.presentationTimeStamp
        if start == nil {
            start = time
            writer.startSession(atSourceTime: time)
        }
        let slot = self.slot(at: time)
        fill(upTo: slot)
        if slot >= nextFrame, video.isReadyForMoreMediaData,
           adaptor.append(picture, withPresentationTime: self.time(ofSlot: slot)) {
            nextFrame = slot + 1
        }
        lastPicture = picture
    }

    private func appendSound(_ buffer: CMSampleBuffer, to input: AVAssetWriterInput) {
        guard let start, buffer.presentationTimeStamp >= start,
              input.isReadyForMoreMediaData else { return }
        input.append(buffer)
    }

    private func slot(at time: CMTime) -> Int64 {
        guard let start else { return 0 }
        return Int64(((time - start).seconds * Double(Self.frameRate)).rounded())
    }

    private func time(ofSlot slot: Int64) -> CMTime {
        (start ?? .zero) + CMTime(value: slot, timescale: Self.frameRate)
    }

    /// Repeats the last picture into the slots before `slot`.
    private func fill(upTo slot: Int64) {
        guard let lastPicture else { return }
        while nextFrame < slot, video.isReadyForMoreMediaData,
              adaptor.append(lastPicture, withPresentationTime: time(ofSlot: nextFrame)) {
            nextFrame += 1
        }
        // Slots the encoder had no room for are skipped.
        nextFrame = max(nextFrame, slot)
    }

    // MARK: Finishing

    /// Ends the movie at host time `end`, holding the last picture until
    /// then. Returns `false` when no picture was ever captured; the file is
    /// then removed.
    func finish(at end: CMTime) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard let start, writer.status == .writing else {
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    if writer.status == .failed, let error = writer.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: false)
                    }
                    return
                }
                let last = max(slot(at: end), nextFrame)
                fill(upTo: last)
                video.markAsFinished()
                systemAudio.markAsFinished()
                microphone?.markAsFinished()
                writer.endSession(atSourceTime: max(time(ofSlot: last), start))
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume(returning: true)
                    } else {
                        continuation.resume(throwing: writer.error
                                            ?? RecordingMixdown.Failure.failed)
                    }
                }
            }
        }
    }
}
