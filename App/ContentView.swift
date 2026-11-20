import AppKit
import SwiftUI
import TitleCutCore
import UniformTypeIdentifiers

/// One document window in the option B "Daylight" shell: top bar, preview
/// card with transport, the Instrument inspector, and the timeline card.
struct ContentView: View {
    @Binding var document: TitleCutDocument

    @State private var store: ProjectStore
    @State private var player = PlayerController()
    /// Each video's resolved file, keyed by `VideoSegment.sourceID`; a
    /// missing video has none.
    @State private var sourceURLs: [UUID?: URL] = [:]
    /// The videos `sourceURLs` was resolved for.
    @State private var resolvedSources: [UUID?: SourceVideo] = [:]
    /// Library styles, loaded when the window opens and after a style is saved.
    @State private var libraryStyles: [TitleStyle] = StyleLibrary.builtIns
    @State private var defaultStyleID: UUID = StyleLibrary.lowerThirdID
    /// Layout cache for preview hit-testing and the inspector's landing pad.
    @State private var titleRenderer = TitleRenderer()
    /// A title being dragged to a new resting position in the preview.
    @State private var titleDrag: TitleDrag?
    @State private var reframeDrag: ReframeDrag?
    @State private var windowTitle = ""
    @State private var isEdited = false
    @State private var hasFile = false
    /// Bumped on undo-manager notifications so Undo/Redo enablement refreshes.
    @State private var undoRevision = 0
    @State private var isExportSheetShown = false
    @State private var isAutoCaptionsSheetShown = false
    @State private var isRemoveSilencesSheetShown = false
    @State private var isRemoveFillersSheetShown = false
    /// This window's project as MCP tools see it.
    @State private var mcpSession: MCPSession?
    /// The frozen frame whose camera window is open.
    @State private var cameraStill: CameraTarget?
    /// Bumped on every copy, so the timeline's Paste button appears.
    @State private var clipboardRevision = 0
    /// Why the last Add Music or Freeze Frame failed, shown until dismissed.
    @State private var actionFailure: ActionFailure?
    /// Frame Faces while it runs.
    @State private var faceTask: Task<Void, Never>?
    /// Audio peaks of each video, keyed by `VideoSegment.sourceID`, for the
    /// timeline; memory only. A video whose sound cannot be read has none.
    @State private var waveforms: [UUID?: Waveform] = [:]
    /// The document window, for the open and save panels' sheets.
    @State private var hostWindow = WindowRef()
    @Environment(\.undoManager) private var undoManager

    init(document: Binding<TitleCutDocument>) {
        _document = document
        _store = State(initialValue: ProjectStore(project: document.wrappedValue.project))
    }

    var body: some View {
        withSheets(editor
            .background(Theme.ground)
            .task(id: sourceURLs) {
                // Kept for files already read; a file whose audio cannot be
                // read shows no waveform.
                var loaded = waveforms.filter { sourceURLs[$0.key] != nil }
                for (key, url) in sourceURLs where loaded[key] == nil {
                    guard let waveform = try? await Waveform.load(from: url) else { continue }
                    loaded[key] = waveform
                }
                if !Task.isCancelled { waveforms = loaded }
            }
            .background(WindowStateReader(title: $windowTitle, isEdited: $isEdited,
                                          hasFile: $hasFile, revision: undoRevision,
                                          onWindow: { window in
                                              hostWindow.window = window
                                              mcpSession?.window = window
                                              if let mcpSession {
                                                  MCPHost.shared.ensureUniqueID(mcpSession)
                                              }
                                          }))
            .ignoresSafeArea(.container, edges: .top)
            .preferredColorScheme(.light)
            .frame(minWidth: 900, minHeight: 640)
            .focusedSceneValue(\.projectStore, store)
            .focusedSceneValue(\.playerController, player)
            .focusedSceneValue(\.showExport, canExport ? { isExportSheetShown = true } : nil)
            .focusedSceneValue(\.exportSubtitles, SRT.hasCues(store.project)
                               ? { [store, documentName, hostWindow] in
                                   SubtitleFile.export(store.project, documentName: documentName,
                                                       in: hostWindow.window)
                               } : nil))
        .onAppear {
            store.write = { [binding = $document] project in
                binding.wrappedValue.project = project
            }
            store.undoManager = undoManager
            loadLibrary()
            registerMCPSession()
        }
        .onDisappear {
            if let mcpSession { MCPHost.shared.unregister(mcpSession) }
        }
        .onChange(of: undoManager) { _, newValue in store.undoManager = newValue }
        .onChange(of: document.project) { _, newValue in store.documentDidChange(newValue) }
        .onChange(of: store.project, initial: true) { old, new in
            projectChanged(new, firstLoad: old == new)
            undoRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) {
            _ in undoRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) {
            _ in undoRevision += 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) {
            _ in undoRevision += 1
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            topBar
            VStack(spacing: Theme.gap) {
                HStack(alignment: .top, spacing: Theme.gap) {
                    previewCard
                    InspectorPanel(store: store, libraryStyles: libraryStyles,
                                   defaultStyleID: $defaultStyleID,
                                   renderSize: renderSize, titleRenderer: titleRenderer,
                                   onLibraryChanged: loadLibrary,
                                   editCamera: { cameraStill = CameraTarget(id: $0) },
                                   framing: missingSource == nil
                                       ? ClipFramingContext(
                                           player: player, sourceURLs: sourceURLs,
                                           frameFaces: canFrameFaces && faceTask == nil
                                               ? { frameFaces() } : nil,
                                           findingFaces: faceTask != nil)
                                       : nil)
                }
                .frame(maxHeight: .infinity)
                TimelineView(store: store, player: player, addTitle: addTitle,
                             deleteSelection: deleteSelection,
                             autoCaptions: canExport ? { isAutoCaptionsSheetShown = true } : nil,
                             removeSilences: canRemoveSilences
                                 ? { isRemoveSilencesSheetShown = true } : nil,
                             removeFillers: canRemoveFillers
                                 ? { isRemoveFillersSheetShown = true } : nil,
                             addMusic: canExport ? { addMusic() } : nil,
                             addVideo: canAddVideo ? { VideoPicker.addVideo(for: store, in: hostWindow.window) } : nil,
                             dropVideo: dropVideo,
                             dropImage: store.project.source == nil ? nil : { url, time in
                                 insertImage(from: url, at: time)
                             },
                             freezeFrame: canFreeze ? { freezeFrame() } : nil,
                             insertCard: store.project.segments.isEmpty ? nil : { insertCard() },
                             editActions: editActions,
                             editCamera: { cameraStill = CameraTarget(id: $0) },
                             clipboardRevision: clipboardRevision,
                             waveforms: waveforms)
            }
            .padding(Theme.margin)
        }
    }

