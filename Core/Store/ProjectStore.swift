import Foundation
import Observation

/// The single mutation path for one document window (§3.1, §8).
///
/// Holds the current `Project`, applies `ProjectCommand`s, and registers
/// whole-snapshot undo on the window's `UndoManager` (C1: the store owns
/// none). Every change is written back through `write`, which the app wires
/// to the DocumentGroup binding (C2).
@MainActor
@Observable
public final class ProjectStore {
    public private(set) var project: Project
    /// Selected segment. Not saved, not undoable (Q1).
    public var selectedSegmentID: UUID? {
        didSet {
            guard selectedSegmentID != nil else { return }
            if selectedMusicID != nil { selectedMusicID = nil }
            if selectedTransition != nil { selectedTransition = nil }
        }
    }
    /// Selected titles, one or more. Not saved, not undoable.
    public var selectedTitleIDs: Set<UUID> = [] {
        didSet {
            guard !selectedTitleIDs.isEmpty else { return }
            if selectedMusicID != nil { selectedMusicID = nil }
            if selectedTransition != nil { selectedTransition = nil }
        }
    }
    /// Selected music piece. Selecting one clears the title and segment
    /// selection, and selecting either of those clears it.
    public var selectedMusicID: UUID? {
        didSet {
            guard selectedMusicID != nil else { return }
            if !selectedTitleIDs.isEmpty { selectedTitleIDs = [] }
            if selectedSegmentID != nil { selectedSegmentID = nil }
            if selectedTransition != nil { selectedTransition = nil }
        }
    }
    /// Selected clip transition, like the music piece: selecting it clears
    /// the other selections, and selecting any of them clears it.
    public var selectedTransition: TransitionPoint? {
        didSet {
            guard selectedTransition != nil else { return }
            if !selectedTitleIDs.isEmpty { selectedTitleIDs = [] }
            if selectedSegmentID != nil { selectedSegmentID = nil }
            if selectedMusicID != nil { selectedMusicID = nil }
        }
    }

    /// The document window's undo manager, injected when the window appears.
    @ObservationIgnored public weak var undoManager: UndoManager?
    /// Receives every new project value, including undo and redo.
    @ObservationIgnored public var write: ((Project) -> Void)?

    @ObservationIgnored private var gestureDepth = 0
    @ObservationIgnored private var gestureStart: Project?
    @ObservationIgnored private var gestureName = ""

    public init(project: Project) {
        self.project = project
    }

    /// Applies `command` and registers one undo step named for it.
    /// Inside a gesture, the change joins the gesture's single step.
    /// - Returns: `false` if the command did not apply.
    @discardableResult
    public func perform(_ command: ProjectCommand) -> Bool {
        var next = project
        guard command.apply(to: &next), next != project else { return false }
        if gestureDepth > 0 {
            replace(with: next)
        } else {
            commit(next, undoingTo: project, name: command.actionName)
        }
        return true
    }

    /// Applies `commands` in order as one undo step named `name`, with one
    /// document write. Commands that do not apply are skipped. Returns
    /// whether the project changed.
    @discardableResult
    public func perform(_ commands: [ProjectCommand], named name: String) -> Bool {
        var next = project
        for command in commands { command.apply(to: &next) }
        guard next != project else { return false }
        if gestureDepth > 0 {
            replace(with: next)
        } else {
            commit(next, undoingTo: project, name: name)
        }
        return true
    }

    /// Inside a gesture, applies `commands` in order to the project as it was
    /// when the gesture began, replacing the previous step. A drag therefore
    /// equals one edit from where it started, whatever path it took.
    /// Outside a gesture, the commands undo as one step named for the last.
    /// - Returns: `false`, leaving the project unchanged, if any command did not apply.
    @discardableResult
    public func performInGesture(_ commands: ProjectCommand...) -> Bool {
        let ownsGesture = gestureDepth == 0
        if ownsGesture { beginGesture(named: commands.last?.actionName ?? "") }
        defer { if ownsGesture { endGesture() } }
        guard var next = gestureStart else { return false }
        for command in commands {
            guard command.apply(to: &next) else { return false }
        }
        if next != project { replace(with: next) }
        return true
    }

