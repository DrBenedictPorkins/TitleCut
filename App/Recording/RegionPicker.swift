import AppKit
import SwiftUI
import TitleCutCore

/// Covers every screen with a dimmed layer on which the person drags out the
/// part to record. The box can then be moved, resized from its edges and
/// corners, or drawn again. Record (or Return) chooses it; Cancel (or
/// Escape) closes the picker.
@MainActor
final class RegionPicker {
    private var windows: [NSWindow] = []
    private let choose: (CGRect, NSScreen) -> Void
    private let cancel: () -> Void

    /// `choose` gets the box in its screen's own points, origin bottom left.
    init(choose: @escaping (CGRect, NSScreen) -> Void, cancel: @escaping () -> Void) {
        self.choose = choose
        self.cancel = cancel
    }

    func show() {
        NSApp.activate()
        for screen in NSScreen.screens {
            let window = PickerWindow(contentRect: screen.frame, styleMask: .borderless,
                                      backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.setFrame(screen.frame, display: false)
            let view = RegionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.choose = { [weak self] region in self?.choose(region, screen) }
            view.cancel = { [weak self] in self?.cancel() }
            view.began = { [weak self, weak view] in
                // One box at a time, on the screen last drawn on.
                for other in self?.windows ?? [] {
                    if let region = other.contentView as? RegionView, region !== view {
                        region.clear()
                    }
                }
            }
            window.contentView = view
            windows.append(window)
            window.orderFrontRegardless()
        }
        let under = NSScreen.screens.firstIndex { $0.frame.contains(NSEvent.mouseLocation) } ?? 0
        if windows.indices.contains(under) { windows[under].makeKey() }
    }

    func close() {
        for window in windows { window.orderOut(nil) }
        windows = []
    }
}

/// A borderless window that takes the keyboard, for Return and Escape.
private final class PickerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// The dimmed layer, the box, its handles and the Record and Cancel buttons.
private final class RegionView: NSView {
    var choose: ((CGRect) -> Void)?
    var cancel: (() -> Void)?
    /// A new box was started on this screen.
    var began: (() -> Void)?

    private var region: CGRect?
    /// What the current drag does.
    private enum Drag {
        case draw(from: CGPoint)
        case move(start: CGRect, from: CGPoint)
        /// Moves the edges named: -1 the low edge, 1 the high edge, 0 neither.
        case resize(start: CGRect, from: CGPoint, x: Int, y: Int)
    }
    private var drag: Drag?
    private let controls = NSHostingView(rootView: PickerControls(size: .zero, record: {},
                                                                  cancel: {}))
    private static let handle: CGFloat = 8
    private static let minimum: CGFloat = 16

