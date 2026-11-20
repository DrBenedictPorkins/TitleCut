import Foundation
import Testing
@testable import TitleCutCore

/// Per-title look edits: `setTitleLook` and the fork rule in `titleLook`.
@MainActor
struct TitleLookTests {
    typealias F = TitleCommandFixture

    /// Library IDs as the panel passes them: style 800 is a library style.
    private let library: Set<UUID> = [Fixture.id(800)]

    private func edited(_ style: TitleStyle) -> TitleStyle {
        var style = style
        style.textColor = RGBA(red: 1, green: 0, blue: 0)
        return style
    }

    private func style(of titleID: UUID, in project: Project) throws -> TitleStyle {
        let title = try #require(project.titles.first { $0.id == titleID })
        return try #require(project.styles.first { $0.id == title.styleID })
    }

    @Test func libraryStyleForksToACustomCopy() throws {
        var project = F.project
        let original = try style(of: Fixture.id(10), in: project)
        let command = try #require(ProjectCommand.titleLook(
            edited(original), forTitle: Fixture.id(10), in: project, libraryStyleIDs: library,
            forkID: Fixture.id(900)))
        #expect(command.actionName == "Change Title Look")
        #expect(command.apply(to: &project))

        let forked = try style(of: Fixture.id(10), in: project)
        #expect(forked.id == Fixture.id(900))
        #expect(forked.name == "Embedded (custom)")
        #expect(forked.textColor == RGBA(red: 1, green: 0, blue: 0))
        // The other title and the original style are untouched.
        #expect(try style(of: Fixture.id(11), in: project) == original)
    }

    @Test func styleSharedWithAnotherTitleForks() throws {
        var project = F.project
        // 800 is not in the library here, but titles 10 and 11 both use it.
        let original = try style(of: Fixture.id(10), in: project)
        #expect(!ProjectCommand.titleHasPrivateStyle(Fixture.id(10), in: project,
                                                     libraryStyleIDs: []))
        let command = try #require(ProjectCommand.titleLook(
            edited(original), forTitle: Fixture.id(10), in: project, libraryStyleIDs: [],
            forkID: Fixture.id(900)))
        #expect(command.apply(to: &project))
        #expect(project.titles.map(\.styleID) == [Fixture.id(900), Fixture.id(800)])
    }

    @Test func privateStyleIsEditedInPlace() throws {
        var project = F.project
        let original = try style(of: Fixture.id(10), in: project)
        try #require(ProjectCommand.titleLook(
            edited(original), forTitle: Fixture.id(10), in: project, libraryStyleIDs: library,
            forkID: Fixture.id(900))).apply(to: &project)
        #expect(ProjectCommand.titleHasPrivateStyle(Fixture.id(10), in: project,
                                                    libraryStyleIDs: library))

        var second = try style(of: Fixture.id(10), in: project)
        second.weight = .black
        let command = try #require(ProjectCommand.titleLook(
            second, forTitle: Fixture.id(10), in: project, libraryStyleIDs: library,
            forkID: Fixture.id(901)))
        #expect(command == .setTitleLook(id: Fixture.id(10), style: second))
        let stylesBefore = project.styles.count
        #expect(command.apply(to: &project))
        #expect(project.styles.count == stylesBefore)
        #expect(try style(of: Fixture.id(10), in: project) == second)
        // A fork of a fork keeps one suffix.
        #expect(second.name == "Embedded (custom)")
    }

    @Test func refusedWhenAnotherTitleUsesTheStyle() {
        var project = F.project
        let before = project
        var shared = F.style(800)
        shared.weight = .black
        #expect(!ProjectCommand.setTitleLook(id: Fixture.id(10), style: shared)
            .apply(to: &project))
        #expect(project == before)
        #expect(!ProjectCommand.setTitleLook(id: Fixture.id(99), style: F.style(801))
            .apply(to: &project))
        #expect(ProjectCommand.titleLook(F.style(801), forTitle: Fixture.id(99), in: project,
                                         libraryStyleIDs: library) == nil)
    }

    @Test func undoRestoresTheExactProject() throws {
        let original = F.project
        let store = ProjectStore(project: original)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo

        // A slider drag: the first change forks, later ones edit the fork.
        store.beginGesture(named: "Change Title Look")
        for size in [0.07, 0.08, 0.09] {
            var look = try style(of: Fixture.id(10), in: store.project)
            look.fontSizeRatio = size
            let command = try #require(ProjectCommand.titleLook(
                look, forTitle: Fixture.id(10), in: store.project, libraryStyleIDs: library))
            #expect(store.perform(command))
        }
        store.endGesture()
        #expect(undo.undoActionName == "Change Title Look")
        #expect(store.project.styles.count == original.styles.count + 1)
        #expect(try style(of: Fixture.id(10), in: store.project).fontSizeRatio == 0.09)
        let edited = store.project

        undo.undo()
        #expect(store.project == original)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(store.project == edited)
    }

    @Test func duplicatedTitleForksOnFirstEdit() throws {
        var project = F.project
        try #require(ProjectCommand.titleLook(
            edited(try style(of: Fixture.id(10), in: project)), forTitle: Fixture.id(10),
            in: project, libraryStyleIDs: library, forkID: Fixture.id(900))).apply(to: &project)
        #expect(ProjectCommand.duplicateTitles(newIDs: [Fixture.id(10): Fixture.id(20)])
            .apply(to: &project))
        // The copy shares the private style, so neither title owns it now.
        #expect(!ProjectCommand.titleHasPrivateStyle(Fixture.id(20), in: project,
                                                     libraryStyleIDs: library))

        var look = try style(of: Fixture.id(20), in: project)
        look.weight = .light
        try #require(ProjectCommand.titleLook(
            look, forTitle: Fixture.id(20), in: project, libraryStyleIDs: library,
            forkID: Fixture.id(901))).apply(to: &project)
        #expect(try style(of: Fixture.id(20), in: project).id == Fixture.id(901))
        #expect(try style(of: Fixture.id(10), in: project).weight == .bold)
        #expect(ProjectCommand.titleHasPrivateStyle(Fixture.id(10), in: project,
                                                    libraryStyleIDs: library))
    }

    // MARK: Pruning unused styles

    private func makeStore(_ project: Project) -> (ProjectStore, UndoManager) {
        let store = ProjectStore(project: project)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo)
    }

    @Test func styleLeftUnusedByAStyleChangeIsPruned() throws {
        var project = F.project
        try #require(ProjectCommand.titleLook(
            edited(try style(of: Fixture.id(10), in: project)), forTitle: Fixture.id(10),
            in: project, libraryStyleIDs: library, forkID: Fixture.id(900))).apply(to: &project)
        #expect(project.styles.map(\.id) == [Fixture.id(800), Fixture.id(900)])
        // Back to the library style: the private fork goes.
        #expect(ProjectCommand.setTitleStyle(ids: [Fixture.id(10)], style: F.style(800))
            .apply(to: &project))
        #expect(project.styles.map(\.id) == [Fixture.id(800)])
    }

    @Test func forkingTheLastUserOfAStylePrunesIt() throws {
        var project = F.project
        ProjectCommand.setTitleStyle(ids: [Fixture.id(11)], style: F.style(801))
            .apply(to: &project)
        try #require(ProjectCommand.titleLook(
            edited(try style(of: Fixture.id(10), in: project)), forTitle: Fixture.id(10),
            in: project, libraryStyleIDs: library, forkID: Fixture.id(900))).apply(to: &project)
        #expect(project.styles.map(\.id) == [Fixture.id(801), Fixture.id(900)])
    }

    @Test func deletingTitlesPrunesTheirStylesAndUndoRestoresThem() {
        let (store, undo) = makeStore(F.project)
        #expect(store.perform(.deleteTitles(ids: [Fixture.id(10)])))
        #expect(store.project.styles == F.project.styles)
        #expect(store.perform(.deleteTitles(ids: [Fixture.id(11)])))
        #expect(store.project.styles.isEmpty)
        undo.undo()
        undo.undo()
        #expect(store.project == F.project)
    }

    @Test func deletingASegmentPrunesItsTitlesStyles() {
        var project = F.project
        // Title 11 is the only user of 801, on segment 3.
        ProjectCommand.setTitleStyle(ids: [Fixture.id(11)], style: F.style(801))
            .apply(to: &project)
        let before = project
        let (store, undo) = makeStore(project)
        #expect(store.perform(.deleteSegment(id: Fixture.id(3))))
        #expect(store.project.styles.map(\.id) == [Fixture.id(800)])
        undo.undo()
        #expect(store.project == before)
    }

    // MARK: Save as new style

    @Test func newStyleFoldsInSizeAndKeepsPosition() throws {
        var project = F.project
        ProjectCommand.setTitleStyleOverrides(
            id: Fixture.id(10), overrides: StyleOverrides(position: .top, fontSizeRatio: 0.12))
            .apply(to: &project)
        let (store, undo) = makeStore(project)
        let saved = try #require(ProjectCommand.newStyle(
            fromTitle: Fixture.id(10), in: project, newID: Fixture.id(950), name: "Big"))
        #expect(saved.style.id == Fixture.id(950))
        #expect(saved.style.name == "Big")
        #expect(saved.style.fontSizeRatio == 0.12)
        #expect(saved.style.position == F.style(800).position)

        #expect(store.performInGesture(saved.commands[0], saved.commands[1]))
        #expect(undo.undoActionName == "Change Title Style")
        let title = try #require(store.project.titles.first { $0.id == Fixture.id(10) })
        #expect(title.styleID == Fixture.id(950))
        #expect(title.styleOverrides == StyleOverrides(position: .top))
        // Same effective size as before the save.
        #expect(try style(of: Fixture.id(10), in: store.project)
            .applying(title.styleOverrides).fontSizeRatio == 0.12)

        undo.undo()
        #expect(store.project == project)
        #expect(!undo.canUndo)
    }

    @Test func newStyleWithOnlyASizeOverrideClearsOverrides() throws {
        var project = F.project
        ProjectCommand.setTitleStyleOverrides(
            id: Fixture.id(10), overrides: StyleOverrides(fontSizeRatio: 0.03))
            .apply(to: &project)
        let saved = try #require(ProjectCommand.newStyle(
            fromTitle: Fixture.id(10), in: project, newID: Fixture.id(950), name: "Small"))
        for command in saved.commands { #expect(command.apply(to: &project)) }
        #expect(project.titles[0].styleOverrides == nil)
        #expect(try style(of: Fixture.id(10), in: project).fontSizeRatio == 0.03)
        #expect(ProjectCommand.newStyle(fromTitle: Fixture.id(99), in: project,
                                        newID: Fixture.id(951), name: "X")?.style == nil)
    }

    // MARK: Groups

    /// `F.project` plus title 12 on style 800: three titles share it.
    private var three: Project {
        var project = F.project
        project.titles.append(Fixture.title(12, segment: 3, offset: 300))
        return project
    }

    private let pair: Set<UUID> = [Fixture.id(10), Fixture.id(11)]

    @Test func groupForksOneSharedStyleFromALibraryStyle() throws {
        var project = three
        let look = edited(try style(of: Fixture.id(10), in: project))
        let command = try #require(ProjectCommand.titlesLook(
            look, forTitles: pair, in: project, libraryStyleIDs: library, forkID: Fixture.id(900)))
        #expect(command.actionName == "Change Title Look")
        #expect(command.apply(to: &project))
        #expect(project.titles.map(\.styleID) == [Fixture.id(900), Fixture.id(900), Fixture.id(800)])
        #expect(try style(of: Fixture.id(10), in: project).name == "Embedded (custom)")
        #expect(project.styles.map(\.id) == [Fixture.id(800), Fixture.id(900)])
    }

    @Test func groupWithAPrivateStyleIsEditedInPlace() throws {
        var project = three
        try #require(ProjectCommand.titlesLook(
            edited(try style(of: Fixture.id(10), in: project)), forTitles: pair, in: project,
            libraryStyleIDs: library, forkID: Fixture.id(900))).apply(to: &project)
        #expect(ProjectCommand.titlesHavePrivateStyle(pair, in: project, libraryStyleIDs: library))

        var look = try style(of: Fixture.id(10), in: project)
        look.weight = .black
        let command = try #require(ProjectCommand.titlesLook(
            look, forTitles: pair, in: project, libraryStyleIDs: library, forkID: Fixture.id(901)))
        #expect(command == .setTitlesLook(ids: pair, style: look))
        #expect(command.apply(to: &project))
        #expect(project.styles.count == 2)
        #expect(try style(of: Fixture.id(11), in: project).weight == .black)
    }

    @Test func groupLookRefusedWhenAnOutsiderUsesTheStyle() throws {
        var project = three
        let before = project
        // Title 12 also uses 800, so 800 cannot be edited for 10 and 11 alone.
        #expect(!ProjectCommand.setTitlesLook(ids: pair, style: F.style(800))
            .apply(to: &project))
        #expect(!ProjectCommand.setTitlesLook(ids: [], style: F.style(801)).apply(to: &project))
        #expect(!ProjectCommand.setTitlesLook(ids: [Fixture.id(10), Fixture.id(99)],
                                              style: F.style(801)).apply(to: &project))
        #expect(project == before)
        // Not private even without the library rule: the helper forks instead.
        #expect(!ProjectCommand.titlesHavePrivateStyle(pair, in: project, libraryStyleIDs: []))
        let command = try #require(ProjectCommand.titlesLook(
            F.style(800), forTitles: pair, in: project, libraryStyleIDs: [],
            forkID: Fixture.id(900)))
        if case let .setTitlesLook(_, style) = command {
            #expect(style.id == Fixture.id(900))
        } else {
            Issue.record("expected setTitlesLook, got \(command)")
        }
    }

    @Test func mixedGroupForksFromTheFirstTitlesLook() throws {
        var project = three
        ProjectCommand.setTitleStyle(ids: [Fixture.id(11)], style: F.style(801, name: "Other"))
            .apply(to: &project)
        var look = try style(of: Fixture.id(10), in: project)
        look.weight = .light
        try #require(ProjectCommand.titlesLook(
            look, forTitles: pair, in: project, libraryStyleIDs: library,
            forkID: Fixture.id(900))).apply(to: &project)
        let shared = try style(of: Fixture.id(11), in: project)
        #expect(shared.id == Fixture.id(900))
        #expect(shared.name == "Embedded (custom)" && shared.weight == .light)
        // 801 is no longer used and is pruned.
        #expect(project.styles.map(\.id) == [Fixture.id(800), Fixture.id(900)])
    }

    @Test func singleEditAfterAGroupEditForksOnlyThatTitle() throws {
        var project = three
        try #require(ProjectCommand.titlesLook(
            edited(try style(of: Fixture.id(10), in: project)), forTitles: pair, in: project,
            libraryStyleIDs: library, forkID: Fixture.id(900))).apply(to: &project)
        var look = try style(of: Fixture.id(11), in: project)
        look.weight = .heavy
        let command = try #require(ProjectCommand.titlesLook(
            look, forTitles: [Fixture.id(11)], in: project, libraryStyleIDs: library,
            forkID: Fixture.id(901)))
        #expect(command.apply(to: &project))
        #expect(project.titles.map(\.styleID) == [Fixture.id(900), Fixture.id(901), Fixture.id(800)])
        #expect(try style(of: Fixture.id(10), in: project).weight == .bold)
        #expect(try style(of: Fixture.id(11), in: project).name == "Embedded (custom)")
    }

    @MainActor
    @Test func groupSliderDragIsOneUndoStep() throws {
        let original = three
        let (store, undo) = makeStore(original)
        store.beginGesture(named: "Change Title Look")
        for size in [0.07, 0.08, 0.09] {
            var look = try style(of: Fixture.id(10), in: store.project)
            look.fontSizeRatio = size
            #expect(store.perform(try #require(ProjectCommand.titlesLook(
                look, forTitles: pair, in: store.project, libraryStyleIDs: library))))
        }
        store.endGesture()
        #expect(undo.undoActionName == "Change Title Look")
        #expect(store.project.styles.count == original.styles.count + 1)
        undo.undo()
        #expect(store.project == original)
        #expect(!undo.canUndo)
    }

    @MainActor
    @Test func groupChipChangeIsOneUndoStep() {
        // As the panel does it: one command per title inside one gesture.
        let original = three
        let (store, undo) = makeStore(original)
        store.beginGesture(named: "Change Title Layout")
        for id in pair {
            store.perform(.setTitleStyleOverrides(id: id, overrides: StyleOverrides(position: .top)))
        }
        store.endGesture()
        #expect(store.project.titles.filter { $0.styleOverrides?.position == .top }.count == 2)
        #expect(undo.undoActionName == "Change Title Layout")
        undo.undo()
        #expect(store.project == original)
        #expect(!undo.canUndo)
    }

    @Test func newStyleForAGroupAppliesToAllAndClearsTheirSizes() throws {
        var project = three
        ProjectCommand.setTitleStyleOverrides(
            id: Fixture.id(11), overrides: StyleOverrides(position: .top, fontSizeRatio: 0.2))
            .apply(to: &project)
        let saved = try #require(ProjectCommand.newStyle(
            fromTitle: Fixture.id(10), applyingTo: pair, in: project, newID: Fixture.id(950),
            name: "Group"))
        // Title 10 has no size override: the saved size is its style's.
        #expect(saved.style.fontSizeRatio == F.style(800).fontSizeRatio)
        for command in saved.commands { #expect(command.apply(to: &project)) }
        #expect(project.titles.map(\.styleID) == [Fixture.id(950), Fixture.id(950), Fixture.id(800)])
        #expect(project.titles[1].styleOverrides == StyleOverrides(position: .top))
    }

    // MARK: Update library style

    @Test func forkRemembersItsLibraryStyle() throws {
        var project = F.project
        try #require(ProjectCommand.titleLook(
            edited(try style(of: Fixture.id(10), in: project)), forTitle: Fixture.id(10),
            in: project, libraryStyleIDs: library, forkID: Fixture.id(900))).apply(to: &project)
        #expect(try style(of: Fixture.id(10), in: project).basedOn == Fixture.id(800))

        // Editing the private copy, or forking it again, keeps the origin.
        var again = try style(of: Fixture.id(10), in: project)
        again.weight = .black
        try #require(ProjectCommand.titleLook(again, forTitle: Fixture.id(10), in: project,
                                              libraryStyleIDs: library)).apply(to: &project)
        #expect(try style(of: Fixture.id(10), in: project).basedOn == Fixture.id(800))

        // A style that is not in the library has no origin to remember.
        var other = F.project
        try #require(ProjectCommand.titleLook(
            edited(try style(of: Fixture.id(10), in: other)), forTitle: Fixture.id(10),
            in: other, libraryStyleIDs: [], forkID: Fixture.id(900))).apply(to: &other)
        #expect(try style(of: Fixture.id(10), in: other).basedOn == nil)

        // A new library style is not a copy of anything.
        let saved = try #require(ProjectCommand.newStyle(
            fromTitle: Fixture.id(10), in: project, newID: Fixture.id(950), name: "New"))
        #expect(saved.style.basedOn == nil)
    }

    @Test func updateWritesTheLookOverItsLibraryStyle() throws {
        var project = three
        try #require(ProjectCommand.titlesLook(
            edited(try style(of: Fixture.id(10), in: project)), forTitles: pair, in: project,
            libraryStyleIDs: library, forkID: Fixture.id(900))).apply(to: &project)
        ProjectCommand.setTitleStyleOverrides(
            id: Fixture.id(10), overrides: StyleOverrides(position: .top, fontSizeRatio: 0.12))
            .apply(to: &project)
        let (store, undo) = makeStore(project)

        let updated = try #require(ProjectCommand.updatedLibraryStyle(
            fromTitle: Fixture.id(10), applyingTo: pair, in: project, name: "Embedded"))
        #expect(updated.style.id == Fixture.id(800))
        #expect(updated.style.name == "Embedded")
        #expect(updated.style.basedOn == nil)
        #expect(updated.style.textColor == RGBA(red: 1, green: 0, blue: 0))
        #expect(updated.style.fontSizeRatio == 0.12)

        store.beginGesture(named: "Change Title Style")
        for command in updated.commands { #expect(store.perform(command)) }
        store.endGesture()
        // The pair and title 12, still on the library style, all get the look.
        #expect(store.project.titles.map(\.styleID)
            == [Fixture.id(800), Fixture.id(800), Fixture.id(800)])
        #expect(store.project.styles == [updated.style])
        #expect(store.project.titles[0].styleOverrides == StyleOverrides(position: .top))

        undo.undo()
        #expect(store.project == project)
    }

    @Test func updateNeedsACustomisedCopy() {
        #expect(ProjectCommand.updatedLibraryStyle(fromTitle: Fixture.id(10), in: F.project,
                                                   name: "Embedded") == nil)
        #expect(ProjectCommand.updatedLibraryStyle(fromTitle: Fixture.id(99), in: F.project,
                                                   name: "Embedded") == nil)
    }

    @Test func selectAllCaptionsFindsOnlyMarkedTitles() {
        var project = three
        project.titles[0].origin = .autoCaption
        project.titles[2].origin = .autoCaption
        #expect(AutoCaptions.titleIDs(in: project) == [Fixture.id(10), Fixture.id(12)])
        #expect(AutoCaptions.titleIDs(in: F.project).isEmpty)
    }
}
