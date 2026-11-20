import AVFoundation
import Speech

/// On-device speech to text with word timings (macOS 26 `SpeechAnalyzer` and
/// `SpeechTranscriber`). No network service of our own; the system may
/// download the language model once.
///
/// This is the only part of Auto-Captions that cannot run in unit tests;
/// everything after it works on `[TranscriptWord]`.
public enum Transcriber {
    public enum Phase: Sendable, Equatable {
        /// Reading the source's audio.
        case preparing
        /// Downloading the language model, fraction 0...1.
        case downloading(Double)
        /// Fraction of the audio transcribed, 0...1.
        case transcribing(Double)
    }

    public enum TranscribeError: Error, Equatable {
        /// Speech transcription is not available on this Mac.
        case unavailable
        case unsupportedLocale
        /// The source has no audio track.
        case noAudio
        /// The audio could not be read or converted.
        case unreadableAudio
    }

    /// Languages this Mac can transcribe.
    public static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }

    /// The supported language nearest `locale`, if any.
    public static func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: locale)
    }

    /// Transcribes the first audio track of the video at `url`.
    ///
    /// - Parameter progress: Called from any thread as work advances.
    /// - Returns: Words in source time, in time order.
    /// - Throws: `TranscribeError`, a Speech or AVFoundation error, or
    ///   `CancellationError` when the calling task is cancelled.
    public static func transcribe(
        audioOf url: URL, locale: Locale, progress: @escaping @Sendable (Phase) -> Void
    ) async throws -> [TranscriptWord] {
        guard SpeechTranscriber.isAvailable else { throw TranscribeError.unavailable }
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TranscribeError.unsupportedLocale
        }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])

        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]) {
            progress(.downloading(0))
            let observer = Task {
                while !Task.isCancelled {
                    progress(.downloading(request.progress.fractionCompleted))
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { observer.cancel() }
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()

        progress(.preparing)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]) else { throw TranscribeError.unreadableAudio }
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("titlecut-audio-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        let extracted = try await extractAudio(of: url, to: audioURL, format: format)

        let audioFile = try AVAudioFile(forReading: audioURL)
        let analyzer = try await SpeechAnalyzer(inputAudioFile: audioFile,
                                                modules: [transcriber], finishAfterFile: true)
        let seconds = extracted.duration.seconds
        progress(.transcribing(0))
        return try await withTaskCancellationHandler {
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                words += Self.words(in: result.text, offset: extracted.start)
                if seconds > 0 {
                    progress(.transcribing(min(max(result.range.end.seconds / seconds, 0), 1)))
                }
            }
            try Task.checkCancellation()
            return words.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// The words of one result. Each run carrying an audio time range is a
    /// word (several words in one run share its time by length).
    /// Punctuation with no letters is attached to the word before it.
    ///
    /// - Parameter offset: Added to every time: the source time of the audio's start.
    static func words(in text: AttributedString, offset: Tick) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let parts = piece.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !parts.isEmpty else { continue }
            guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self],
                  range.start.isNumeric, range.duration.isNumeric else {
                if let last = words.indices.last { words[last].text += parts.joined() }
                continue
            }
            let start = Ticks.from(range.start) + offset
            let end = Ticks.from(range.end) + offset
            let total = parts.map(\.count).reduce(0, +)
            var cursor = start
            var counted = 0
            for part in parts {
                counted += part.count
                let partEnd = total > 0 ? start + (end - start) * Tick(counted) / Tick(total) : end
                if !part.contains(where: { $0.isLetter || $0.isNumber }),
                   let last = words.indices.last {
                    words[last].text += part
                    words[last].end = max(words[last].end, partEnd)
                } else {
                    words.append(TranscriptWord(text: part, start: cursor, end: partEnd))
                }
                cursor = partEnd
            }
        }
        return words
    }

    /// Writes the first audio track of `url` to `destination` as PCM in
    /// `format`.
    /// - Returns: The source time of the first sample and the audio's length.
    private static func extractAudio(of url: URL, to destination: URL,
                                     format: AVAudioFormat) async throws
        -> (start: Tick, duration: CMTime) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw TranscribeError.noAudio
        }
        let timeRange = try await track.load(.timeRange)
        guard let settings = readerSettings(for: format) else {
            throw TranscribeError.unreadableAudio
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw TranscribeError.unreadableAudio }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? TranscribeError.unreadableAudio
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let file = try AVAudioFile(forWriting: destination, settings: format.settings,
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
        var first: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(frames))
            else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frames),
                into: buffer.mutableAudioBufferList) == noErr
            else { throw TranscribeError.unreadableAudio }
            if first == nil { first = CMSampleBufferGetPresentationTimeStamp(sample) }
            try file.write(from: buffer)
        }
        if reader.status == .failed { throw reader.error ?? TranscribeError.unreadableAudio }
        let start = first.flatMap { $0.isNumeric ? $0 : nil } ?? timeRange.start
        return (Ticks.from(start), timeRange.duration)
    }

    /// Linear PCM reader settings that produce exactly `format`.
    private static func readerSettings(for format: AVAudioFormat) -> [String: Any]? {
        let (bits, isFloat): (Int, Bool)
        switch format.commonFormat {
        case .pcmFormatFloat32: (bits, isFloat) = (32, true)
        case .pcmFormatFloat64: (bits, isFloat) = (64, true)
        case .pcmFormatInt16: (bits, isFloat) = (16, false)
        case .pcmFormatInt32: (bits, isFloat) = (32, false)
        default: return nil
        }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: bits,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved,
        ]
    }
}
