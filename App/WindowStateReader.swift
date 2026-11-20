import AppKit
import SwiftUI

/// Reads the hosting window's title and its document's edited state, which
/// the document system owns, so the custom top bar can show them.
///
/// With autosave in place, `NSWindow.isDocumentEdited` stays false; the
/// document's own `isDocumentEdited` is the source. Neither posts KVO
/// reliably, so the view re-reads on every change (`revision`) and every
/// 2 s, which also catches autosaves.
struct WindowStateReader: NSViewRepresentable {
    @Binding var title: String
    @Binding var isEdited: Bool
    /// Whether the document has been saved to a file the person chose.
    @Binding var hasFile: Bool
    /// Changes whenever the document may have changed; triggers a re-read.
    let revision: Int
    /// Receives the hosting window when the view joins it.
    var onWindow: (NSWindow) -> Void = { _ in }

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        view.onChange = { title, edited, hasFile in
            if self.title != title { self.title = title }
            if self.isEdited != edited { self.isEdited = edited }
            if self.hasFile != hasFile { self.hasFile = hasFile }
        }
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        // NSDocument updates its change count after the edit is recorded.
        DispatchQueue.main.async { view.report() }
    }

    final class ReaderView: NSView {
        var onChange: ((String, Bool, Bool) -> Void)?
        var onWindow: ((NSWindow) -> Void)?
        private var timer: Timer?

        func report() {
            guard let window else { return }
            let document = window.windowController?.document as? NSDocument
            onChange?(window.title, document?.isDocumentEdited ?? window.isDocumentEdited,
                      document?.fileURL != nil)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            timer?.invalidate()
            timer = nil
            guard let window else { return }
            onWindow?(window)
            report()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }

        isolated deinit {
            timer?.invalidate()
        }
    }
}
