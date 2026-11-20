import Foundation
import Testing
@testable import TitleCutCore

/// Edits made outside a user event (MCP calls, async work) must each be
/// one undo step, even though the document write registers undo itself.
@MainActor
struct UndoGroupingTests {
    private final class Target: NSObject {}

    private func makeStore() -> (ProjectStore, UndoManager) {
        let store = ProjectStore(project: Fixture.single)
        let undo = UndoManager()
        store.undoManager = undo
        let target = Target()
        // As SwiftUI's document binding does: register on every write.
        store.write = { _ in undo.registerUndo(withTarget: target) { _ in } }
        return (store, undo)
    }

    @Test func eachEditOutsideAnEventIsItsOwnClosedStep() {
        let (store, undo) = makeStore()
        #expect(store.perform(.splitSegment(atOutputTime: 900, newSegmentID: Fixture.id(2))))
        #expect(undo.groupingLevel == 0)
        #expect(store.perform(.setTitleText(id: Fixture.id(10), text: "Changed")))
        #expect(undo.groupingLevel == 0)
        undo.undo()
        #expect(store.project.titles[0].text == "T10")
        #expect(store.project.segments.count == 2)
        undo.undo()
        #expect(store.project == Fixture.single)
    }

    @Test func severalCommandsAreOneStepWithOneWrite() {
        let (store, undo) = makeStore()
        var writes = 0
        let inner = store.write
        store.write = { writes += 1; inner?($0) }
        #expect(store.perform([.setTitleText(id: Fixture.id(10), text: "A"),
                               .setTitleText(id: Fixture.id(11), text: "B"),
                               .deleteTitles(ids: [Fixture.id(99)])], named: "Edit Titles"))
        #expect(writes == 1)
        #expect(undo.undoActionName == "Edit Titles")
        undo.undo()
        #expect(store.project == Fixture.single)
        #expect(!store.perform([.deleteTitles(ids: [Fixture.id(99)])], named: "None"))
    }
}
