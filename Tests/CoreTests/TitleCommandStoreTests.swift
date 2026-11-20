import Foundation
import Testing
@testable import TitleCutCore

@MainActor
struct TitleCommandStoreTests {
    typealias F = TitleCommandFixture

    private func makeStore(_ project: Project) -> (ProjectStore, UndoManager) {
        let store = ProjectStore(project: project)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        return (store, undo)
    }

    nonisolated static let commands: [ProjectCommand] = [
        .addTitle(id: Fixture.id(20), text: "New", atOutputTime: 1500, style: F.style(801)),
        .addTitle(id: Fixture.id(20), text: "New", atOutputTime: 0, style: F.style(800)),
        .moveTitle(id: Fixture.id(10), toOutputStart: 2000),
        .setTitleDuration(id: Fixture.id(10), duration: 1000),
        .setTitleText(id: Fixture.id(10), text: "Changed"),
        .setTitleTransitionIn(id: Fixture.id(10),
                              transition: Transition(kind: .scale, duration: 60, easing: .easeIn)),
        .setTitleTransitionOut(id: Fixture.id(11),
                               transition: Transition(kind: .fade, duration: 60, easing: .linear)),
        .setTitleStyleOverrides(id: Fixture.id(10), overrides: StyleOverrides(position: .center)),
        .setTitleStyle(ids: [Fixture.id(10), Fixture.id(11)], style: F.style(801)),
        .deleteTitles(ids: [Fixture.id(10)]),
        .deleteTitles(ids: [Fixture.id(10), Fixture.id(11)]),
    ]

    @Test(arguments: 0..<commands.count)
    func everyTitleCommandUndoesToIdenticalProjectAndRedoes(index: Int) {
        let command = Self.commands[index]
        let original = F.project
        let (store, undo) = makeStore(original)
        #expect(store.perform(command))
        let edited = store.project
        #expect(edited != original)
        #expect(undo.undoActionName == command.actionName)

        undo.undo()
        #expect(store.project == original)
        #expect(undo.redoActionName == command.actionName)
        undo.redo()
        #expect(store.project == edited)
        undo.undo()
        #expect(store.project == original)
    }

    @Test func dragMoveCoalescesIntoOneUndoStep() {
        let (store, undo) = makeStore(F.project)
        store.beginGesture(named: "Move Title")
        for start: Tick in stride(from: 150, through: 2100, by: 150) {
            store.perform(.moveTitle(id: Fixture.id(10), toOutputStart: start))
        }
        #expect(!undo.canUndo)
        store.endGesture()
        #expect(undo.undoActionName == "Move Title")
        #expect(store.project.titles[0].anchor
                == TitleAnchor(segmentID: Fixture.id(3), offset: 300))
        let moved = store.project

        undo.undo()
        #expect(store.project == F.project)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(store.project == moved)
    }

    @Test func dragResizeCoalescesIntoOneUndoStep() {
        let (store, undo) = makeStore(F.project)
        store.beginGesture(named: "Change Title Duration")
        for duration: Tick in [400, 500, 650] {
            store.perform(.setTitleDuration(id: Fixture.id(10), duration: duration))
        }
        store.endGesture()
        #expect(store.project.titles[0].duration == 650)
        undo.undo()
        #expect(store.project == F.project)
        #expect(!undo.canUndo)
    }

    @Test func dragOnScreenCoalescesIntoOneUndoStepAndPlacesCentre() {
        let (store, undo) = makeStore(F.project)
        store.beginGesture(named: "Move Title on Screen")
        for x in [0.3, 0.35, 0.42] {
            store.perform(.setTitleStyleOverrides(
                id: Fixture.id(10), overrides: StyleOverrides(position: .custom(x: x, y: 0.2))))
        }
        store.endGesture()
        #expect(undo.undoActionName == "Move Title on Screen")
        #expect(store.project.titles[0].styleOverrides?.position == .custom(x: 0.42, y: 0.2))

        let frame = FrameRenderer.titleFrame(contentSize: CGSize(width: 200, height: 60),
                                             position: .custom(x: 0.42, y: 0.2),
                                             alignment: .leading,
                                             renderSize: CGSize(width: 1000, height: 500))
        #expect(frame.midX == 420)
        #expect(frame.midY == 100)

        undo.undo()
        #expect(store.project == F.project)
        #expect(!undo.canUndo)
    }

    @Test func titleSelectionIsPrunedOnDeleteAndNotRestoredByUndo() {
        let (store, undo) = makeStore(F.project)
        store.selectedTitleIDs = [Fixture.id(10), Fixture.id(11)]
        #expect(store.perform(.deleteTitles(ids: [Fixture.id(10)])))
        #expect(store.selectedTitleIDs == [Fixture.id(11)])
        undo.undo()
        #expect(store.project == F.project)
        #expect(store.selectedTitleIDs == [Fixture.id(11)])
    }

    @Test func titleSelectionIsPrunedWhenUndoRemovesTitle() {
        let (store, undo) = makeStore(F.project)
        store.perform(.addTitle(id: Fixture.id(20), text: "New", atOutputTime: 0,
                                style: F.style(800)))
        store.selectedTitleIDs = [Fixture.id(20), Fixture.id(10)]
        undo.undo()
        #expect(store.selectedTitleIDs == [Fixture.id(10)])
    }

    @Test func titleSelectionIsPrunedWhenSegmentDeleteTakesItsTitles() {
        let (store, _) = makeStore(F.project)
        store.selectedTitleIDs = [Fixture.id(10), Fixture.id(11)]
        store.perform(.deleteSegment(id: Fixture.id(1)))
        #expect(store.selectedTitleIDs == [Fixture.id(11)])
    }

    @Test func deleteSelectedTitlesIsOneUndoStep() {
        let (store, undo) = makeStore(F.project)
        #expect(!store.deleteSelectedTitles())
        store.selectedTitleIDs = [Fixture.id(10), Fixture.id(11)]
        #expect(store.deleteSelectedTitles())
        #expect(store.project.titles.isEmpty)
        #expect(store.selectedTitleIDs.isEmpty)
        #expect(undo.undoActionName == "Delete Titles")
        undo.undo()
        #expect(store.project == F.project)
        #expect(!undo.canUndo)
    }

    @Test func documentDidChangePrunesTitleSelection() {
        let (store, _) = makeStore(F.project)
        store.selectedTitleIDs = [Fixture.id(10), Fixture.id(11)]
        var changed = F.project
        changed.titles.removeFirst()
        store.documentDidChange(changed)
        #expect(store.selectedTitleIDs == [Fixture.id(11)])
    }
}
