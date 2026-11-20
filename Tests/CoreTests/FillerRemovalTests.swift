import Foundation
import Testing
@testable import TitleCutCore

struct FillerRemovalTests {
    private func word(_ text: String, _ start: Tick, _ end: Tick) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end)
    }

    /// "So, uh, we start. Um... like this." in source ticks.
    private var words: [TranscriptWord] {
        [word("So,", 0, 300), word("uh,", 300, 600), word("we", 600, 750),
         word("start.", 750, 1200), word("Um...", 1200, 1500), word("like", 1500, 1800),
         word("this.", 1800, 2100)]
    }

    @Test func onlyFillerSoundsAreFound() {
        #expect(FillerRemoval.isFiller("Uh,"))
        #expect(FillerRemoval.isFiller("HMM?"))
        #expect(!FillerRemoval.isFiller("like"))
        #expect(!FillerRemoval.isFiller("umbrella"))
        #expect(FillerRemoval.fillers(in: words)
                == [TickRange(start: 300, duration: 300), TickRange(start: 1200, duration: 300)])
    }

    @Test func cutsFollowTheClipsIntoOutputTime() {
        // v1 src [0,1000) at 0 | v2 src [1000,3000) at 1000.
        let project = MoveFixture.with([Fixture.video(1, start: 0, duration: 1000),
                                        Fixture.video(2, start: 1000, duration: 2000)])
        #expect(FillerRemoval.cuts(for: words, in: project)
                == [TickRange(start: 300, duration: 300), TickRange(start: 1200, duration: 300)])
    }

    @MainActor @Test func removingRebuildsAutoCaptionsInOneUndoStep() throws {
        var original = Fixture.single
        original.titles = []
        let style = TitleCommandFixture.style(800, name: "Caption")
        let captions = AutoCaptions.titles(for: words, in: original, style: style,
                                           makeID: UUID.init)
        #expect(ProjectCommand.replaceAutoCaptions(titles: captions, style: style)
            .apply(to: &original))
        let store = ProjectStore(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        let cuts = FillerRemoval.cuts(for: words, in: original)
        let commands = FillerRemoval.commands(removing: cuts, from: original, words: words)
        store.beginGesture(named: "Remove Filler Words")
        for command in commands { store.perform(command) }
        store.endGesture()

        let project = store.project
        #expect(TimelineMath.outputDuration(project) == 3000 - 600)
        let text = project.titles.map(\.text).joined(separator: " ")
        #expect(text == "So, we start. like this.")
        #expect(project.titles.allSatisfy { $0.origin == .autoCaption && $0.styleID == style.id })

        undo.undo()
        #expect(store.project == original)
        #expect(!undo.canUndo)
    }

    @Test func handMadeTitlesAreKeptWithoutCaptions() {
        let project = Fixture.single
        let commands = FillerRemoval.commands(
            removing: FillerRemoval.cuts(for: words, in: project), from: project, words: words)
        #expect(!commands.contains {
            if case .replaceAutoCaptions = $0 { true } else { false }
        })
        var edited = project
        for command in commands { command.apply(to: &edited) }
        #expect(edited.titles.count == 3)
    }

    @Test func nothingToCutGivesNoCommands() {
        let plain = [word("Hello", 0, 300), word("there.", 300, 600)]
        #expect(FillerRemoval.cuts(for: plain, in: Fixture.single).isEmpty)
        #expect(FillerRemoval.commands(removing: [], from: Fixture.single, words: plain).isEmpty)
    }
}