    override init(frame: NSRect) {
        super.init(frame: frame)
        controls.isHidden = true
        addSubview(controls)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways,
                                                 .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func clear() {
        region = nil
        updateControls()
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let region { dim.append(NSBezierPath(rect: region).reversed) }
        NSColor.black.withAlphaComponent(0.4).setFill()
        dim.fill()
        guard let region else {
            drawHint()
            return
        }
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: region.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
        NSColor.white.setFill()
        for point in handlePoints(of: region) {
            let side = Self.handle
            NSBezierPath(rect: CGRect(x: point.x - side / 2, y: point.y - side / 2,
                                      width: side, height: side)).fill()
        }
    }

    private func drawHint() {
        let text = "Drag to choose the part of the screen to record. Press Escape to cancel."
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let box = CGRect(x: bounds.midX - size.width / 2 - 14, y: bounds.midY - size.height / 2 - 8,
                         width: size.width + 28, height: size.height + 16)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        text.draw(at: CGPoint(x: box.minX + 14, y: box.minY + 8), withAttributes: attributes)
    }

    /// Corners and edge midpoints.
    private func handlePoints(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.midY),
         CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.minX, y: rect.maxY),
         CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)]
    }

    // MARK: Mouse

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        // A box under twice the handle's size has no middle; its inset is
        // the null rect, which AppKit throws on.
        if let inside = region?.insetBy(dx: Self.handle, dy: Self.handle),
           !inside.isNull, !inside.isEmpty {
            addCursorRect(inside, cursor: .openHand)
        }
    }

    /// Cursor rects only apply in the key window, so the screen the mouse
    /// moves onto takes the key.
    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        let point = convert(event.locationInWindow, from: nil)
        if let region {
            let reach = Self.handle
            let x = abs(point.x - region.minX) <= reach ? -1
                : abs(point.x - region.maxX) <= reach ? 1 : 0
            let y = abs(point.y - region.minY) <= reach ? -1
                : abs(point.y - region.maxY) <= reach ? 1 : 0
            let near = region.insetBy(dx: -reach, dy: -reach).contains(point)
            if near, x != 0 || y != 0 {
                drag = .resize(start: region, from: point, x: x, y: y)
                return
            }
            if region.contains(point) {
                drag = .move(start: region, from: point)
                return
            }
        }
        began?()
        drag = .draw(from: point)
        region = nil
        updateControls()
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        switch drag {
        case .draw(let from):
            region = CGRect(x: min(from.x, point.x), y: min(from.y, point.y),
                            width: abs(point.x - from.x), height: abs(point.y - from.y))
        case .move(let start, let from):
            var moved = start.offsetBy(dx: point.x - from.x, dy: point.y - from.y)
            moved.origin.x = min(max(moved.minX, 0), bounds.width - moved.width)
            moved.origin.y = min(max(moved.minY, 0), bounds.height - moved.height)
            region = moved
        case .resize(let start, let from, let x, let y):
            var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
            let dx = point.x - from.x, dy = point.y - from.y
            if x < 0 { minX = min(start.minX + dx, maxX - Self.minimum) }
            if x > 0 { maxX = max(start.maxX + dx, minX + Self.minimum) }
            if y < 0 { minY = min(start.minY + dy, maxY - Self.minimum) }
            if y > 0 { maxY = max(start.maxY + dy, minY + Self.minimum) }
            region = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                .intersection(bounds)
        case nil: return
        }
        updateControls()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .draw = drag, let region,
           region.width < Self.minimum || region.height < Self.minimum {
            self.region = nil
        }
        drag = nil
        updateControls()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: cancel?()
        case 36, 76: if let region { choose?(region) }
        default: super.keyDown(with: event)
        }
    }

    // MARK: Controls

    /// Puts Record and Cancel under the box, above it when there is no room,
    /// or inside its bottom edge on a box that fills the screen.
    private func updateControls() {
        guard let region, drag == nil || region.width >= Self.minimum else {
            controls.isHidden = true
            return
        }
        let pixels = ScreenRegion.pixelSize(region.size, scale: window?.backingScaleFactor ?? 2)
        controls.rootView = PickerControls(
            size: pixels,
            record: { [weak self] in
                guard let self, let region = self.region else { return }
                self.choose?(region)
            },
            cancel: { [weak self] in self?.cancel?() })
        let size = controls.fittingSize
        let gap: CGFloat = 10
        var y = region.minY - gap - size.height
        if y < 0 { y = region.maxY + gap }
        if y + size.height > bounds.height { y = region.minY + gap }
        let x = min(max(region.midX - size.width / 2, 8), bounds.width - size.width - 8)
        controls.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
        controls.isHidden = false
    }
}

/// The box's size in pixels, Cancel and Record.
private struct PickerControls: View {
    let size: CGSize
    let record: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(Int(size.width)) \u{00D7} \(Int(size.height))")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.muted)
            Button("Cancel", action: cancel)
                .buttonStyle(BorderedShellButtonStyle())
            Button(action: record) {
                Label("Record", systemImage: "record.circle")
            }
            .buttonStyle(AccentShellButtonStyle())
        }
        .padding(8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .environment(\.colorScheme, .light)
    }
}
