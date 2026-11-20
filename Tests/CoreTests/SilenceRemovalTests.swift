import Foundation
import Testing
@testable import TitleCutCore

struct SilenceRemovalTests {
    /// 100 bins a second: `loud`/`quiet` seconds alternating, starting loud.
    private func waveform(_ runs: [(level: Float, seconds: Double)]) -> Waveform {
        Waveform(peaks: runs.flatMap { run in
            Array(repeating: run.level, count: Int(run.seconds * Waveform.binsPerSecond))
        })
    }

    @Test func pauseIsFoundWithPaddingKeptAtEachEnd() {
        let audio = waveform([(1, 1), (0, 1), (1, 1)])
        // 1 s to 2 s silent; 0.15 s (90 ticks) kept at each end.
        #expect(SilenceRemoval.silences(in: audio, settings: .init())
                == [TickRange(start: 690, duration: 420)])
    }

    @Test func shortPausesAndQuietSpeechAreKept() {
        let audio = waveform([(1, 1), (0, 0.4), (1, 1), (0.5, 2)])
        // 0.5 is about -22 dB: above the -30 dB threshold.
        #expect(SilenceRemoval.silences(in: audio, settings: .init()).isEmpty)
    }

    @Test func closeCutsKeepOnlyTheLongest() {
        // Talk 2 s, 0.75 s pause, 0.5 s word, 2.25 s pause, talk 2 s.
        let audio = waveform([(1, 2), (0, 0.75), (1, 0.5), (0, 2.25), (1, 2)])
        let found = SilenceRemoval.silences(in: audio, settings: .init())
        // Only the 2.25 s pause (3.25 s to 5.5 s, padded) is cut.
        #expect(found == [TickRange(start: 2040, duration: 1170)])
        let all = SilenceRemoval.silences(in: audio, settings: .init(minimumKeptSeconds: 0))
        #expect(all.count == 2)
    }

    @Test func previewTimeMapsBothWays() {
        let cuts = [TickRange(start: 600, duration: 300), TickRange(start: 1500, duration: 600)]
        #expect(SilenceRemoval.keptTime(300, cuts: cuts) == 300)
        #expect(SilenceRemoval.keptTime(750, cuts: cuts) == 600)
        #expect(SilenceRemoval.keptTime(2400, cuts: cuts) == 1500)
        #expect(SilenceRemoval.originalTime(600, cuts: cuts) == 900)
        #expect(SilenceRemoval.originalTime(1200, cuts: cuts) == 2100)
        #expect(SilenceRemoval.originalTime(1199, cuts: cuts) == 1499)
    }

    @Test func aRangeKeepsOnlyCutsInsideIt() {
        let cuts = [TickRange(start: 0, duration: 300), TickRange(start: 600, duration: 600),
                    TickRange(start: 2000, duration: 300)]
        #expect(SilenceRemoval.cuts(cuts, within: TickRange(start: 900, duration: 900))
                == [TickRange(start: 900, duration: 300)])
        #expect(SilenceRemoval.cuts(cuts, within: nil) == cuts)
    }

    @Test func aQuietSelectionMeasuresFromItsOwnLoudest() {
        // Quiet speech at 0.5 with a 0.3 dip: 9 dB below the speech,
        // 31.5 dB below the file's loudest.
        let audio = waveform([(0.5, 1), (0.3, 1), (0.5, 1)])
        #expect(SilenceRemoval.silences(in: audio, settings: .init()).count == 1)
        #expect(SilenceRemoval.silences(in: audio, settings: .init(), loudest: 0.5).isEmpty)
        #expect(SilenceRemoval.silences(in: audio, settings: .init(thresholdDecibels: 6),
                                        loudest: 0.5).count == 1)
    }

    @Test func spacedCutsAreAllKept() {
        let ranges = [TickRange(start: 0, duration: 300), TickRange(start: 1300, duration: 300)]
        #expect(SilenceRemoval.spaced(ranges, minimumKept: 900) == ranges)
        #expect(SilenceRemoval.spaced(ranges, minimumKept: 1100) == [ranges[0]])
    }

    @Test func silenceAtTheStartIsCutToTheFirstFrame() {
        let audio = waveform([(0, 1), (1, 1)])
        #expect(SilenceRemoval.silences(in: audio, settings: .init())
                == [TickRange(start: 0, duration: 510)])
    }

    @Test func cutsFollowEachClipIntoOutputTime() {
        // v1 src [0,600) at 0 | v2 src [1200,1800) at 600.
        let project = MoveFixture.with([Fixture.video(1, start: 0, duration: 600),
                                        Fixture.video(2, start: 1200, duration: 600)])
        let silences = [TickRange(start: 300, duration: 1200)]  // src 300..1500
        #expect(SilenceRemoval.cuts(for: silences, in: project)
                == [TickRange(start: 300, duration: 300), TickRange(start: 600, duration: 300)])
    }

    @MainActor @Test func removingClosesUpKeepsTitlesAndUndoesInOneStep() {
        let original = Fixture.single
        let store = ProjectStore(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        let commands = SilenceRemoval.commands(
            removing: [TickRange(start: 900, duration: 600)], from: original)
        store.beginGesture(named: "Remove Silences")
        for command in commands { store.perform(command) }
        store.endGesture()

        let project = store.project
        #expect(TimelineMath.outputDuration(project) == 2400)
        #expect(project.segments.map(\.duration) == [900, 1500])
        if case .video(let second) = project.segments[1] {
            #expect(second.sourceRange == TickRange(start: 1500, duration: 1500))
        }
        let starts = project.titles.map { TimelineMath.titleOutputRange($0, in: project)?.start }
        // 0.5 s unchanged; 2 s was inside the cut, now at the join; 4 s moved 1 s earlier.
        #expect(starts == [300, 900, 1800])

        undo.undo()
        #expect(store.project == original)
        #expect(!undo.canUndo)
    }

    @Test func theLastClipIsNeverCutAway() {
        let project = Fixture.single
        let commands = SilenceRemoval.commands(
            removing: [TickRange(start: 0, duration: 3000)], from: project)
        var edited = project
        for command in commands { command.apply(to: &edited) }
        #expect(TimelineMath.outputDuration(edited) == 3000)
    }
}