    /// The window's sheets and alerts.
    private func withSheets(_ content: some View) -> some View {
        content
            .sheet(isPresented: $isExportSheetShown) {
                if canExport {
                    ExportSheet(project: store.project, sourceURLs: sourceURLs,
                                documentName: documentName)
                }
            }
            .focusedSceneValue(\.showAutoCaptions,
                               canExport ? { isAutoCaptionsSheetShown = true } : nil)
            .sheet(isPresented: $isAutoCaptionsSheetShown) {
                if canExport {
                    // Transcripts are written beside the project, outside undo.
                    AutoCaptionsSheet(store: store, videos: usedVideos,
                                      savedTranscripts: document.transcripts,
                                      libraryStyles: libraryStyles) { transcript in
                        saveTranscript(transcript)
                    }
                }
            }
            .focusedSceneValue(\.showRemoveSilences,
                               canRemoveSilences ? { isRemoveSilencesSheetShown = true } : nil)
            .focusedSceneValue(\.frameFaces,
                               canFrameFaces && faceTask == nil ? { frameFaces() } : nil)
            .focusedSceneValue(\.insertCard,
                               store.project.segments.isEmpty ? nil : { insertCard() })
            .focusedSceneValue(\.showRemoveFillers,
                               canRemoveFillers ? { isRemoveFillersSheetShown = true } : nil)
            .focusedSceneValue(\.addVideo,
                               canAddVideo ? { VideoPicker.addVideo(for: store, in: hostWindow.window) } : nil)
            .focusedSceneValue(\.recordScreen, { recordScreen() })
            .sheet(isPresented: $isRemoveFillersSheetShown) {
                if canRemoveFillers {
                    // Transcripts are written beside the project, outside undo.
                    RemoveFillersSheet(store: store, videos: usedVideos,
                                       savedTranscripts: document.transcripts) { transcript in
                        saveTranscript(transcript)
                    }
                }
            }
            .sheet(item: $cameraStill) { target in
                CameraSheet(store: store, stillID: target.id, renderSize: renderSize)
            }
            .alert(item: $actionFailure) { failure in
                Alert(title: Text(failure.what), message: Text(failure.action))
            }
            .sheet(isPresented: $isRemoveSilencesSheetShown) {
                if !waveforms.isEmpty {
                    RemoveSilencesSheet(store: store, waveforms: waveforms,
                                        sourceURLs: sourceURLs, renderSize: renderSize,
                                        mainPlayer: player)
                }
            }
    }

    // MARK: Top bar

    private var documentName: String {
        guard !windowTitle.isEmpty else { return "Untitled" }
        let suffix = ".titlecut"
        return windowTitle.hasSuffix(suffix) ? String(windowTitle.dropLast(suffix.count))
                                             : windowTitle
    }

    private var topBar: some View {
        let _ = undoRevision
        return TopBar(
            documentName: documentName,
            saveState: isEdited ? "Edited" : (hasFile ? "Saved" : "Not saved"),
            canUndo: undoManager?.canUndo ?? false,
            canRedo: undoManager?.canRedo ?? false,
            canExport: canExport,
            undo: { undoManager?.undo(); undoRevision += 1 },
            redo: { undoManager?.redo(); undoRevision += 1 },
            export: { isExportSheetShown = true },
            shapes: store.project.source.map(OutputShape.offered(for:)) ?? [],
            shape: store.project.source.flatMap {
                OutputShape.of(store.project.output.size, source: $0)
            },
            setShape: { shape in
                guard let source = store.project.source else { return }
                store.perform(.setOutputSize(shape.size(for: source)))
            },
            isRecording: ScreenRecorder.shared.isRecording,
            record: recordOrStop)
    }

