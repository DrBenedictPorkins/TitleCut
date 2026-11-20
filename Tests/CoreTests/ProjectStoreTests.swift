import Foundation
import Testing
@testable import TitleCutCore

@MainActor
struct ProjectStoreTests {
    private func makeStore(_ project: Project) -> (ProjectStore, UndoManager, Box) {
        let store = ProjectStore(project: project)
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        let written = Box()
        store.write = { written.values.append($0) }
        return (store, undo, written)
    }

    final class Box { var values: [Project] = [] }

    nonisolated static let commands: [(Project, ProjectCommand)] = [
        (Project(id: Fixture.projectID), .setSource(Fixture.source, segmentID: Fixture.id(1))),
        (Fixture.single, .splitSegment(atOutputTime: 1000, newSegmentID: Fixture.id(2))),
        (Fixture.threeSegments, .deleteSegment(id: Fixture.id(1))),
        (Fixture.threeSegments, .deleteSegment(id: Fixture.id(2))),
    ]

    @Test(arguments: 0..<commands.count)
    func everyCommandUndoesToIdenticalProjectAndRedoes(index: Int) {
        let (original, command) = Self.commands[index]
        let (store, undo, written) = makeStore(original)
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
        #expect(written.values == [edited, original, edited, original])
    }

    @Test func rejectedCommandRegistersNothing() {
        let (store, undo, written) = makeStore(Fixture.threeSegments)
        #expect(!store.perform(.deleteSegment(id: Fixture.id(99))))
        #expect(!undo.canUndo)
        #expect(written.values.isEmpty)
    }

    @Test func eachCommandIsOneUndoStep() {
        let (store, undo, _) = makeStore(Fixture.single)
        store.perform(.splitSegment(atOutputTime: 1000, newSegmentID: Fixture.id(2)))
        let afterFirst = store.project
        store.perform(.splitSegment(atOutputTime: 2000, newSegmentID: Fixture.id(3)))
        store.perform(.deleteSegment(id: Fixture.id(2)))
        undo.undo()
        undo.undo()
        #expect(store.project == afterFirst)
        undo.undo()
        #expect(store.project == Fixture.single)
        #expect(!undo.canUndo)
    }

    @Test func gestureCoalescesIntoOneUndoStep() {
        let (store, undo, _) = makeStore(Fixture.single)
        store.beginGesture(named: "Trim")
        store.perform(.splitSegment(atOutputTime: 1000, newSegmentID: Fixture.id(2)))
        store.perform(.splitSegment(atOutputTime: 2000, newSegmentID: Fixture.id(3)))
        #expect(!undo.canUndo)
        store.endGesture()
        #expect(undo.undoActionName == "Trim")
        let edited = store.project
        undo.undo()
        #expect(store.project == Fixture.single)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(store.project == edited)
    }

    @Test func gestureWithoutChangeRegistersNothing() {
        let (store, undo, _) = makeStore(Fixture.single)
        store.beginGesture(named: "Nothing")
        store.endGesture()
        #expect(!undo.canUndo)
    }

    @Test func deleteSelectedClearsSelectionAndUndoKeepsItCleared() {
        let (store, undo, _) = makeStore(Fixture.threeSegments)
        store.selectedSegmentID = Fixture.id(2)
        #expect(store.deleteSelectedSegment())
        #expect(store.selectedSegmentID == nil)
        #expect(!store.deleteSelectedSegment())
        undo.undo()
        #expect(store.project == Fixture.threeSegments)
        #expect(store.selectedSegmentID == nil)  // selection is not undoable
    }

    @Test func documentDidChangeAdoptsWithoutUndo() {
        let (store, undo, written) = makeStore(Fixture.threeSegments)
        store.selectedSegmentID = Fixture.id(2)
        store.documentDidChange(Fixture.single)
        #expect(store.project == Fixture.single)
        #expect(store.selectedSegmentID == nil)
        #expect(!undo.canUndo)
        #expect(written.values.isEmpty)
    }
}
