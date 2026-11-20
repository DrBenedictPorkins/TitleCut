import AVFoundation
import Speech
import Testing
@testable import TitleCutCore

/// Caption lines, timeline mapping, the replace command and transcript
/// persistence. Speech recognition itself is not run here.
struct AutoCaptionsTests {
    private func w(_ text: String, _ start: Tick, _ end: Tick) -> TranscriptWord {
        TranscriptWord(text: text, start: start, end: end)
    }

    /// Words back to back, `length` ticks each.
    private func run(_ texts: [String], from start: Tick = 0, length: Tick = 60) -> [TranscriptWord] {
        texts.enumerated().map { index, text in
            w(text, start + Tick(index) * length, start + Tick(index + 1) * length)
        }
    }

    private var style: TitleStyle { StyleLibrary.caption }

    private func ids(from base: Int = 100) -> () -> UUID {
        var next = base
        return {
            next += 1
            return Fixture.id(next)
        }
    }

    // MARK: Lines

    @Test func sentenceEndClosesALine() {
        let lines = AutoCaptions.lines([w("Hello", 0, 100), w("world.", 110, 200),
                                        w("Next", 220, 300), w("one?", 300, 360),
                                        w("Yes!", 380, 420)])
        #expect(lines.map(\.text) == ["Hello world.", "Next one?", "Yes!"])
        #expect(lines[0] == AutoCaptions.Line(text: "Hello world.", start: 0, end: 200,
                                              words: [w("Hello", 0, 100), w("world.", 110, 200)]))
    }

    @Test func pauseLongerThanHalfASecondBreaks() {
        let lines = AutoCaptions.lines([w("a", 0, 100), w("b", 400, 450), w("c", 751, 800)])
        // 300 ticks is exactly the limit and stays; 301 breaks.
        #expect(lines.map(\.text) == ["a b", "c"])
    }

    @Test func atMostSevenWords() {
        let lines = AutoCaptions.lines(run((1...9).map { "w\($0)" }))
        #expect(lines.map { $0.text.split(separator: " ").count } == [7, 2])
    }

    @Test func atMostFortyTwoCharacters() {
        let lines = AutoCaptions.lines(run(Array(repeating: "abcdefghij", count: 5)))
        // Three words are 32 characters; a fourth would make 43.
        #expect(lines.map(\.text.count) == [32, 21])
    }

    @Test func atMostThreeSeconds() {
        let lines = AutoCaptions.lines(run(["a", "b", "c", "d", "e"], length: 500))
        // The fourth word would end 2000 ticks after the line began (> 1800).
        #expect(lines.map(\.text) == ["a b c", "d e"])
    }

    @Test func blankWordsAreSkippedAndTextTrimmed() {
        let lines = AutoCaptions.lines([w(" hi ", 0, 60), w("  ", 60, 120), w("there", 120, 180)])
        #expect(lines.map(\.text) == ["hi there"])
        #expect(AutoCaptions.lines([]).isEmpty)
    }

    // MARK: Mapping onto the timeline

    @Test func trimmedOutSpeechIsDroppedAndGapsAreSkipped() throws {
        // src [0,1200) | gap 600 | src [1800,3000): source [1200,1800) is cut.
        let project = Project(source: Fixture.source, segments: [
            Fixture.video(1, start: 0, duration: 1200),
            .gap(GapSegment(id: Fixture.id(5), duration: 600)),
            Fixture.video(3, start: 1800, duration: 1200),
        ])
        let words = [w("One.", 100, 300), w("Gone.", 1300, 1500), w("Three.", 1900, 2100)]
        let titles = AutoCaptions.titles(for: words, in: project, style: style, makeID: ids())
        #expect(titles.map(\.text) == ["One.", "Three."])
        #expect(titles.map(\.anchor) == [TitleAnchor(segmentID: Fixture.id(1), offset: 100),
                                         TitleAnchor(segmentID: Fixture.id(3), offset: 100)])
        #expect(titles.map(\.id) == [Fixture.id(101), Fixture.id(102)])
        let second = try #require(TimelineMath.titleOutputRange(titles[1], in: project))
        #expect(second.start == 1900)
        #expect(titles.allSatisfy { $0.origin == .autoCaption && $0.styleID == style.id })
        #expect(titles[0].transitionIn == AutoCaptions.transitionIn)
        #expect(titles[0].transitionOut == AutoCaptions.transitionOut)
    }

    @Test func shortLinesAreHeldButNotPastTheNextLine() {
        let project = Project(source: Fixture.source,
                              segments: [Fixture.video(1, start: 0, duration: 3000)])
        let words = [w("Hi.", 0, 100), w("There.", 300, 400), w("End.", 2000, 2100)]
        let titles = AutoCaptions.titles(for: words, in: project, style: style, makeID: ids())
        // "Hi." held until "There." starts; "There." held the minimum 480.
        #expect(titles.map(\.duration) == [300, 480, 480])
    }

    @Test func captionsAreClippedToTheirSegmentEnd() {
        let project = Project(source: Fixture.source, segments: [
            Fixture.video(1, start: 0, duration: 1200),
            Fixture.video(3, start: 1800, duration: 1200),
        ])
        let words = [w("Across", 1100, 1300), w("Later", 1250, 1400)]
        let titles = AutoCaptions.titles(for: words, in: project, style: style, makeID: ids())
        // "Across" starts in segment 1 and stops at its end; "Later" starts in
        // the cut part and is dropped.
        #expect(titles.map(\.text) == ["Across"])
        #expect(titles.map(\.duration) == [100])
    }

    @Test func movedClipsKeepTheirSpeechInOutputOrder() throws {
        // The second half of the source now plays first.
        let project = Project(source: Fixture.source, segments: [
            Fixture.video(3, start: 1500, duration: 1500),
            Fixture.video(1, start: 0, duration: 1500),
        ])
        let words = [w("First.", 100, 300), w("Second.", 1600, 1800)]
        let titles = AutoCaptions.titles(for: words, in: project, style: style, makeID: ids())
        #expect(titles.map(\.text) == ["Second.", "First."])
        let starts = try titles.map { try #require(TimelineMath.titleOutputRange($0, in: project)).start }
        #expect(starts == [100, 1600])
    }

    @Test func linesDoNotCrossACut() {
        // Contiguous source split in two: a line breaks at the split.
        let project = Project(source: Fixture.source, segments: [
            Fixture.video(1, start: 0, duration: 600),
            Fixture.video(2, start: 600, duration: 2400),
        ])
        let words = run(["a", "b", "c", "d"], from: 480, length: 60)
        let titles = AutoCaptions.titles(for: words, in: project, style: style, makeID: ids())
        #expect(titles.map(\.text) == ["a b", "c d"])
        #expect(titles.map(\.anchor.segmentID) == [Fixture.id(1), Fixture.id(2)])
    }

    // MARK: Words from a Speech result

    @Test func wordsFromAttributedRuns() {
        func piece(_ text: String, _ start: Double, _ end: Double) -> AttributedString {
            var string = AttributedString(text)
            string[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600))
            return string
        }
        var text = piece("Hello", 0, 0.5)
        text += piece(" big world", 0.5, 1.5)
        text += piece(".", 1.5, 1.6)
        text += AttributedString(" ")
        let words = Transcriber.words(in: text, offset: 60)
        #expect(words.map(\.text) == ["Hello", "big", "world."])
        // "big world" shares its run's time by length: 3/8 and 5/8 of 600.
        #expect(words.map(\.start) == [60, 360, 585])
        #expect(words.map(\.end) == [360, 585, 1020])
    }

    // MARK: Replace command

    @MainActor
    @Test func rerunReplacesOnlyMarkedTitlesInOneUndoStep() throws {
        var project = TitleCommandFixture.project
        let first = AutoCaptions.titles(for: [w("Old.", 100, 300)], in: project, style: style,
                                        makeID: ids(from: 100))
        #expect(ProjectCommand.replaceAutoCaptions(titles: first, style: style)
            .apply(to: &project))
        #expect(project.titles.count == 3)
        // An edited caption keeps its marker.
        ProjectCommand.setTitleText(id: Fixture.id(101), text: "Edited").apply(to: &project)

        let store = ProjectStore(project: project)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let second = AutoCaptions.titles(for: [w("New.", 100, 300), w("More.", 1300, 1500)],
                                         in: project, style: style, makeID: ids(from: 200))
        let command = ProjectCommand.replaceAutoCaptions(titles: second, style: style)
        #expect(command.actionName == "Auto-Captions")
        #expect(store.perform(command))
        #expect(store.project.titles.map(\.id)
                == [Fixture.id(10), Fixture.id(11), Fixture.id(201), Fixture.id(202)])
        #expect(store.project.titles.prefix(2) == project.titles.prefix(2))
        #expect(undo.undoActionName == "Auto-Captions")

        undo.undo()
        #expect(store.project == project)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(store.project.titles.map(\.text) == ["T10", "T11", "New.", "More."])
    }

    @Test func emptyRerunRemovesCaptionsAndTheirStyle() {
        var project = TitleCommandFixture.project
        let captions = AutoCaptions.titles(for: [w("Old.", 100, 300)], in: project, style: style,
                                           makeID: ids())
        ProjectCommand.replaceAutoCaptions(titles: captions, style: style).apply(to: &project)
        #expect(project.styles.map(\.id) == [Fixture.id(800), StyleLibrary.captionID])
        #expect(ProjectCommand.replaceAutoCaptions(titles: [], style: style).apply(to: &project))
        #expect(project.titles.map(\.id) == [Fixture.id(10), Fixture.id(11)])
        #expect(project.styles.map(\.id) == [Fixture.id(800)])
    }

    @Test func refusals() {
        let project = TitleCommandFixture.project
        let good = AutoCaptions.titles(for: [w("A.", 100, 300)], in: project, style: style,
                                       makeID: ids())
        func refused(_ titles: [Title]) -> Bool {
            var copy = project
            return !ProjectCommand.replaceAutoCaptions(titles: titles, style: style)
                .apply(to: &copy) && copy == project
        }
        var unmarked = good
        unmarked[0].origin = nil
        #expect(refused(unmarked))
        var otherStyle = good
        otherStyle[0].styleID = Fixture.id(800)
        #expect(refused(otherStyle))
        var missingSegment = good
        missingSegment[0].anchor.segmentID = Fixture.id(99)
        #expect(refused(missingSegment))
        var takenID = good
        takenID[0].id = Fixture.id(10)
        #expect(refused(takenID))
        #expect(refused(good + good))
    }

    // MARK: Persistence

    private var transcript: Transcript {
        Transcript(locale: "en-US", source: SourceFingerprint(byteCount: 1234, duration: 3000),
                   words: [w("Hello", 0, 120), w("world.", 130, 300)])
    }

    @Test func transcriptRoundTripsAndMatchesItsSource() throws {
        let data = try ProjectFile.encodeTranscript(transcript)
        #expect(ProjectFile.decodeTranscript(data) == transcript)
        #expect(transcript.matches(SourceFingerprint(byteCount: 1234, duration: 3000),
                                   locale: "en-US"))
        #expect(!transcript.matches(SourceFingerprint(byteCount: 1235, duration: 3000),
                                    locale: "en-US"))
        #expect(!transcript.matches(transcript.source, locale: "fr-FR"))
    }

    @Test func newerOrDamagedTranscriptIsTreatedAsAbsent() throws {
        var newer = transcript
        newer.formatVersion = Transcript.currentFormatVersion + 1
        #expect(ProjectFile.decodeTranscript(try JSONEncoder().encode(newer)) == nil)
        #expect(ProjectFile.decodeTranscript(Data("{".utf8)) == nil)
    }

    @Test func packageSavesAndLoadsTheTranscripts() throws {
        var project = TitleCommandFixture.project
        project.titles[0].origin = .autoCaption
        var other = transcript
        other.source = SourceFingerprint(byteCount: 99, duration: 600)
        let package = try ProjectFile.package(project, transcripts: [transcript, other],
                                              existing: nil)
        #expect(Set(package.fileWrappers.map { Array($0.keys) } ?? [])
                == ["project.json", "stills", "transcripts.json"])
        let (loaded, loadedTranscripts) = try ProjectFile.read(package: package)
        #expect(loaded == project)
        #expect(loadedTranscripts == [transcript, other])

        let without = try ProjectFile.package(project, transcripts: [], existing: package)
        #expect(without.fileWrappers?["transcripts.json"] == nil)
        #expect(try ProjectFile.read(package: without).1.isEmpty)
    }

    @Test func olderPackagesLoadTheirOneTranscript() throws {
        let package = try ProjectFile.package(TitleCommandFixture.project, transcripts: [],
                                              existing: nil)
        let file = FileWrapper(regularFileWithContents: try ProjectFile.encodeTranscript(transcript))
        file.preferredFilename = "transcript.json"
        package.addFileWrapper(file)
        #expect(try ProjectFile.read(package: package).1 == [transcript])
    }

    @Test func aNewTranscriptReplacesTheOneOfTheSameVideo() {
        var french = transcript
        french.locale = "fr-FR"
        var other = transcript
        other.source = SourceFingerprint(byteCount: 99, duration: 600)
        #expect([transcript, other].replacing(with: french) == [other, french])
    }

    @Test func titlesWithoutOriginOmitItAndOldFilesLoad() throws {
        let project = TitleCommandFixture.project
        let json = String(decoding: try ProjectFile.encode(project), as: UTF8.self)
        #expect(!json.contains("origin"))
        #expect(try ProjectFile.decode(Data(json.utf8)) == project)

        var marked = project
        marked.titles[0].origin = .autoCaption
        let markedJSON = String(decoding: try ProjectFile.encode(marked), as: UTF8.self)
        #expect(markedJSON.contains("\"origin\" : \"autoCaption\""))
        #expect(try ProjectFile.decode(Data(markedJSON.utf8)).titles[0].origin == .autoCaption)
    }
}
