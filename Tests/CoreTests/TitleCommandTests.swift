import Foundation
import Testing
@testable import TitleCutCore

/// Styles for title command tests.
enum TitleCommandFixture {
    static func style(_ n: Int, name: String = "Style") -> TitleStyle {
        TitleStyle(id: Fixture.id(n), name: name, fontName: "Helvetica Neue",
                   fontSizeRatio: 0.06, weight: .bold, textColor: RGBA(red: 1, green: 1, blue: 1),
                   alignment: .center, position: .lowerThird, maxWidthRatio: 0.8)
    }

    /// `Fixture.threeSegments` with style 800 embedded, as titles 10 and 11 use it.
    static var project: Project {
        var project = Fixture.threeSegments
        project.styles = [style(800, name: "Embedded")]
        return project
    }
}

struct TitleCommandTests {
    typealias F = TitleCommandFixture

    // MARK: Add

    @Test func addAnchorsToSegmentAtTimeWithDefaults() throws {
        var project = F.project
        #expect(ProjectCommand.addTitle(id: Fixture.id(20), text: "Hello", atOutputTime: 1500,
                                        style: F.style(801)).apply(to: &project))
        let title = try #require(project.titles.last)
        #expect(title.id == Fixture.id(20))
        #expect(title.text == "Hello")
        #expect(title.anchor == TitleAnchor(segmentID: Fixture.id(2), offset: 300))
        #expect(title.duration == ProjectCommand.defaultTitleDuration)
        #expect(title.styleID == Fixture.id(801))
        #expect(title.styleOverrides == nil)
        #expect(title.transitionIn == ProjectCommand.defaultTransitionIn)
        #expect(title.transitionOut == ProjectCommand.defaultTransitionOut)
        #expect(project.styles.map(\.id) == [Fixture.id(800), Fixture.id(801)])
    }

    @Test func addUsesGivenDurationAndTransitions() throws {
        var project = F.project
        let fade = Transition(kind: .typewriter, duration: 60, easing: .linear)
        ProjectCommand.addTitle(id: Fixture.id(20), text: "", atOutputTime: 0,
                                style: F.style(800), duration: 900,
                                transitionIn: fade, transitionOut: .none).apply(to: &project)
        let title = try #require(project.titles.last)
        #expect(title.duration == 900)
        #expect(title.transitionIn == fade)
        #expect(title.transitionOut == .none)
    }

    @Test func addDoesNotDuplicateOrReplaceAnEmbeddedStyle() {
        var project = F.project
        var edited = F.style(800, name: "Library version")
        edited.fontSizeRatio = 0.2
        ProjectCommand.addTitle(id: Fixture.id(20), text: "A", atOutputTime: 0, style: edited)
            .apply(to: &project)
        ProjectCommand.addTitle(id: Fixture.id(21), text: "B", atOutputTime: 10, style: edited)
            .apply(to: &project)
        #expect(project.styles == [F.style(800, name: "Embedded")])
        #expect(project.titles.suffix(2).map(\.styleID) == [Fixture.id(800), Fixture.id(800)])
    }

    @Test(arguments: [Tick(-1), 3000, 3500])
    func addOutsideTimelineIsRefused(time: Tick) {
        var project = F.project
        #expect(!ProjectCommand.addTitle(id: Fixture.id(20), text: "X", atOutputTime: time,
                                         style: F.style(801)).apply(to: &project))
        #expect(project == F.project)
    }

    @Test func addRefusesDuplicateIDAndNonPositiveDuration() {
        var project = F.project
        #expect(!ProjectCommand.addTitle(id: Fixture.id(10), text: "X", atOutputTime: 0,
                                         style: F.style(801)).apply(to: &project))
        #expect(!ProjectCommand.addTitle(id: Fixture.id(20), text: "X", atOutputTime: 0,
                                         style: F.style(801), duration: 0).apply(to: &project))
        #expect(project == F.project)
    }

    // MARK: Move

    @Test func moveAcrossSplitBoundaryReanchors() throws {
        var project = Fixture.single
        ProjectCommand.splitSegment(atOutputTime: 1000, newSegmentID: Fixture.id(2))
            .apply(to: &project)
        // Title 10 starts at 300, in segment 1. Move it past the split at 1000.
        #expect(ProjectCommand.moveTitle(id: Fixture.id(10), toOutputStart: 1100)
            .apply(to: &project))
        let title = try #require(project.titles.first { $0.id == Fixture.id(10) })
        #expect(title.anchor == TitleAnchor(segmentID: Fixture.id(2), offset: 100))
        #expect(TimelineMath.titleOutputRange(title, in: project)
                == TickRange(start: 1100, duration: 300))

        // Exactly on the boundary belongs to the later segment; back before it, the earlier.
        ProjectCommand.moveTitle(id: Fixture.id(10), toOutputStart: 1000).apply(to: &project)
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(2), offset: 0))
        ProjectCommand.moveTitle(id: Fixture.id(10), toOutputStart: 999).apply(to: &project)
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(1), offset: 999))
    }

    @Test func moveIntoStillSegmentReanchors() {
        var project = F.project
        ProjectCommand.moveTitle(id: Fixture.id(10), toOutputStart: 1250).apply(to: &project)
        #expect(project.titles[0].anchor == TitleAnchor(segmentID: Fixture.id(2), offset: 50))
        #expect(project.titles[0].duration == 300)
    }

    @Test func moveClampsToTimeline() {
        var project = F.project
        ProjectCommand.moveTitle(id: Fixture.id(11), toOutputStart: -400).apply(to: &project)
        #expect(project.titles[1].anchor == TitleAnchor(segmentID: Fixture.id(1), offset: 0))
        ProjectCommand.moveTitle(id: Fixture.id(11), toOutputStart: 9000).apply(to: &project)
        #expect(project.titles[1].anchor == TitleAnchor(segmentID: Fixture.id(3), offset: 1199))
    }

    @Test func moveUnknownTitleIsRefused() {
        var project = F.project
        #expect(!ProjectCommand.moveTitle(id: Fixture.id(99), toOutputStart: 0)
            .apply(to: &project))
        #expect(project == F.project)
    }

    // MARK: Field edits

    @Test func setDuration() {
        var project = F.project
        #expect(ProjectCommand.setTitleDuration(id: Fixture.id(10), duration: 1500)
            .apply(to: &project))
        #expect(project.titles[0].duration == 1500)
        #expect(!ProjectCommand.setTitleDuration(id: Fixture.id(10), duration: 0)
            .apply(to: &project))
        #expect(!ProjectCommand.setTitleDuration(id: Fixture.id(10), duration: -10)
            .apply(to: &project))
        #expect(project.titles[0].duration == 1500)
    }

    @Test func setTextTransitionsAndOverrides() {
        var project = F.project
        let slide = Transition(kind: .slide(edge: .leading), duration: 120, easing: .easeInOut)
        let overrides = StyleOverrides(position: .top, fontSizeRatio: 0.1)
        ProjectCommand.setTitleText(id: Fixture.id(10), text: "New\ntext").apply(to: &project)
        ProjectCommand.setTitleTransitionIn(id: Fixture.id(10), transition: slide)
            .apply(to: &project)
        ProjectCommand.setTitleTransitionOut(id: Fixture.id(10), transition: .none)
            .apply(to: &project)
        ProjectCommand.setTitleStyleOverrides(id: Fixture.id(10), overrides: overrides)
            .apply(to: &project)
        #expect(project.titles[0].text == "New\ntext")
        #expect(project.titles[0].transitionIn == slide)
        #expect(project.titles[0].transitionOut == .none)
        #expect(project.titles[0].styleOverrides == overrides)
        #expect(project.titles[1] == F.project.titles[1])

        ProjectCommand.setTitleStyleOverrides(id: Fixture.id(10), overrides: nil)
            .apply(to: &project)
        #expect(project.titles[0].styleOverrides == nil)
    }

    @Test func fieldEditsOnUnknownTitleAreRefused() {
        var project = F.project
        let id = Fixture.id(99)
        let commands: [ProjectCommand] = [
            .setTitleDuration(id: id, duration: 10), .setTitleText(id: id, text: "x"),
            .setTitleTransitionIn(id: id, transition: .none),
            .setTitleTransitionOut(id: id, transition: .none),
            .setTitleStyleOverrides(id: id, overrides: nil),
        ]
        for command in commands {
            #expect(!command.apply(to: &project))
        }
        #expect(project == F.project)
    }

    // MARK: Style

    @Test func setStyleOnMultipleTitlesCopiesStyleOnce() {
        var project = F.project
        ProjectCommand.addTitle(id: Fixture.id(12), text: "C", atOutputTime: 2000,
                                style: F.style(800)).apply(to: &project)
        #expect(ProjectCommand.setTitleStyle(ids: [Fixture.id(10), Fixture.id(12)],
                                             style: F.style(801)).apply(to: &project))
        #expect(project.titles.map(\.styleID)
                == [Fixture.id(801), Fixture.id(800), Fixture.id(801)])
        #expect(project.styles.map(\.id) == [Fixture.id(800), Fixture.id(801)])

        ProjectCommand.setTitleStyle(ids: [Fixture.id(11)], style: F.style(801))
            .apply(to: &project)
        // No title uses 800 any more, so it is pruned.
        #expect(project.styles.map(\.id) == [Fixture.id(801)])
        #expect(project.titles.allSatisfy { $0.styleID == Fixture.id(801) })
    }

    @Test func setStyleRefusedIfAnyTitleMissingOrNoneGiven() {
        var project = F.project
        #expect(!ProjectCommand.setTitleStyle(ids: [Fixture.id(10), Fixture.id(99)],
                                              style: F.style(801)).apply(to: &project))
        #expect(!ProjectCommand.setTitleStyle(ids: [], style: F.style(801)).apply(to: &project))
        #expect(project == F.project)
    }

    // MARK: Delete

    @Test func deleteTitlesIgnoresMissingIDs() {
        var project = F.project
        #expect(ProjectCommand.deleteTitles(ids: [Fixture.id(10), Fixture.id(99)])
            .apply(to: &project))
        #expect(project.titles.map(\.id) == [Fixture.id(11)])
        #expect(project.styles == F.project.styles)
        #expect(!ProjectCommand.deleteTitles(ids: [Fixture.id(99)]).apply(to: &project))
    }

    @Test func actionNames() {
        #expect(ProjectCommand.deleteTitles(ids: [Fixture.id(1)]).actionName == "Delete Title")
        #expect(ProjectCommand.deleteTitles(ids: [Fixture.id(1), Fixture.id(2)]).actionName
                == "Delete Titles")
        #expect(ProjectCommand.setTitleStyle(ids: [Fixture.id(1)], style: F.style(1)).actionName
                == "Change Title Style")
    }
}