    /// Record in the top bar: starts a screen recording, or stops the one
    /// running; `nil` while one is being chosen or saved.
    private var recordOrStop: (() -> Void)? {
        switch ScreenRecorder.shared.phase {
        case .idle: { recordScreen() }
        case .recording: { ScreenRecorder.shared.stop() }
        case .choosing, .finishing: nil
        }
    }

    /// Record Screen: the movie opens as the first video, or is added at the
    /// end of the timeline.
    private func recordScreen() {
        ScreenRecorder.shared.start(in: hostWindow.window) { [store, hostWindow] url in
            if store.project.source == nil {
                VideoPicker.openVideo(at: url, for: store, in: hostWindow.window)
            } else {
                VideoPicker.addVideo(at: url, to: store, in: hostWindow.window)
            }
        }
    }

    /// The first video's file; `nil` when there is none or it is missing.
    private var sourceURL: URL? { sourceURLs[UUID?.none] }

    /// The first video in the project whose file cannot be found.
    private var missingSource: (key: UUID?, video: SourceVideo)? {
        store.project.sourcesByKey.first { sourceURLs[$0.key] == nil }
    }

    /// The videos the timeline plays, with their files.
    private var usedVideos: [(key: UUID?, url: URL)] {
        store.project.usedSourceKeys.compactMap { key in sourceURLs[key].map { (key, $0) } }
    }

    /// Export (and Auto-Captions) need every video on disk and at least one segment.
    private var canExport: Bool {
        store.project.source != nil && missingSource == nil && !store.project.segments.isEmpty
    }

    /// A video file dropped on the window: it opens as the first video, or
    /// is added at the end; `nil` while a video is missing.
    private var dropVideo: (@MainActor @Sendable (URL) -> Void)? {
        if store.project.source == nil {
            return { [store, hostWindow] in
                VideoPicker.openVideo(at: $0, for: store, in: hostWindow.window)
            }
        }
        guard canAddVideo else { return nil }
        return { [store, hostWindow] in
            VideoPicker.addVideo(at: $0, to: store, in: hostWindow.window)
        }
    }

    /// Add Video needs the first video open and every video on disk.
    private var canAddVideo: Bool {
        store.project.source != nil && missingSource == nil
    }

    /// Freeze Frame needs every video on disk.
    private var canFreeze: Bool {
        store.project.source != nil && missingSource == nil
    }

    /// Some audio has been read and the timeline has a video clip.
    private var canRemoveSilences: Bool {
        !waveforms.isEmpty && store.project.segments.contains {
            if case .video = $0 { true } else { false }
        }
    }

    /// Every video is on disk and the timeline has a video clip.
    private var canRemoveFillers: Bool {
        store.project.source != nil && missingSource == nil && store.project.segments.contains {
            if case .video = $0 { true } else { false }
        }
    }

    // MARK: Preview card