    /// Starts a continuous edit; changes until `endGesture()` undo as one step.
    public func beginGesture(named name: String) {
        if gestureDepth == 0 {
            gestureStart = project
            gestureName = name
        }
        gestureDepth += 1
    }

    /// Ends a continuous edit and registers its undo step, if anything changed.
    public func endGesture() {
        guard gestureDepth > 0 else { return }
        gestureDepth -= 1
        guard gestureDepth == 0, let start = gestureStart else { return }
        gestureStart = nil
        if start != project {
            registerUndo(restoring: start, redoTo: project, name: gestureName)
        }
    }

    /// Adopts a project that changed outside the store (e.g. File > Revert).
    /// Registers no undo.
    public func documentDidChange(_ newValue: Project) {
        guard newValue != project else { return }
        project = newValue
        pruneSelection()
    }

    /// Gives the project a new ID, for a file copied from one already open.
    /// Not an edit: registers no undo, but is written to the document.
    public func renewID() {
        var next = project
        next.id = UUID()
        project = next
        undoManager?.disableUndoRegistration()
        write?(next)
        undoManager?.enableUndoRegistration()
    }

    /// Deletes the selected music piece, if any.
    @discardableResult
    public func deleteSelectedMusic() -> Bool {
        guard let id = selectedMusicID else { return false }
        return perform(.deleteMusic(id: id))
    }

    /// Removes the selected clip transition, if any.
    @discardableResult
    public func deleteSelectedTransition() -> Bool {
        guard let point = selectedTransition else { return false }
        return perform(.setClipTransition(at: point, transition: nil))
    }

    /// Deletes the selected segment, if any.
    @discardableResult
    public func deleteSelectedSegment() -> Bool {
        guard let id = selectedSegmentID else { return false }
        return perform(.deleteSegment(id: id))
    }

    /// Deletes the selected titles, if any.
    @discardableResult
    public func deleteSelectedTitles() -> Bool {
        guard !selectedTitleIDs.isEmpty else { return false }
        return perform(.deleteTitles(ids: selectedTitleIDs))
    }

    // MARK: Private

    private func commit(_ next: Project, undoingTo previous: Project, name: String) {
        inTopLevelGroup {
            replace(with: next)
            registerUndo(restoring: previous, redoTo: next, name: name)
        }
    }

    private func replace(with next: Project) {
        project = next
        pruneSelection()
        write?(next)
    }

    private func registerUndo(restoring previous: Project, redoTo next: Project, name: String) {
        inTopLevelGroup {
            undoManager?.registerUndo(withTarget: self) { store in
                MainActor.assumeIsolated {
                    // Registering again while undoing records the redo step.
                    store.commit(previous, undoingTo: next, name: name)
                }
            }
            undoManager?.setActionName(name)
        }
    }

    /// Runs `body` inside an undo group that closes when it returns.
    ///
    /// Opens a group only if none is open (event grouping or an undo in
    /// progress). Outside an event (an async load, an MCP call), registering
    /// with `groupsByEvent` on opens an implicit event group that can stay
    /// open until the next input event; every later change would then join
    /// it, and NSDocument counts a change only when a top-level group closes.
    /// Writing the document registers undo too (SwiftUI's document binding),
    /// so writes go inside this group with our own registration. Event
    /// grouping is suspended so this group is the top-level one.
    private func inTopLevelGroup(_ body: () -> Void) {
        guard let undoManager, undoManager.groupingLevel == 0 else {
            body()
            return
        }
        let groupsByEvent = undoManager.groupsByEvent
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        body()
        undoManager.endUndoGrouping()
        undoManager.groupsByEvent = groupsByEvent
    }


    private func pruneSelection() {
        if let id = selectedMusicID, !project.music.contains(where: { $0.id == id }) {
            selectedMusicID = nil
        }
        if let id = selectedSegmentID, !project.segments.contains(where: { $0.id == id }) {
            selectedSegmentID = nil
        }
        if let point = selectedTransition, point.transition(in: project) == nil {
            selectedTransition = nil
        }
        if !selectedTitleIDs.isEmpty {
            let pruned = selectedTitleIDs.intersection(project.titles.map(\.id))
            if pruned != selectedTitleIDs { selectedTitleIDs = pruned }
        }
    }
}
