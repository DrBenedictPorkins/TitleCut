import Foundation
import Testing
@testable import TitleCutCore

/// Copy, paste and duplicate of titles.
struct TitleClipboardTests {
    typealias F = TitleCommandFixture

    /// `Fixture.threeSegments` (v1 [0,1200) | still [1200,1800) | v3 [1800,3000))
    /// with a styled, positioned title 12 on v3 at 300 and style 801 for it.
    static var project: Project {
        var project = F.project
        var title = Fixture.title(12, segment: 3, offset: 300, duration: 450)
        title.styleID = Fixture.id(801)
        title.styleOverrides = StyleOverrides(position: .custom(x: 0.3, y: 0.7),
                                              fontSizeRatio: 0.1)
        title.transitionIn = Transition(kind: .slide(edge: .bottom), duration: 90, easing: .easeOut)
        title.text = "Third"
        project.titles.append(title)
        project.styles.append(F.style(801, name: "Copied"))
        return project
    }

    @Test func copyRecordsRelativeStartsInTimeOrderAndUsedStyles() throws {
        // Title 10 at 100, title 12 at 2100.
        let clipboard = try #require(TitleClipboard(copying: [Fixture.id(12), Fixture.id(10)],
                                                    from: Self.project))
        #expect(clipboard.entries.map(\.title.id) == [Fixture.id(10), Fixture.id(12)])
        #expect(clipboard.entries.map(\.start) == [0, 2000])
        #expect(Set(clipboard.styles.map(\.id)) == [Fixture.id(800), Fixture.id(801)])
        #expect(clipboard.plainText == "T10\n\nThird")
        #expect(try TitleClipboard.decode(clipboard.encoded()) == clipboard)
        #expect(TitleClipboard(copying: [Fixture.id(99)], from: Self.project) == nil)
    }

    @Test func pasteAnchorsAtThePlayheadKeepingSpacingAndEverythingElse() throws {
        let clipboard = try #require(TitleClipboard(copying: [Fixture.id(10), Fixture.id(12)],
                                                    from: Self.project))
        var project = Self.project
        #expect(ProjectCommand.pasteTitles(clipboard, atOutputTime: 600,
                                           newIDs: [Fixture.id(20), Fixture.id(21)])
            .apply(to: &project))
        let first = try #require(project.titles.first { $0.id == Fixture.id(20) })
        let second = try #require(project.titles.first { $0.id == Fixture.id(21) })
        #expect(first.anchor == TitleAnchor(segmentID: Fixture.id(1), offset: 600))
        #expect(second.anchor == TitleAnchor(segmentID: Fixture.id(3), offset: 800))  // 2600
        var expected = Self.project.titles[2]
        expected.id = Fixture.id(21)
        expected.anchor = second.anchor
        #expect(second == expected)
        #expect(project.titles.count == Self.project.titles.count + 2)
    }

    @Test func pasteAnchorsToAGap() throws {
        let clipboard = try #require(TitleClipboard(copying: [Fixture.id(10)], from: Self.project))
        var project = MoveFixture.with([MoveFixture.gap(5, duration: 600),
                                        Fixture.video(1, start: 0, duration: 600)])
        project.styles = Self.project.styles
        #expect(ProjectCommand.pasteTitles(clipboard, atOutputTime: 200, newIDs: [Fixture.id(20)])
            .apply(to: &project))
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(5), offset: 200))
    }

    @Test func pasteIntoAnotherProjectEmbedsMissingStyles() throws {
        let clipboard = try #require(TitleClipboard(copying: [Fixture.id(12)], from: Self.project))
        var other = Fixture.single
        #expect(other.styles.isEmpty)
        #expect(ProjectCommand.pasteTitles(clipboard, atOutputTime: 0, newIDs: [Fixture.id(20)])
            .apply(to: &other))
        #expect(other.styles == [F.style(801, name: "Copied")])

        // A style the project already has is kept as is.
        var edited = Self.project
        edited.styles[1].name = "Project copy"
        #expect(ProjectCommand.pasteTitles(clipboard, atOutputTime: 0, newIDs: [Fixture.id(20)])
            .apply(to: &edited))
        #expect(edited.styles[1].name == "Project copy")
    }

    @Test func titlesPastTheEndAreDroppedAndAllDroppedIsRefused() throws {
        let clipboard = try #require(TitleClipboard(copying: [Fixture.id(10), Fixture.id(12)],
                                                    from: Self.project))
        var project = Self.project
        // 2000 lands; 4000 is past the 3000 end.
        #expect(ProjectCommand.pasteTitles(clipboard, atOutputTime: 2000,
                                           newIDs: [Fixture.id(20), Fixture.id(21)])
            .apply(to: &project))
        #expect(project.titles.map(\.id).contains(Fixture.id(20)))
        #expect(!project.titles.map(\.id).contains(Fixture.id(21)))

        project = Self.project
        #expect(!ProjectCommand.pasteTitles(clipboard, atOutputTime: 3000,
                                            newIDs: [Fixture.id(20), Fixture.id(21)])
            .apply(to: &project))
        #expect(project == Self.project)
    }

    @Test func pasteRefusesBadIDsAndUnknownStyles() throws {
        var clipboard = try #require(TitleClipboard(copying: [Fixture.id(12)], from: Self.project))
        var project = Self.project
        #expect(!ProjectCommand.pasteTitles(clipboard, atOutputTime: 0, newIDs: [])
            .apply(to: &project))
        #expect(!ProjectCommand.pasteTitles(clipboard, atOutputTime: 0, newIDs: [Fixture.id(10)])
            .apply(to: &project))
        clipboard.styles = []
        var other = Fixture.single
        #expect(!ProjectCommand.pasteTitles(clipboard, atOutputTime: 0, newIDs: [Fixture.id(20)])
            .apply(to: &other))
        #expect(other == Fixture.single)
        #expect(project == Self.project)
    }

    @Test func duplicateStartsEachCopyWhereTheOriginalEnds() throws {
        var project = Self.project
        #expect(ProjectCommand.duplicateTitles(newIDs: [Fixture.id(10): Fixture.id(20),
                                                        Fixture.id(12): Fixture.id(21)])
            .apply(to: &project))
        let copy10 = try #require(project.titles.first { $0.id == Fixture.id(20) })
        let copy12 = try #require(project.titles.first { $0.id == Fixture.id(21) })
        #expect(TimelineMath.titleOutputRange(copy10, in: project)?.start == 400)
        #expect(copy10.anchor.segmentID == Fixture.id(1))
        #expect(TimelineMath.titleOutputRange(copy12, in: project)?.start == 2550)
        #expect(copy12.styleOverrides == Self.project.titles[2].styleOverrides)
        #expect(copy12.text == "Third")
    }

    @Test func duplicateRefusals() {
        var project = Self.project
        #expect(!ProjectCommand.duplicateTitles(newIDs: [:]).apply(to: &project))
        #expect(!ProjectCommand.duplicateTitles(newIDs: [Fixture.id(99): Fixture.id(20)])
            .apply(to: &project))
        #expect(!ProjectCommand.duplicateTitles(newIDs: [Fixture.id(10): Fixture.id(11)])
            .apply(to: &project))
        // Title 11 runs [1800,2100); its copy at 2100 lands. A title ending at
        // the timeline end has nowhere to go.
        var title = Fixture.title(13, segment: 3, offset: 900)    // [2700,3000)
        title.styleID = Fixture.id(800)
        project.titles.append(title)
        let before = project
        #expect(!ProjectCommand.duplicateTitles(newIDs: [Fixture.id(13): Fixture.id(20)])
            .apply(to: &project))
        #expect(project == before)
    }

    @Test func actionNames() throws {
        let one = try #require(TitleClipboard(copying: [Fixture.id(10)], from: Self.project))
        let two = try #require(TitleClipboard(copying: [Fixture.id(10), Fixture.id(12)],
                                              from: Self.project))
        #expect(ProjectCommand.pasteTitles(one, atOutputTime: 0, newIDs: [Fixture.id(20)])
            .actionName == "Paste Title")
        #expect(ProjectCommand.pasteTitles(two, atOutputTime: 0, newIDs: [])
            .actionName == "Paste Titles")
        #expect(ProjectCommand.duplicateTitles(newIDs: [Fixture.id(10): Fixture.id(20)])
            .actionName == "Duplicate Title")
        #expect(ProjectCommand.duplicateTitles(newIDs: [Fixture.id(10): Fixture.id(20),
                                                        Fixture.id(12): Fixture.id(21)])
            .actionName == "Duplicate Titles")
    }
}

@MainActor
struct TitleClipboardUndoTests {
    @Test func pasteAndDuplicateUndoExactly() throws {
        let original = TitleClipboardTests.project
        let clipboard = try #require(TitleClipboard(copying: [Fixture.id(10), Fixture.id(12)],
                                                    from: original))
        let commands: [ProjectCommand] = [
            .pasteTitles(clipboard, atOutputTime: 500, newIDs: [Fixture.id(20), Fixture.id(21)]),
            .duplicateTitles(newIDs: [Fixture.id(10): Fixture.id(20), Fixture.id(12): Fixture.id(21)]),
        ]
        for command in commands {
            var other = Fixture.single
            other.styles = []
            for start in [original, other] {
                let store = ProjectStore(project: start)
                let undo = UndoManager()
                undo.groupsByEvent = false
                store.undoManager = undo
                guard store.perform(command) else { continue }
                let edited = store.project
                #expect(undo.undoActionName == command.actionName)
                undo.undo()
                #expect(store.project == start)
                #expect(!undo.canUndo)
                undo.redo()
                #expect(store.project == edited)
            }
        }
    }
}