    private var previewCard: some View {
        VStack(spacing: 0) {
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.stage)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.radius - 1,
                                              topTrailingRadius: Theme.radius - 1))
            .padding([.top, .horizontal], 1)
            TransportBar(controller: player)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .card()
    }

    @ViewBuilder private var stage: some View {
        if store.project.source != nil {
            if let missing = missingSource {
                StageMessage(systemImage: "questionmark.video", title: "Video Not Found",
                             detail: "TitleCut cannot open the video at "
                                + "\(missing.video.lastKnownPath). Locate it to keep editing.") {
                    Button("Locate Video…") {
                        VideoPicker.locateVideo(missing.key, for: store, in: hostWindow.window)
                    }
                    .buttonStyle(AccentShellButtonStyle())
                }
            } else {
                PlayerView(controller: player, onDelete: deleteSelection,
                           onAddTitle: addTitle, onClick: previewClicked,
                           onDrag: previewDragged, onMouseUp: previewMouseUp,
                           dragBox: titleDrag?.isMoving == true ? titleDrag?.box : nil,
                           renderSize: renderSize, editActions: editActions,
                           reframe: reframe)
            }
        } else {
            StageMessage(systemImage: "film", title: "No Video",
                         detail: "Open, drop or record a video to start editing.") {
                HStack(spacing: 10) {
                    Button("Open Video…") {
                        VideoPicker.chooseVideo(for: store, in: hostWindow.window)
                    }
                    .buttonStyle(AccentShellButtonStyle())
                    Button("Record Screen…") { recordScreen() }
                        .buttonStyle(BorderedShellButtonStyle())
                        .disabled(ScreenRecorder.shared.phase != .idle)
                }
            }
            // The whole stage takes the drop, not just the message.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first, let dropVideo else { return false }
                dropVideo(url)
                return true
            }
        }
    }

    // MARK: Titles

    private var renderSize: CGSize {
        let size = store.project.output.size
        if size.width > 0, size.height > 0 { return size }
        return store.project.source?.naturalSize ?? .zero
    }

    private func loadLibrary() {
        let library = StyleLibrary()
        libraryStyles = (try? library.styles()) ?? StyleLibrary.builtIns
        defaultStyleID = (try? library.defaultStyle())?.id ?? StyleLibrary.lowerThirdID
    }

    /// Adds a title at the playhead in the default style, selects it and
    /// shows it in the inspector.
    private func addTitle() {
        let style = libraryStyles.first { $0.id == defaultStyleID }
            ?? (try? StyleLibrary().defaultStyle()) ?? StyleLibrary.lowerThird
        let id = UUID()
        let added = store.perform(.addTitle(id: id, text: "Title",
                                            atOutputTime: Ticks.from(seconds: player.currentTime),
                                            style: style))
        if added {
            store.selectedTitleIDs = [id]
            store.selectedSegmentID = nil
        }
    }

    private var editActions: PreviewEditActions {
        PreviewEditActions(
            canCopy: { !store.selectedTitleIDs.isEmpty || selectedMusic != nil },
            copy: { selectedMusic != nil ? copyMusic() : copyTitles() },
            canPaste: { canPasteTitles() || canPasteMusic() },
            paste: { canPasteMusic() ? pasteMusic() : pasteTitles() },
            canDuplicate: {
                !store.selectedTitleIDs.isEmpty || selectedMusic != nil || canDuplicateSegment()
            },
            duplicate: {
                if selectedMusic != nil {
                    duplicateMusic()
                } else if !store.selectedTitleIDs.isEmpty {
                    duplicateTitles()
                } else {
                    duplicateSegment()
                }
            },
            canSelectAll: { !store.project.titles.isEmpty },
            selectAll: { selectTitles(store.project.titles.map(\.id)) })
    }

    /// Puts the selected titles on the general pasteboard, with their text as a string.
    private func copyTitles() {
        guard let clipboard = TitleClipboard(copying: store.selectedTitleIDs, from: store.project),
              let data = try? clipboard.encoded() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .titleCutTitles)
        pasteboard.setString(clipboard.plainText, forType: .string)
        clipboardRevision += 1
    }

    private func canPasteTitles() -> Bool {
        player.hasMedia
            && Ticks.from(seconds: player.currentTime) < TimelineMath.outputDuration(store.project)
            && NSPasteboard.general.availableType(from: [.titleCutTitles]) != nil
    }

    /// Pastes copied titles at the playhead and selects them.
    private func pasteTitles() {
        guard let data = NSPasteboard.general.data(forType: .titleCutTitles),
              let clipboard = try? TitleClipboard.decode(data) else { return }
        let ids = clipboard.entries.map { _ in UUID() }
        if store.perform(.pasteTitles(clipboard, atOutputTime: Ticks.from(seconds: player.currentTime),
                                      newIDs: ids)) {
            selectTitles(ids)
        }
    }

    /// Duplicates the selected titles, each starting where it ends, and selects the copies.
    private func duplicateTitles() {
        let ids = Dictionary(uniqueKeysWithValues: store.selectedTitleIDs.map { ($0, UUID()) })
        if store.perform(.duplicateTitles(newIDs: ids)) {
            selectTitles(Array(ids.values))
        }
    }

    /// A selected clip other than a gap.
    private func canDuplicateSegment() -> Bool {
        guard let id = store.selectedSegmentID,
              let segment = store.project.segments.first(where: { $0.id == id }) else { return false }
        return !segment.isGap
    }

    /// Puts a copy of the selected clip right after it, pushing later
    /// segments right, and selects the copy.
    private func duplicateSegment() {
        guard let id = store.selectedSegmentID else { return }
        let copy = UUID()
        if store.perform(.duplicateSegment(id: id, newID: copy)) {
            store.selectedSegmentID = copy
        }
    }

    private var selectedMusic: MusicClip? {
        store.selectedMusicID.flatMap { id in store.project.music.first { $0.id == id } }
    }

    /// Puts the selected music piece on the general pasteboard.
    private func copyMusic() {
        guard let clip = selectedMusic, let data = try? JSONEncoder().encode(clip) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .titleCutMusic)
        clipboardRevision += 1
    }

    /// A copied piece whose song is still in the music files.
    private var copiedMusic: MusicClip? {
        guard let data = NSPasteboard.general.data(forType: .titleCutMusic),
              let clip = try? JSONDecoder().decode(MusicClip.self, from: data),
              FileManager.default.fileExists(atPath: MusicFiles.url(for: clip.fileName).path)
        else { return nil }
        return clip
    }

    private func canPasteMusic() -> Bool {
        player.hasMedia
            && Ticks.from(seconds: player.currentTime) < TimelineMath.outputDuration(store.project)
            && copiedMusic != nil
    }

    /// Pastes the copied piece at the playhead, pushing later pieces right,
    /// and selects it.
    private func pasteMusic() {
        guard var clip = copiedMusic else { return }
        clip.id = UUID()
        clip.start = Ticks.from(seconds: player.currentTime)
        insertMusic(clip)
    }

    /// Duplicates the selected piece right after itself, pushing later
    /// pieces right, and selects the copy.
    private func duplicateMusic() {
        guard var clip = selectedMusic else { return }
        clip.id = UUID()
        clip.start = clip.end
        insertMusic(clip)
    }

    private func insertMusic(_ clip: MusicClip) {
        if store.perform(.insertMusic(clip)) { store.selectedMusicID = clip.id }
    }

    /// Selects those of `ids` that are in the project.
    private func selectTitles(_ ids: [UUID]) {
        store.selectedTitleIDs = Set(ids).intersection(store.project.titles.map(\.id))
        store.selectedSegmentID = nil
    }

    /// Delete key: the selected titles if any, otherwise the selected
    /// music piece, transition or segment.
    private func deleteSelection() {
        if !store.selectedTitleIDs.isEmpty {
            store.deleteSelectedTitles()
        } else if store.selectedMusicID != nil {
            store.deleteSelectedMusic()
        } else if store.selectedTransition != nil {
            store.deleteSelectedTransition()
        } else {
            store.deleteSelectedSegment()
        }
    }

    private func previewClicked(_ point: CGPoint?, additive: Bool) {
        titleDrag = nil
        let found = point.flatMap {
            PreviewHitTest.hit(at: $0, in: store.project,
                               outputTime: Ticks.from(seconds: player.currentTime),
                               renderSize: renderSize, renderer: titleRenderer)
        }
        guard let found else {
            if !additive { store.selectedTitleIDs = [] }
            return
        }
        let hit = found.id
        if let point, !additive {
            titleDrag = TitleDrag(id: hit, start: point, box: found.frame)
        }
        if additive {
            if store.selectedTitleIDs.contains(hit) {
                store.selectedTitleIDs.remove(hit)
            } else {
                store.selectedTitleIDs.insert(hit)
            }
        } else {
            store.selectedTitleIDs = [hit]
        }
        store.selectedSegmentID = nil
    }

    /// Moves the dragged title's box with the mouse and stores its centre as
    /// the title's custom position. The whole drag is one undo step.
    private func previewDragged(_ point: CGPoint) {
        guard var drag = titleDrag, renderSize.width > 0, renderSize.height > 0,
              let title = store.project.titles.first(where: { $0.id == drag.id }) else { return }
        let dx = point.x - drag.start.x, dy = point.y - drag.start.y
        if !drag.isMoving {
            // Ignore the small jitter of a plain click.
            guard hypot(dx, dy) >= renderSize.width * 0.004 else { return }
            drag.isMoving = true
            store.beginGesture(named: "Move Title on Screen")
        }
        let x = min(max((drag.startBox.midX + dx) / renderSize.width, 0), 1)
        let y = min(max((drag.startBox.midY + dy) / renderSize.height, 0), 1)
        drag.box = CGRect(x: x * renderSize.width - drag.startBox.width / 2,
                          y: y * renderSize.height - drag.startBox.height / 2,
                          width: drag.startBox.width, height: drag.startBox.height)
        titleDrag = drag
        var overrides = title.styleOverrides ?? StyleOverrides()
        overrides.position = .custom(x: x, y: y)
        store.perform(.setTitleStyleOverrides(id: drag.id, overrides: overrides))
    }

    /// Stores a transcript beside the project, in place of any earlier one
    /// of its video. Not an undoable edit: the document binding would
    /// otherwise register an undo step for it.
    private func saveTranscript(_ transcript: Transcript) {
        undoManager?.disableUndoRegistration()
        document.transcripts = document.transcripts.replacing(with: transcript)
        undoManager?.enableUndoRegistration()
    }

    // MARK: MCP

    /// Lets MCP tools reach this window's project, with the window state
    /// only this view holds.
    private func registerMCPSession() {
        let session = mcpSession ?? MCPSession(store: store, player: player)
        session.name = { documentName }
        session.isEdited = { isEdited || !hasFile }
        session.sourceURLs = { sourceURLs }
        session.transcripts = { document.transcripts }
        session.setTranscript = { saveTranscript($0) }
        session.renderSize = { renderSize }
        session.libraryStyles = { libraryStyles }
        session.defaultStyleID = { defaultStyleID }
        session.waveforms = { waveforms }
        session.renewProjectID = { [weak session] in
            store.renewID()
            // Saved like an edit (autosave), so the copy keeps its new ID.
            (session?.window?.windowController?.document as? NSDocument)?
                .updateChangeCount(.changeDone)
        }
        mcpSession = session
        MCPHost.shared.register(session)
    }

    // MARK: Freeze frame

    /// Grabs the frame at the playhead and inserts it as a 3 s still
    /// segment there, splitting the clip, and selects it.
    private func freezeFrame() {
        let outputTime = Ticks.from(seconds: player.currentTime)
        guard let (clip, sourceTime) = TimelineMath.sourcePoint(outputTime, in: store.project),
              let source = store.project.source(of: clip),
              let sourceURL = sourceURLs[clip.sourceID] else { return }
        // Freeze what the frame shows now, with the clip's framing or halves.
        let crops = StillFiles.visibleRects(sourceSize: source.naturalSize,
                                            renderSize: renderSize, clip: clip)
        let stacked = SplitScreen.isStacked(renderSize)
        Task {
            let still: StillImage
            do {
                still = try await StillFiles.grab(from: sourceURL, at: sourceTime, id: UUID(),
                                                  crops: crops,
                                                  stacked: stacked)
            } catch {
                actionFailure = ActionFailure(
                    what: "The frame at the playhead could not be frozen: "
                        + error.localizedDescription,
                    action: "Check that \(sourceURL.lastPathComponent) still opens, "
                        + "then try again.")
                return
            }
            let id = UUID()
            if store.perform(.insertStill(still, segmentID: id, splitID: UUID(),
                                          atOutputTime: outputTime,
                                          duration: Self.freezeDuration)) {
                store.selectedSegmentID = id
                store.selectedTitleIDs = []
            }
        }
    }

    private static let freezeDuration: Tick = 3 * Ticks.perSecond

    /// Inserts the picture at `url` as a 3 s still after the segment playing
    /// at output time `time`, or at the end for `nil`, and selects it.
    private func insertImage(from url: URL, at time: Tick?) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let image: StillImage
        do {
            image = try StillFiles.importImage(from: url, id: UUID())
        } catch {
            actionFailure = ActionFailure(
                what: "\(url.lastPathComponent) could not be added: " + error.localizedDescription,
                action: "Drop a JPEG, PNG or HEIC picture.")
            return
        }
        let id = UUID()
        let project = store.project
        let total = TimelineMath.outputDuration(project)
        // Never inside a segment: after the one dropped on, else at the end.
        var at = total
        if let time, let location = TimelineMath.locate(time, in: project) {
            at = time - location.offset + project.segments[location.index].duration
        }
        if store.perform(.insertImage(image, segmentID: id, splitID: UUID(), atOutputTime: at,
                                      duration: Self.freezeDuration)) {
            store.selectedSegmentID = id
            store.selectedTitleIDs = []
        }
    }

    /// Inserts a black title card at the playhead and selects it.
    private func insertCard() {
        let id = UUID()
        if store.perform(.insertCard(CardSegment(id: id, duration: Self.freezeDuration),
                                     splitID: UUID(),
                                     atOutputTime: Ticks.from(seconds: player.currentTime))) {
            store.selectedSegmentID = id
            store.selectedTitleIDs = []
        }
    }

    // MARK: Music

    /// Asks for a song, copies it into the project's music files and adds
    /// it at the playhead, selected.
    private func addMusic() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a song for the music strip"
        panel.present(in: hostWindow.window) { url in addMusic(from: url) }
    }

    /// Copies the song at `url` into the project's music files and adds it
    /// at the playhead, selected.
    private func addMusic(from url: URL) {
        let playhead = Ticks.from(seconds: player.currentTime)
        Task {
            let id = UUID()
            let imported: (fileName: String, duration: Tick)
            do {
                imported = try await MusicFiles.importSong(from: url, id: id)
            } catch {
                actionFailure = ActionFailure(
                    what: "\(url.lastPathComponent) could not be added: "
                        + error.localizedDescription,
                    action: "Choose an audio file such as MP3, M4A, WAV or AIFF.")
                return
            }
            guard let clip = MusicPlacement.newPiece(
                id: id, fileName: imported.fileName,
                name: url.deletingPathExtension().lastPathComponent,
                songDuration: imported.duration, at: playhead,
                among: store.project.music,
                videoDuration: TimelineMath.outputDuration(store.project))
            else {
                try? FileManager.default.removeItem(at: MusicFiles.url(for: imported.fileName))
                actionFailure = ActionFailure(
                    what: "There is no room on the music strip at the playhead.",
                    action: "Move the playhead to an empty part of the strip, "
                        + "then add the song again.")
                return
            }
            if store.perform(.addMusic(clip)) { store.selectedMusicID = clip.id }
        }
    }

    // MARK: Reframing

    /// Every video is on disk, and the frame crops the sides of a clip's video.
    private var canFrameFaces: Bool {
        guard missingSource == nil else { return false }
        return store.project.segments.contains { segment in
            guard case .video(let video) = segment,
                  let source = store.project.source(of: video) else { return false }
            return FaceFraming.framing(centering: 0.5, sourceSize: source.naturalSize,
                                       renderSize: renderSize) != nil
        }
    }

    /// Sets every clip's framing to centre its largest face, as one step.
    private func frameFaces() {
        guard faceTask == nil, missingSource == nil else { return }
        let project = store.project
        let urls = sourceURLs
        faceTask = Task {
            defer { faceTask = nil }
            do {
                let framings = try await FaceFraming.find(in: project, urls: urls)
                guard !framings.isEmpty else {
                    actionFailure = ActionFailure(
                        what: "No faces were found in the clips.",
                        action: "Reframe by hand: select a clip and drag the box in its "
                            + "framing map, or Command-drag the preview.")
                    return
                }
                store.perform(FaceFraming.commands(framings, in: store.project),
                              named: "Frame Faces")
            } catch is CancellationError {
                // The window closed; nothing to report.
            } catch {
                actionFailure = ActionFailure(
                    what: "A video could not be read: \(error.localizedDescription)",
                    action: "Check that the project's videos still open, then try again.")
            }
        }
    }

    /// What one framing of `clip` fills: the frame, or half of it for a
    /// split-screen clip.
    private func framedSize(of clip: VideoSegment) -> CGSize {
        clip.split == nil ? renderSize : SplitScreen.halfSize(of: renderSize)
    }

    /// The video clip under the playhead, when its video is found.
    private var reframeTarget: VideoSegment? {
        guard let location = TimelineMath.locate(Ticks.from(seconds: player.currentTime),
                                                 in: store.project),
              location.index < store.project.segments.count,
              case .video(let video) = store.project.segments[location.index],
              let source = store.project.source(of: video),
              source.naturalSize.width > 0, source.naturalSize.height > 0,
              framedSize(of: video).height > 0
        else { return nil }
        return video
    }

    private var reframe: PreviewReframe {
        PreviewReframe(
            isAvailable: { reframeTarget != nil },
            begin: { point in
                guard let video = reframeTarget, let source = store.project.source(of: video),
                      PreviewHitTest.hit(at: point, in: store.project,
                                         outputTime: Ticks.from(seconds: player.currentTime),
                                         renderSize: renderSize, renderer: titleRenderer) == nil
                else { return false }
                let half = video.split.map { _ in
                    SplitScreen.halves(of: renderSize)[1].contains(point) ? 1 : 0
                }
                let start = half.flatMap { video.split?[$0] } ?? video.frame
                // The picture overhangs the frame, or the half pressed, by
                // this many render pixels on each axis.
                let framed = framedSize(of: video)
                let size = source.naturalSize
                let scale = max(framed.width / size.width, framed.height / size.height)
                    * min(max(start.zoom, 1), ClipFraming.maximumZoom)
                reframeDrag = ReframeDrag(id: video.id, start: start,
                                          overhang: CGSize(width: size.width * scale - framed.width,
                                                           height: size.height * scale
                                                               - framed.height),
                                          split: video.split, half: half)
                store.beginGesture(named: "Reframe Clip")
                return true
            },
            change: { translation in
                guard let drag = reframeDrag else { return }
                // Dragging the picture right or down shows more of its left
                // or top; an axis it does not overhang stays put.
                var frame = drag.start
                if drag.overhang.width > 0.5 {
                    frame.x = drag.start.x - Double(translation.width / drag.overhang.width)
                }
                if drag.overhang.height > 0.5 {
                    frame.y = drag.start.y - Double(translation.height / drag.overhang.height)
                }
                if var split = drag.split, let half = drag.half {
                    split[half] = frame.clamped
                    store.perform(.setSegmentSplit(id: drag.id, split: split))
                } else {
                    store.perform(.setSegmentFrame(id: drag.id, frame: frame))
                }
            },
            end: {
                guard reframeDrag != nil else { return }
                reframeDrag = nil
                store.endGesture()
            })
    }

    private func previewMouseUp() {
        if titleDrag?.isMoving == true { store.endGesture() }
        titleDrag = nil
    }

    private func projectChanged(_ project: Project, firstLoad: Bool) {
        let sources = Dictionary(uniqueKeysWithValues: project.sourcesByKey.map {
            ($0.key, $0.video)
        })
        var urls = sourceURLs
        if sources != resolvedSources {
            // A video already resolved keeps its file.
            urls = [:]
            for (key, video) in sources {
                urls[key] = resolvedSources[key] == video ? sourceURLs[key] : video.resolveURL()
            }
            resolvedSources = sources
            sourceURLs = urls
        }
        // Nothing plays while a video is missing; the stage asks for it.
        let complete = sources.keys.allSatisfy { urls[$0] != nil }
        player.update(project: project, sourceURLs: complete ? urls : [:], debounce: !firstLoad)
    }
}

