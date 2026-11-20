import SwiftUI
import TitleCutCore

/// White 52 pt bar: app name, document name, saved state, shape, Record,
/// Undo, Redo, Export, and, set apart, the MCP server button.
struct TopBar: View {
    let documentName: String
    /// "Edited", "Saved" or "Not saved".
    let saveState: String
    let canUndo: Bool
    let canRedo: Bool
    /// There is a source on disk and something on the timeline.
    let canExport: Bool
    let undo: () -> Void
    let redo: () -> Void
    let export: () -> Void
    /// Frame shapes to offer; empty before a video is open.
    let shapes: [OutputShape]
    /// The current shape, `nil` for a size none of `shapes` has.
    let shape: OutputShape?
    let setShape: (OutputShape) -> Void
    /// A screen recording is running; Record becomes Stop.
    let isRecording: Bool
    /// Starts or stops a screen recording; `nil` while one is being chosen
    /// or saved.
    let record: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Room for the window's traffic-light buttons.
            Color.clear.frame(width: 64)
            Text("TitleCut")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.text)
            Text(documentName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text(saveState)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Spacer(minLength: 12)
            if !shapes.isEmpty {
                Picker("Shape", selection: Binding(get: { shape },
                                                   set: { new in if let new { setShape(new) } })) {
                    ForEach(shapes, id: \.self) { Text($0.label).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Frame shape: the video fills it, cropped at the centre")
            }
            Button {
                record?()
            } label: {
                Label(isRecording ? "Stop" : "Record",
                      systemImage: isRecording ? "stop.fill" : "record.circle")
            }
            .buttonStyle(BorderedShellButtonStyle())
            .disabled(record == nil)
            .help(isRecording ? "Stop the screen recording and add it to the timeline"
                  : "Record part of the screen with its sound and the microphone "
                    + "(Shift-Command-R)")
            Button("Undo", action: undo)
                .buttonStyle(BorderedShellButtonStyle())
                .disabled(!canUndo)
            Button("Redo", action: redo)
                .buttonStyle(BorderedShellButtonStyle())
                .disabled(!canRedo)
            Button("Export", action: export)
                .buttonStyle(AccentShellButtonStyle())
                .disabled(!canExport)
                .help("Export MP4 or GIF (Command-E)")
            // Set apart from the editing controls.
            Rectangle().fill(Theme.border).frame(width: 1, height: 24).padding(.horizontal, 8)
            MCPButton()
        }
        .padding(.horizontal, Theme.margin)
        .frame(height: Theme.topBarHeight)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .gesture(WindowDragGesture())
    }
}
