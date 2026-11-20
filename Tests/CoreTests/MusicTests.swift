import AVFoundation
import Foundation
import Testing
@testable import TitleCutCore

enum MusicFixture {
    /// A piece of a 10 s song.
    static func clip(_ n: Int, start: Tick, duration: Tick, songStart: Tick = 0,
                     fileName: String = "song.m4a") -> MusicClip {
        MusicClip(id: Fixture.id(n), fileName: fileName, name: "Song \(n)",
                  songDuration: 6000, start: start,
                  songRange: TickRange(start: songStart, duration: duration),
                  fadeIn: 0, fadeOut: 0)
    }

    /// A mono 44.1 kHz sine wave of `seconds`, as a WAV in a fresh temp folder.
    static func song(seconds: Double) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "MusicTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = 0.5 * sin(Float(i) * 2 * .pi * 440 / 44100)
        }
        try file.write(from: buffer)
        return url
    }
}

struct MusicPlacementTests {
    typealias M = MusicFixture

    @Test func movingStopsAtTheNeighbours() {
        let left = M.clip(1, start: 0, duration: 600)
        let piece = M.clip(2, start: 1200, duration: 600)
        let right = M.clip(3, start: 2400, duration: 600)
        let others = [left, piece, right]
        #expect(MusicPlacement.moved(piece, to: 100, among: others).start == 600)
        #expect(MusicPlacement.moved(piece, to: 2300, among: others).start == 1800)
        #expect(MusicPlacement.moved(piece, to: 1500, among: others).start == 1500)
    }

    @Test func trimmingTheStartKeepsTheEndAndTheSongInPlace() {
        let piece = M.clip(1, start: 1200, duration: 1200, songStart: 600)
        let trimmed = MusicPlacement.trimmedStart(piece, to: 1500, among: [piece])
        #expect(trimmed.start == 1500 && trimmed.end == 2400)
        #expect(trimmed.songRange.start == 900)
        // Cannot reach back before the song's first moment.
        let extended = MusicPlacement.trimmedStart(piece, to: 0, among: [piece])
        #expect(extended.start == 600 && extended.songRange.start == 0)
    }

    @Test func trimmingTheEndStopsAtTheSongEndAndTheNextPiece() {
        let piece = M.clip(1, start: 0, duration: 1200, songStart: 4800)
        #expect(MusicPlacement.trimmedEnd(piece, to: 99_000, among: [piece]).end == 1200)
        let free = M.clip(2, start: 0, duration: 1200)
        let next = M.clip(3, start: 3000, duration: 600)
        #expect(MusicPlacement.trimmedEnd(free, to: 99_000, among: [free, next]).end == 3000)
        #expect(MusicPlacement.trimmedEnd(free, to: 0, among: [free]).duration
                == MusicPlacement.minimumDuration)
    }

    @Test func newPieceStartsAfterThePlayheadPieceAndFillsTheRoom() {
        let existing = M.clip(1, start: 0, duration: 1200)
        let piece = MusicPlacement.newPiece(
            id: Fixture.id(9), fileName: "b.m4a", name: "B", songDuration: 60_000,
            at: 600, among: [existing], videoDuration: 3000)
        #expect(piece?.start == 1200 && piece?.end == 3000)
        #expect(MusicPlacement.newPiece(
            id: Fixture.id(9), fileName: "b.m4a", name: "B", songDuration: 60_000,
            at: 2900, among: [], videoDuration: 3000) == nil)
    }
}

@MainActor
struct MusicCommandTests {
    typealias M = MusicFixture

    @Test func overlappingPiecesAreRefused() {
        var project = Fixture.single
        #expect(ProjectCommand.addMusic(M.clip(1, start: 0, duration: 1200)).apply(to: &project))
        #expect(!ProjectCommand.addMusic(M.clip(2, start: 600, duration: 1200)).apply(to: &project))
        #expect(ProjectCommand.addMusic(M.clip(2, start: 1200, duration: 600)).apply(to: &project))
        var moved = M.clip(2, start: 1000, duration: 600)
        #expect(!ProjectCommand.setMusic(moved).apply(to: &project))
        moved.start = 1800
        #expect(ProjectCommand.setMusic(moved).apply(to: &project))
        #expect(project.music.map(\.start) == [0, 1800])
    }

    @Test func addChangeAndDeleteUndo() {
        let original = Fixture.single
        let store = ProjectStore(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        var clip = M.clip(1, start: 0, duration: 1200)
        #expect(store.perform(.addMusic(clip)))
        let added = store.project
        clip.volume = 0.3
        #expect(store.perform(.setMusic(clip)))
        store.selectedMusicID = clip.id
        #expect(store.deleteSelectedMusic())
        #expect(store.project.music.isEmpty)
        #expect(store.selectedMusicID == nil)
        undo.undo()
        #expect(store.project.music.first?.volume == 0.3)
        undo.undo()
        #expect(store.project == added)
        undo.undo()
        #expect(store.project == original)
    }

    @Test func selectingMusicClearsOtherSelections() {
        let store = ProjectStore(project: Fixture.single)
        store.selectedTitleIDs = [Fixture.id(10)]
        store.selectedMusicID = Fixture.id(1)
        #expect(store.selectedTitleIDs.isEmpty)
        store.selectedSegmentID = Fixture.id(1)
        #expect(store.selectedMusicID == nil)
    }
}

struct MusicFileTests {
    @Test func projectsWithoutMusicStillLoad() throws {
        var json = try JSONSerialization.jsonObject(
            with: ProjectFile.encode(Fixture.single)) as! [String: Any]
        json.removeValue(forKey: "music")
        let data = try JSONSerialization.data(withJSONObject: json)
        #expect(try ProjectFile.decode(data).music.isEmpty)
    }