/// The frozen frame shown in the camera window.
private struct CameraTarget: Identifiable {
    let id: UUID
}

/// An Add Music or Freeze Frame failure: what went wrong and what to do.
private struct ActionFailure: Identifiable {
    let id = UUID()
    let what: String
    let action: String
}

/// A reframe drag: the clip, its framing at the press, and how far its
/// picture overhangs the frame on each axis, in render pixels. For a
/// split-screen clip, its halves at the press and the half being dragged.
private struct ReframeDrag {
    let id: UUID
    let start: ClipFraming
    let overhang: CGSize
    let split: SplitScreen?
    let half: Int?
}

/// A title drag in the preview, in render-size pixels with a top-left origin.
private struct TitleDrag {
    let id: UUID
    /// Where the mouse went down.
    let start: CGPoint
    /// The title's resting frame when the drag began.
    let startBox: CGRect
    /// The title's frame now.
    var box: CGRect
    /// Past the click threshold; the gesture is open.
    var isMoving = false

    init(id: UUID, start: CGPoint, box: CGRect) {
        self.id = id
        self.start = start
        self.startBox = box
        self.box = box
    }
}

/// Centred message on the dark preview stage.
private struct StageMessage<Actions: View>: View {
    let systemImage: String
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            actions
                .padding(.top, 4)
        }
        .padding(24)
    }
}

