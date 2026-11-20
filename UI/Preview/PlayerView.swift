import AVFoundation
import AppKit
import SwiftUI

/// Actions reachable from the keyboard while the preview has focus.
enum TransportKey: Equatable {
    case playPause
    case stepFrames(Int)
    case jumpSeconds(Double)
    case deleteSelection
    case addTitle

    private static let space: UInt16 = 49
    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124
    private static let delete: UInt16 = 51
    private static let forwardDelete: UInt16 = 117
    private static let t: UInt16 = 17

    /// Maps a key event to an action (§7.2).
    /// Returns `nil` for anything else, including keys with Command, Option or Control.
    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isRepeat: Bool) {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        guard flags.isDisjoint(with: [.command, .option, .control]) else { return nil }
        let shift = flags.contains(.shift)
        switch keyCode {
        case Self.space where !shift:
            if isRepeat { return nil }
            self = .playPause
        case Self.leftArrow:
            self = shift ? .jumpSeconds(-1) : .stepFrames(-1)
        case Self.rightArrow:
            self = shift ? .jumpSeconds(1) : .stepFrames(1)
        case Self.delete where !shift, Self.forwardDelete where !shift:
            if isRepeat { return nil }
            self = .deleteSelection
        case Self.t where !shift:
            if isRepeat { return nil }
            self = .addTitle
        default:
            return nil
        }
    }
}

/// Copy, Paste, Duplicate and Select All for titles, with whether each applies.
struct PreviewEditActions {
    var canCopy: @MainActor () -> Bool
    var copy: @MainActor () -> Void
    var canPaste: @MainActor () -> Bool
    var paste: @MainActor () -> Void
    var canDuplicate: @MainActor () -> Bool
    var duplicate: @MainActor () -> Void
    var canSelectAll: @MainActor () -> Bool
    var selectAll: @MainActor () -> Void
}

/// Hosts an `AVPlayerLayer` and handles transport keys while first responder.
///
/// Shortcuts live here, not as menu key equivalents, so they never fire while
/// a text field elsewhere in the window is editing.
/// Command-drag on the picture to move the clip under the playhead inside
/// the output frame, where it overhangs that frame.
struct PreviewReframe {
    /// The clip under the playhead can be reframed. A closure, so the
    /// playhead is read only on demand.
    var isAvailable: @MainActor () -> Bool
    /// Command went down on the picture at this render point. Returns
    /// whether reframing started; `false` passes the press on as a click.
    var begin: @MainActor (_ renderPoint: CGPoint) -> Bool
    /// Travel since `begin`, in render pixels, positive right and down.
    var change: @MainActor (_ translation: CGSize) -> Void
    var end: @MainActor () -> Void
}

struct PlayerView: NSViewRepresentable {
    let controller: PlayerController
    /// Deletes the current selection (Delete key).
    let onDelete: @MainActor () -> Void
    /// Adds a title at the playhead (T).
    let onAddTitle: @MainActor () -> Void
    /// A click on the video: the point in render-size pixels (top-left
    /// origin), or `nil` outside the picture, and whether Command was held.
    let onClick: @MainActor (_ renderPoint: CGPoint?, _ additive: Bool) -> Void
    /// The mouse moved with the button down after a click: the point in
    /// render-size pixels, not limited to the picture.
    let onDrag: @MainActor (_ renderPoint: CGPoint) -> Void
    /// The button went up after a click.
    let onMouseUp: @MainActor () -> Void
    /// Outline drawn over the picture while a title is dragged, in
    /// render-size pixels with a top-left origin.
    let dragBox: CGRect?
    /// The composition's render size, to map clicks into it.
    let renderSize: CGSize
    /// Edit > Copy, Paste, Duplicate and Select All while the preview is first responder.
    let editActions: PreviewEditActions
    let reframe: PreviewReframe

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = controller.player
        configure(view)
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== controller.player {
            view.playerLayer.player = controller.player
        }
        configure(view)
    }

    private func configure(_ view: PlayerLayerView) {
        view.renderSize = renderSize
        view.onKey = { [controller, onDelete, onAddTitle] key in
            switch key {
            case .deleteSelection: onDelete()
            case .addTitle: onAddTitle()
            case .playPause: controller.togglePlayPause()
            case .stepFrames(let count): controller.step(frames: count)
            case .jumpSeconds(let delta): controller.jump(by: delta)
            }
        }
        view.onClick = onClick
        view.onDrag = onDrag
        view.onMouseUp = onMouseUp
        view.dragBox = dragBox
        view.editActions = editActions
        view.reframe = reframe
    }
}

