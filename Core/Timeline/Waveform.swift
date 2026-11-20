import AVFoundation
import Foundation

/// Peak levels of a source video's audio above `highPassCutoff`, for
/// drawing on the timeline and finding silences.
///
/// Read once per source and kept in memory; never saved in the project.
public struct Waveform: Sendable, Equatable {
    /// Bins per second of source time.
    public static let binsPerSecond = 100.0

    /// Display level per bin, 0...1: see `levels(fromPeaks:)`.
    public let peaks: [Float]

    public init(peaks: [Float]) {
        self.peaks = peaks
    }

    /// Highest peak between two source times, 0 outside the audio.
    public func peak(fromSeconds start: Double, toSeconds end: Double) -> Float {
        let first = max(Int(start * Self.binsPerSecond), 0)
        let last = min(Int((end * Self.binsPerSecond).rounded(.up)), peaks.count)
        guard first < last else {
            return first < peaks.count ? peaks[first] : 0
        }
        return peaks[first..<last].max() ?? 0
    }

    /// Reads the first audio track of `url`. `nil` when the file has no audio.
    public static func load(from url: URL) async throws -> Waveform? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? CocoaError(.fileReadCorruptFile)
        }

        let samplesPerBin = Int(8000 / binsPerSecond)
        var filter = HighPass(cutoff: highPassCutoff, sampleRate: 8000)
        var peaks: [Float] = []
        var current: Float = 0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            data.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                               destination: bytes.baseAddress!)
            }
            for sample in data {
                current = max(current, abs(filter.process(sample)))
                count += 1
                if count == samplesPerBin {
                    peaks.append(min(current, 1))
                    current = 0
                    count = 0
                }
            }
        }
        if count > 0 { peaks.append(min(current, 1)) }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        return Waveform(peaks: levels(fromPeaks: peaks))
    }

    /// Sound below this, in hertz, is left out of the levels: wind and
    /// handling rumble otherwise fill the pauses between words.
    static let highPassCutoff: Double = 200

    /// Second-order Butterworth high-pass (RBJ biquad), one sample at a time.
    struct HighPass {
        private let b0, b1, b2, a1, a2: Float
        private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        init(cutoff: Double, sampleRate: Double) {
            let w = 2 * Double.pi * cutoff / sampleRate
            let alpha = sin(w) / 2.0.squareRoot()  // sin(w) / 2Q, Q = 1/sqrt(2)
            let a0 = 1 + alpha
            b0 = Float((1 + cos(w)) / 2 / a0)
            b1 = Float(-(1 + cos(w)) / a0)
            b2 = b0
            a1 = Float(-2 * cos(w) / a0)
            a2 = Float((1 - alpha) / a0)
        }

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            return y
        }
    }

    /// Quietest level drawn, in dB below the file's reference peak.
    static let floorDecibels: Float = 45

    /// Maps raw peaks to display levels relative to the file itself, so quiet
    /// speech fills the band as well as loud music. The reference is the 99th
    /// percentile peak, so a single click does not flatten the rest; levels
    /// are in decibels from `floorDecibels` below it (0) to it (1).
    static func levels(fromPeaks peaks: [Float]) -> [Float] {
        let sorted = peaks.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return peaks.map { _ in 0 } }
        let reference = sorted[min(Int(Double(sorted.count) * 0.99), sorted.count - 1)]
        return peaks.map { peak in
            guard peak > 0 else { return 0 }
            let decibels = 20 * log10(peak / reference)
            return min(max(1 + decibels / floorDecibels, 0), 1)
        }
    }
}