extension StageMessage where Actions == EmptyView {
    init(systemImage: String, title: String, detail: String) {
        self.init(systemImage: systemImage, title: title, detail: detail) { EmptyView() }
    }
}

/// Choosing the source video for a document that has none.
@MainActor
enum VideoPicker {
    /// Shows an open panel limited to movie files, as a sheet on `window`,
    /// and sets the choice as the project's source. Errors from a file the
    /// person chose are shown in an alert.
    static func chooseVideo(for store: ProjectStore, in window: NSWindow?) {
        guard store.project.source == nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a video"
        panel.prompt = "Open"
        panel.present(in: window) { url in openVideo(at: url, for: store, in: window) }
    }

    /// Sets the video at `url` as the project's source. Errors from a file
    /// the person chose or recorded are shown in an alert on `window`.
    static func openVideo(at url: URL, for store: ProjectStore, in window: NSWindow?) {
        Task {
            do {
                let source = try await SourceVideo.load(from: url)
                store.perform(.setSource(source, segmentID: UUID()))
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not open \(url.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                alert.present(in: window)
            }
        }
    }
}

extension VideoPicker {
    /// Add Video: asks for a video and adds it at the end of the timeline.
    static func addVideo(for store: ProjectStore, in window: NSWindow?) {
        guard store.project.source != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a video to add at the end"
        panel.prompt = "Add"
        panel.present(in: window) { url in addVideo(at: url, to: store, in: window) }
    }