final class PlayerLayerView: NSView {
    var onKey: ((TransportKey) -> Void)?
    var onClick: ((CGPoint?, Bool) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onMouseUp: (() -> Void)?
    var editActions: PreviewEditActions?
    var reframe: PreviewReframe? {
        didSet { updateReframeHint() }
    }
    /// Where a reframe drag started, in view coordinates.
    private var reframeStart: CGPoint?
    /// The pointer over the view, for showing the hint on Command.
    private var hoverPoint: CGPoint?
    private var flagsMonitor: Any?
    private var cursorPushed: NSCursor?
    /// Centre handle shown while Command is held over a reframable picture.
    private let reframeHint = CALayer()
    var renderSize: CGSize = .zero {
        didSet { if renderSize != oldValue { layoutDragBox() } }
    }
    var dragBox: CGRect? {
        didSet { if dragBox != oldValue { layoutDragBox() } }
    }
    private let dragBoxLayer = CAShapeLayer()

    /// Gives keyboard focus back to the preview in `window`, ending any text
    /// editing, so transport shortcuts work after clicking elsewhere.
    static func focusPreview(in window: NSWindow?) {
        guard let window, let content = window.contentView,
              let preview = find(in: content) else { return }
        window.makeFirstResponder(preview)
    }

    private static func find(in view: NSView) -> PlayerLayerView? {
        if let match = view as? PlayerLayerView { return match }
        for subview in view.subviews {
            if let match = find(in: subview) { return match }
        }
        return nil
    }

    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer = playerLayer
        dragBoxLayer.fillColor = nil
        dragBoxLayer.strokeColor = NSColor.white.cgColor
        dragBoxLayer.lineWidth = 1.5
        dragBoxLayer.lineDashPattern = [5, 4]
        dragBoxLayer.shadowColor = NSColor.black.cgColor
        dragBoxLayer.shadowOpacity = 0.6
        dragBoxLayer.shadowRadius = 1
        dragBoxLayer.shadowOffset = .zero
        playerLayer.addSublayer(dragBoxLayer)
        reframeHint.contents = Self.hintImage
        reframeHint.contentsGravity = .resizeAspect
        reframeHint.isHidden = true
        reframeHint.shadowColor = NSColor.black.cgColor
        reframeHint.shadowOpacity = 0.5
        reframeHint.shadowRadius = 3
        reframeHint.shadowOffset = .zero
        playerLayer.addSublayer(reframeHint)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow,
                                   .inVisibleRect],
            owner: self))
    }

    private static let hintImage: CGImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 48, weight: .semibold)
            .applying(.init(paletteColors: [.black, .white]))
        guard let image = NSImage(systemSymbolName: "arrow.left.and.right.circle.fill",
                                  accessibilityDescription: "Reframe")?
            .withSymbolConfiguration(config) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }()

    /// Shows the centre handle and hand cursor while Command is held over
    /// the picture of a reframable clip, or during a reframe drag.
    private func updateReframeHint() {
        let video = playerLayer.videoRect
        let over = hoverPoint.map { video.contains($0) } ?? false
        let shown = reframeStart != nil
            || (over && reframe?.isAvailable() == true
                && NSEvent.modifierFlags.contains(.command))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        reframeHint.isHidden = !shown
        if shown {
            let side: CGFloat = 56
            reframeHint.frame = CGRect(x: video.midX - side / 2, y: video.midY - side / 2,
                                       width: side, height: side)
        }
        CATransaction.commit()
        let cursor: NSCursor? = reframeStart != nil ? .closedHand : (shown ? .openHand : nil)
        guard cursor !== cursorPushed else { return }
        if cursorPushed != nil { NSCursor.pop() }
        cursorPushed = cursor
        cursor?.push()
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        updateReframeHint()
    }

    override func mouseEntered(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        updateReframeHint()
    }

    override func mouseExited(with event: NSEvent) {
        hoverPoint = nil
        updateReframeHint()
    }

    override func layout() {
        super.layout()
        layoutDragBox()
    }

    /// Places the drag outline over the picture, in layer coordinates.
    private func layoutDragBox() {
        let video = playerLayer.videoRect
        guard let box = dragBox, renderSize.width > 0, renderSize.height > 0,
              video.width > 0, video.height > 0 else {
            dragBoxLayer.path = nil
            return
        }
        let sx = video.width / renderSize.width, sy = video.height / renderSize.height
        let y = isFlipped ? video.minY + box.minY * sy : video.maxY - box.maxY * sy
        let rect = CGRect(x: video.minX + box.minX * sx, y: y,
                          width: box.width * sx, height: box.height * sy)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dragBoxLayer.frame = playerLayer.bounds
        dragBoxLayer.path = CGPath(rect: rect.insetBy(dx: -4, dy: -4), transform: nil)
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        if window != nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) {
                [weak self] event in
                MainActor.assumeIsolated {
                    if event.window === self?.window { self?.updateReframeHint() }
                }
                return event
            }
        } else if cursorPushed != nil {
            NSCursor.pop()
            cursorPushed = nil
        }
        // Take focus when shown, unless something else (e.g. a text field) has it.
        guard let window else { return }
        if window.firstResponder === window || window.firstResponder == nil {
            window.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let render = renderPoint(for: point)
        if event.modifierFlags.contains(.command), let render, let reframe,
           reframe.isAvailable(), reframe.begin(render) {
            reframeStart = point
            updateReframeHint()
            return
        }
        onClick?(render, event.modifierFlags.contains(.command))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let start = reframeStart {
            let video = playerLayer.videoRect
            guard video.width > 0, video.height > 0 else { return }
            let dy = isFlipped ? point.y - start.y : start.y - point.y
            reframe?.change(CGSize(width: (point.x - start.x) / video.width * renderSize.width,
                                   height: dy / video.height * renderSize.height))
            return
        }
        if let render = renderPoint(for: point, insideOnly: false) { onDrag?(render) }
    }

    override func mouseUp(with event: NSEvent) {
        if reframeStart != nil {
            reframeStart = nil
            reframe?.end()
            hoverPoint = convert(event.locationInWindow, from: nil)
            updateReframeHint()
            return
        }
        onMouseUp?()
    }

    /// Maps a point in this view to render-size pixels with a top-left origin.
    /// With `insideOnly`, points outside the picture give `nil`.
    private func renderPoint(for point: CGPoint, insideOnly: Bool = true) -> CGPoint? {
        let video = playerLayer.videoRect
        guard renderSize.width > 0, renderSize.height > 0, video.width > 0, video.height > 0,
              !insideOnly || video.contains(point) else { return nil }
        let x = (point.x - video.minX) / video.width * renderSize.width
        // Layer coordinates are bottom-left origin unless the view is flipped.
        let fromTop = isFlipped ? point.y - video.minY : video.maxY - point.y
        return CGPoint(x: x, y: fromTop / video.height * renderSize.height)
    }

    // Edit menu actions arrive through the responder chain, so they reach the
    // preview only when it, not a text field, is first responder.

    @objc func copy(_ sender: Any?) { editActions?.copy() }
    @objc func paste(_ sender: Any?) { editActions?.paste() }
    /// Edit > Duplicate.
    @objc func duplicateTitles(_ sender: Any?) { editActions?.duplicate() }
    /// Edit > Select All: every title.
    override func selectAll(_ sender: Any?) { editActions?.selectAll() }

    override func keyDown(with event: NSEvent) {
        if let key = TransportKey(keyCode: event.keyCode,
                                  modifiers: event.modifierFlags,
                                  isRepeat: event.isARepeat) {
            onKey?(key)
        } else {
            super.keyDown(with: event)
        }
    }
}

extension PlayerLayerView: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let editActions else { return false }
        switch menuItem.action {
        case #selector(copy(_:)): return editActions.canCopy()
        case #selector(paste(_:)): return editActions.canPaste()
        case #selector(duplicateTitles(_:)): return editActions.canDuplicate()
        case #selector(selectAll(_:)): return editActions.canSelectAll()
        default: return true
        }
    }
}
