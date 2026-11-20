import Foundation
import Testing
@testable import TitleCutCore

struct WaveformTests {
    // 100 bins per second: bin n covers n/100 ..< (n+1)/100 s.
    let waveform = Waveform(peaks: [0.1, 0.9, 0.2, 0.4])

    @Test func peakIsTheHighestBinInTheRange() {
        #expect(waveform.peak(fromSeconds: 0, toSeconds: 0.04) == 0.9)
        #expect(waveform.peak(fromSeconds: 0.02, toSeconds: 0.04) == 0.4)
    }

    @Test func rangeInsideOneBinReadsThatBin() {
        #expect(waveform.peak(fromSeconds: 0.011, toSeconds: 0.011) == 0.9)
    }

    @Test func outsideTheAudioIsSilent() {
        #expect(waveform.peak(fromSeconds: 5, toSeconds: 6) == 0)
        #expect(Waveform(peaks: []).peak(fromSeconds: 0, toSeconds: 1) == 0)
    }
}

struct WaveformLevelTests {
    @Test func quietAudioIsScaledToItsOwnLoudestPart() {
        let levels = Waveform.levels(fromPeaks: [0.01, 0.02, 0.0])
        #expect(levels[1] == 1)
        #expect(levels[0] > 0.8)
        #expect(levels[2] == 0)
    }

    @Test func silenceStaysFlat() {
        #expect(Waveform.levels(fromPeaks: [0, 0]) == [0, 0])
    }

    /// Peak of a sine at `hertz` after the high-pass settles.
    private func filteredPeak(hertz: Double) -> Float {
        var filter = Waveform.HighPass(cutoff: Waveform.highPassCutoff, sampleRate: 8000)
        var peak: Float = 0
        for n in 0..<8000 {
            let y = filter.process(Float(sin(2 * Double.pi * hertz * Double(n) / 8000)))
            if n > 4000 { peak = max(peak, abs(y)) }
        }
        return peak
    }

    @Test func rumbleIsLeftOutAndSpeechKept() {
        #expect(filteredPeak(hertz: 50) < 0.1)
        #expect(filteredPeak(hertz: 200) > 0.65 && filteredPeak(hertz: 200) < 0.75)
        #expect(filteredPeak(hertz: 1000) > 0.95)
    }
}