    /// Adds the video at `url` at the end of the timeline and selects it.
    /// Errors from a file the person chose are shown in an alert on `window`.
    static func addVideo(at url: URL, to store: ProjectStore, in window: NSWindow?) {
        Task {
            do {
                let source = try await SourceVideo.load(from: url)
                let id = UUID()
                if store.perform(.addVideo(source, segmentID: id)) {
                    store.selectedSegmentID = id
                    store.selectedTitleIDs = []
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not add \(url.lastPathComponent)"
                alert.informativeText = error.localizedDescription
                alert.present(in: window)
            }
        }
    }

    /// Locate Video: points video `key` (`VideoSegment.sourceID`) at a file
    /// the person chooses, for a video that moved or that a sandboxed app
    /// may no longer open.
    static func locateVideo(_ key: UUID?, for store: ProjectStore, in window: NSWindow?) {
        guard let source = store.project.source(id: key) else { return }
        let name = URL(fileURLWithPath: source.lastKnownPath).lastPathComponent
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: source.lastKnownPath).deletingLastPathComponent()
        panel.message = "Locate \(name)"
        panel.prompt = "Locate"
        panel.present(in: window) { url in
            Task {
                let alert = NSAlert()
                do {
                    let found = try await SourceVideo.load(from: url)
                    if store.perform(.relinkSource(found, sourceID: key)) { return }
                    alert.messageText = "\(url.lastPathComponent) is shorter than the video "
                        + "this project uses"
                    alert.informativeText = "Choose the original video, \(name)."
                } catch {
                    alert.messageText = "Could not open \(url.lastPathComponent)"
                    alert.informativeText = error.localizedDescription
                }
                alert.present(in: window)
            }
        }
    }
}

/// A window held weakly, so view state does not keep it open.
@MainActor
final class WindowRef {
    weak var window: NSWindow?
}

extension NSSavePanel {
    /// Shows the panel as a sheet on `window`, so only that window waits for
    /// it; app-modal when there is no window. Calls `chosen` after OK.
    func present(in window: NSWindow?, chosen: @escaping @MainActor (URL) -> Void) {
        guard let window, window.isVisible else {
            if runModal() == .OK, let url { chosen(url) }
            return
        }
        beginSheetModal(for: window) { [self] response in
            if response == .OK, let url { chosen(url) }
        }
    }
}

extension NSAlert {
    /// Shows the alert as a sheet on `window`; app-modal when there is none.
    func present(in window: NSWindow?) {
        if let window, window.isVisible {
            beginSheetModal(for: window)
        } else {
            runModal()
        }
    }
}

extension NSPasteboard.PasteboardType {
    /// Copied titles as `TitleClipboard` JSON.
    static let titleCutTitles = Self(TitleClipboard.pasteboardType)
    static let titleCutMusic = Self(MusicClip.pasteboardType)
}

extension FocusedValues {
    /// The project store of the focused document window, for menu commands.
    @Entry var projectStore: ProjectStore?
    /// The player of the focused document window, for menu commands.
    @Entry var playerController: PlayerController?
    /// Opens the export sheet of the focused document window; `nil` when it
    /// cannot export.
    @Entry var showExport: (() -> Void)?
    /// Saves the focused window's auto-captions as .srt; `nil` when there are none.
    @Entry var exportSubtitles: (() -> Void)?
    /// Opens the Auto-Captions sheet of the focused document window; `nil`
    /// when there is no source on disk or nothing on the timeline.
    @Entry var showAutoCaptions: (() -> Void)?
    /// Opens the Remove Silences sheet; `nil` until the audio has been read.
    @Entry var showRemoveSilences: (() -> Void)?
    /// Opens the Remove Filler Words sheet; `nil` without a source on disk
    /// or a video clip.
    @Entry var showRemoveFillers: (() -> Void)?
    /// Inserts a title card at the playhead; `nil` on an empty timeline.
    @Entry var insertCard: (() -> Void)?
    /// Asks for a video and adds it at the end; `nil` without a first video
    /// or while one is missing.
    @Entry var addVideo: (() -> Void)?
    /// Starts a screen recording for the focused document window.
    @Entry var recordScreen: (() -> Void)?
    /// Frames the largest face in every clip; `nil` when the frame does not
    /// crop the sides, or while it runs.
    @Entry var frameFaces: (() -> Void)?
}
