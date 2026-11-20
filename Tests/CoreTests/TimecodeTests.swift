import Testing
@testable import TitleCutCore

struct TimecodeTests {
    @Test func zero() {
        #expect(Timecode.string(seconds: 0, frameRate: 30) == "00:00:00:00")
    }

    @Test func halfSecondAt30() {
        #expect(Timecode.string(seconds: 1.5, frameRate: 30) == "00:00:01:15")
    }

    @Test func hoursMinutesSecondsFramesAt25() {
        #expect(Timecode.string(seconds: 3661 + 5.0 / 25, frameRate: 25) == "01:01:01:05")
    }

    @Test func minutesRollOver() {
        #expect(Timecode.string(seconds: 220, frameRate: 30) == "00:03:40:00")
    }

    @Test func invalidTimeFormatsAsZero() {
        #expect(Timecode.string(seconds: -1, frameRate: 30) == "00:00:00:00")
        #expect(Timecode.string(seconds: .nan, frameRate: 30) == "00:00:00:00")
        #expect(Timecode.string(seconds: .infinity, frameRate: 30) == "00:00:00:00")
    }

    @Test func invalidRateFallsBack() {
        #expect(Timecode.string(seconds: 0.5, frameRate: 0) == "00:00:00:15")
        #expect(Timecode.string(seconds: 0.5, frameRate: .nan) == "00:00:00:15")
    }

    @Test(arguments: [24.0, 25.0, 30.0, 60.0])
    func everyFrameOfIntegerRateIsExact(rate: Double) {
        let fps = Int(rate)
        for index in 0..<(fps * 3) {
            let parts = Timecode.components(seconds: Double(index) / rate, frameRate: rate)
            #expect(parts.seconds == index / fps)
            #expect(parts.frames == index % fps)
        }
    }

    @Test func ntscFramesStayInRangeAndIncrease() {
        // 29.97 fps: frame n starts at n * 1001 / 30000 s.
        var previous = (seconds: -1, frames: -1)
        for index in 0..<300 {
            let parts = Timecode.components(seconds: Double(index) * 1001 / 30000,
                                            frameRate: 30000.0 / 1001)
            #expect((0...29).contains(parts.frames))
            #expect((parts.seconds, parts.frames) > previous)
            previous = (parts.seconds, parts.frames)
        }
    }

    @Test func justBelowNextSecondDoesNotOverflow() {
        let parts = Timecode.components(seconds: 0.99999999, frameRate: 30)
        #expect(parts.frames < 30)
    }
}

struct SeekCoalescerTests {
    @Test func firstRequestIssuesImmediately() {
        var coalescer = SeekCoalescer<Double>()
        #expect(coalescer.request(1) == 1)
        #expect(coalescer.isSeeking)
    }

    @Test func requestsDuringSeekKeepOnlyLatest() {
        var coalescer = SeekCoalescer<Double>()
        _ = coalescer.request(1)
        #expect(coalescer.request(2) == nil)
        #expect(coalescer.request(3) == nil)
        #expect(coalescer.complete() == 3)
        #expect(coalescer.isSeeking)
        #expect(coalescer.complete() == nil)
        #expect(!coalescer.isSeeking)
    }

    @Test func idleAfterCompletionIssuesAgain() {
        var coalescer = SeekCoalescer<Double>()
        _ = coalescer.request(1)
        _ = coalescer.complete()
        #expect(coalescer.request(4) == 4)
    }

    @Test func resetClearsState() {
        var coalescer = SeekCoalescer<Double>()
        _ = coalescer.request(1)
        _ = coalescer.request(2)
        coalescer.reset()
        #expect(!coalescer.isSeeking)
        #expect(coalescer.pending == nil)
        #expect(coalescer.request(5) == 5)
    }
}
