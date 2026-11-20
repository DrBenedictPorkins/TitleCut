import SwiftUI
import TitleCutCore

@main
struct TitleCutApp: App {
    init() {
        // Launch opens a new untitled project instead of the Open panel.
        // AppKit reads this from user defaults, not Info.plist.
        // Closing or quitting with unsaved changes asks whether to keep them,
        // instead of autosaving silently ("Ask to keep changes when closing
        // documents" in System Settings, for this app only).
        UserDefaults.standard.register(defaults: [
            "NSShowAppCentricOpenPanelInsteadOfUntitledFile": false,
            "NSCloseAlwaysConfirmsChanges": true,
        ])
        MainActor.assumeIsolated {
            MCPFolders.shared.restore()
            MCPService.shared.restore()
            Unlock.shared.start()
        }
    }

    var body: some Scene {
        DocumentGroup(newDocument: TitleCutDocument()) { file in
            ContentView(document: file.$document)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutMenuButton()
            }
            EditCommands()
        }

        Window("About \(BuildInfo.current.displayName)", id: AboutView.windowID) {
            AboutView(info: .current)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
    }
}

/// Replaces the standard "About" menu item and opens the custom About window.
private struct AboutMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About \(BuildInfo.current.displayName)") {
            openWindow(id: AboutView.windowID)
        }
    }
}

/// File > Open Video…, Add Video…, Record Screen…, Export… and Export Subtitles…, Edit > Duplicate,
/// View > Zoom and the Timeline menu, routed to the focused document window.
private struct EditCommands: Commands {
    @FocusedValue(\.projectStore) private var store
    @FocusedValue(\.playerController) private var player
    @FocusedValue(\.showExport) private var showExport
    @FocusedValue(\.exportSubtitles) private var exportSubtitles
    @FocusedValue(\.showAutoCaptions) private var showAutoCaptions
    @FocusedValue(\.showRemoveSilences) private var showRemoveSilences
    @FocusedValue(\.showRemoveFillers) private var showRemoveFillers
    @FocusedValue(\.insertCard) private var insertCard
    @FocusedValue(\.addVideo) private var addVideo
    @FocusedValue(\.recordScreen) private var recordScreen
    private var recorder = ScreenRecorder.shared
    @FocusedValue(\.frameFaces) private var frameFaces
    @FocusedValue(\.timelineZoom) private var zoom

    /// Titles, a music piece, or a clip other than a gap is selected.
    private var canDuplicate: Bool {
        guard let store else { return false }
        if !store.selectedTitleIDs.isEmpty || store.selectedMusicID != nil { return true }
        guard let id = store.selectedSegmentID,
              let segment = store.project.segments.first(where: { $0.id == id }) else { return false }
        return !segment.isGap
    }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Video…") {
                if let store { VideoPicker.chooseVideo(for: store, in: NSApp.mainWindow) }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(store == nil || store?.project.source != nil)
            Button("Add Video…") { addVideo?() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(addVideo == nil)
            if recorder.isRecording {
                Button("Stop Recording") { recorder.stop() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            } else {
                Button("Record Screen…") { recordScreen?() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(recordScreen == nil || recorder.phase != .idle)
            }
        }

        CommandGroup(after: .importExport) {
            Button("Export…") { showExport?() }
                .keyboardShortcut("e")
                .disabled(showExport == nil)
            Button("Export Subtitles…") { exportSubtitles?() }
                .disabled(exportSubtitles == nil)
        }

        CommandGroup(after: .pasteboard) {
            // Sent up the responder chain: the preview handles it when it is
            // first responder, so it never acts while a text field is editing.
            Button("Duplicate") {
                NSApp.sendAction(#selector(PlayerLayerView.duplicateTitles(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("d")
            .disabled(!canDuplicate)
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { zoom?.zoomIn() }
                .keyboardShortcut("+")
                .disabled(!(zoom?.canZoomIn ?? false))
            Button("Zoom Out") { zoom?.zoomOut() }
                .keyboardShortcut("-")
                .disabled(!(zoom?.canZoomOut ?? false))
            Button("Zoom to Fit") { zoom?.zoomToFit() }
                .keyboardShortcut("0")
                .disabled(!(zoom?.canZoomOut ?? false))
        }

        CommandMenu("Timeline") {
            Button("Split at Playhead") {
                guard let store, let player else { return }
                store.perform(.splitSegment(atOutputTime: Ticks.from(seconds: player.currentTime),
                                            newSegmentID: UUID()))
            }
            .keyboardShortcut("k")
            .disabled(store?.project.segments.isEmpty ?? true)

            // No key equivalents for Delete or T: the focused preview handles
            // them so they never fire while a text field is editing.
            Button("Delete") {
                guard let store else { return }
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
            .disabled(store.map { $0.selectedTitleIDs.isEmpty && $0.selectedSegmentID == nil
                                  && $0.selectedMusicID == nil && $0.selectedTransition == nil }
                      ?? true)

            Divider()
            Button("Insert Title Card") { insertCard?() }
                .disabled(insertCard == nil)
            Button("Frame Faces") { frameFaces?() }
                .disabled(frameFaces == nil)
            Button("Auto-Captions…") { showAutoCaptions?() }
                .disabled(showAutoCaptions == nil)
            Button("Remove Silences…") { showRemoveSilences?() }
                .disabled(showRemoveSilences == nil)
            Button("Remove Filler Words…") { showRemoveFillers?() }
                .disabled(showRemoveFillers == nil)
            Button("Select All Captions") {
                guard let store else { return }
                store.selectedTitleIDs = AutoCaptions.titleIDs(in: store.project)
                store.selectedSegmentID = nil
            }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(store.map { AutoCaptions.titleIDs(in: $0.project).isEmpty } ?? true)
        }
    }
}