    @Test func songsAreSavedInThePackageAndReadBack() async throws {
        let song = try MusicFixture.song(seconds: 2)
        let id = UUID()
        let imported = try await MusicFiles.importSong(from: song, id: id)
        #expect(abs(imported.duration - 1200) <= 1)
        var project = Fixture.single
        project.music = [MusicFixture.clip(1, start: 0, duration: 600,
                                           fileName: imported.fileName)]
        let package = try ProjectFile.package(project, transcripts: [], existing: nil)
        let saved = package.fileWrappers?[MusicFiles.folderName]?.fileWrappers
        #expect(saved?.keys.sorted() == [imported.fileName])

        // Opening on a Mac without the cached copy restores it.
        try FileManager.default.removeItem(at: MusicFiles.url(for: imported.fileName))
        let (read, _) = try ProjectFile.read(package: package)
        #expect(read.music == project.music)
        #expect(FileManager.default.fileExists(atPath: MusicFiles.url(for: imported.fileName).path))
        try? FileManager.default.removeItem(at: MusicFiles.url(for: imported.fileName))
    }

    @Test func unusedSongsAreLeftOutOfThePackage() throws {
        let package = try ProjectFile.package(Fixture.single, transcripts: [], existing: nil)
        #expect(package.fileWrappers?[MusicFiles.folderName] == nil)
    }
}

@Suite(.serialized)
struct MusicCompositionTests {
    @Test func musicIsCutOffAtTheVideoEndWithVolumeRamps() async throws {
        let url = try await RenderFixture.numbered.value
        var project = Project.empty
        ProjectCommand.setSource(try await SourceVideo.load(from: url), segmentID: Fixture.id(1))
            .apply(to: &project)
        let total = TimelineMath.outputDuration(project)
        let song = try MusicFixture.song(seconds: 30)
        let imported = try await MusicFiles.importSong(from: song, id: UUID())
        defer { try? FileManager.default.removeItem(at: MusicFiles.url(for: imported.fileName)) }
        var clip = MusicFixture.clip(1, start: 300, duration: 12_000, fileName: imported.fileName)
        clip.songDuration = imported.duration
        clip.fadeIn = 300
        clip.fadeOut = 300
        project.music = [clip]

        let tracks = try #require(try await CompositionBuilder.SourceTracks.load(
            from: AVURLAsset(url: url)))
        let music = await CompositionBuilder.MusicTracks.load(for: project)
        let built = try CompositionBuilder.build(project, tracks: tracks, music: music)
        let audio = try await built.composition.loadTracks(withMediaType: .audio)
        let musicTrack = try #require(audio.last)
        let range = try await musicTrack.load(.timeRange)
        #expect(Ticks.from(range.end) == total)
        let mix = try #require(built.audioMix)
        #expect(mix.inputParameters.count == 1)
        var timeRange = CMTimeRange.zero
        let found = mix.inputParameters[0].getVolumeRamp(
            for: Ticks.cmTime(310), startVolume: nil, endVolume: nil, timeRange: &timeRange)
        #expect(found)
        #expect(Ticks.from(timeRange.start) == 300)
    }
}

struct MusicInsertTests {
    typealias M = MusicFixture

    @Test func duplicateGoesAfterTheOriginalAndPushesLaterPiecesRight() {
        var project = Fixture.single
        project.music = [M.clip(1, start: 0, duration: 600),
                         M.clip(2, start: 900, duration: 600),
                         M.clip(3, start: 1800, duration: 300)]
        var copy = M.clip(4, start: 600, duration: 600)
        copy.start = 600
        #expect(ProjectCommand.insertMusic(copy).apply(to: &project))
        // The copy fills 600...1200; piece 2 had 300 of room, so the later pieces move 300.
        #expect(project.music.map(\.start) == [0, 600, 1200, 2100])
        #expect(project.music.map(\.id) == [1, 4, 2, 3].map(Fixture.id))
    }

    @Test func pasteInsideAPieceLandsAfterIt() {
        var project = Fixture.single
        project.music = [M.clip(1, start: 0, duration: 1200)]
        #expect(ProjectCommand.insertMusic(M.clip(2, start: 500, duration: 600))
            .apply(to: &project))
        #expect(project.music.map(\.start) == [0, 1200])
    }

    @Test func pasteIntoEnoughRoomMovesNothing() {
        var project = Fixture.single
        project.music = [M.clip(1, start: 2400, duration: 600)]
        #expect(ProjectCommand.insertMusic(M.clip(2, start: 0, duration: 600))
            .apply(to: &project))
        #expect(project.music.map(\.start) == [0, 2400])
        #expect(!ProjectCommand.insertMusic(M.clip(2, start: 0, duration: 600))
            .apply(to: &project))
    }
}
