import AppKit
import SwiftUI

/// While recording: a red outline around the recorded part of the screen and
/// a bar with the elapsed time and Stop. Both are TitleCut windows, so the
/// recording leaves them out.
@MainActor
final class RecordingIndicator {
    private let outline: NSWindow
    private let bar: NSPanel
    private static let line: CGFloat = 2

    /// `region` is in global screen points, origin bottom left.
    init(region: CGRect, on screen: NSScreen, stop: @escaping () -> Void) {
        let line = Self.line
        outline = NSWindow(contentRect: region.insetBy(dx: -line, dy: -line),
                           styleMask: .borderless, backing: .buffered, defer: false)
        outline.level = .screenSaver
        outline.isOpaque = false
        outline.backgroundColor = .clear
        outline.hasShadow = false
        outline.ignoresMouseEvents = true
        outline.isReleasedWhenClosed = false
        outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        outline.contentView = NSHostingView(rootView: Rectangle()
            .strokeBorder(Color.red, lineWidth: line))

        let content = NSHostingView(rootView: RecordingBar(started: .now, stop: stop))
        let size = content.fittingSize
        bar = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                      defer: false)
        bar.level = .screenSaver
        bar.isOpaque = false
        bar.backgroundColor = .clear
        bar.hasShadow = true
        bar.isReleasedWhenClosed = false
        bar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        bar.contentView = content
        // Under the region, else above it, else inside its bottom edge.
        let visible = screen.frame
        let gap: CGFloat = 10
        var y = region.minY - gap - size.height
        if y < visible.minY { y = region.maxY + gap }
        if y + size.height > visible.maxY { y = region.minY + gap }
        let x = min(max(region.midX - size.width / 2, visible.minX + 8),
                    visible.maxX - size.width - 8)
        bar.setFrameOrigin(CGPoint(x: x, y: y))

        outline.orderFrontRegardless()
        bar.orderFrontRegardless()
    }

    func close() {
        outline.orderOut(nil)
        bar.orderOut(nil)
    }
}

/// Elapsed time and Stop.
private struct RecordingBar: View {
    let started: Date
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 10, height: 10)
            SwiftUI.TimelineView(.periodic(from: started, by: 1)) { context in
                Text(Duration.seconds(max(context.date.timeIntervalSince(started), 0))
                    .formatted(.time(pattern: .minuteSecond)))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.text)
            }
            Button(action: stop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(AccentShellButtonStyle())
        }
        .padding(8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .environment(\.colorScheme, .light)
    }
}
