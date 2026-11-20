import SwiftUI

/// Transport row under the preview: frame back, round Play, frame forward,
/// timecode, and the progress scrubber.
struct TransportBar: View {
    let controller: PlayerController

    var body: some View {
        HStack(spacing: 12) {
            Button("Previous Frame", systemImage: "backward.frame.fill") {
                controller.step(frames: -1)
            }
            .help("Previous frame (Left Arrow)")
            .buttonStyle(IconButtonStyle())

            Button(controller.isPlaying ? "Pause" : "Play",
                   systemImage: controller.isPlaying ? "pause.fill" : "play.fill") {
                controller.togglePlayPause()
            }
            .help("Play or pause (Space)")
            .buttonStyle(PlayButtonStyle())

            Button("Next Frame", systemImage: "forward.frame.fill") {
                controller.step(frames: 1)
            }
            .help("Next frame (Right Arrow)")
            .buttonStyle(IconButtonStyle())

            Text("\(controller.currentTimecode) / \(controller.durationTimecode)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(Theme.text)
                .accessibilityIdentifier("timecode")
                .fixedSize()

            Scrubber(controller: controller)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 14)
        .frame(height: 56)
        .disabled(!controller.hasMedia)
    }
}

/// Thin progress track with accent fill and a white knob with an accent ring.
struct Scrubber: View {
    let controller: PlayerController

    @State private var isDragging = false
    @Environment(\.isEnabled) private var isEnabled

    private var fraction: Double {
        controller.duration > 0 ? min(max(controller.currentTime / controller.duration, 0), 1) : 0
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let x = width * fraction
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border).frame(height: 4)
                Capsule().fill(Theme.accent.opacity(isEnabled ? 1 : 0.4))
                    .frame(width: max(x, 0), height: 4)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                    .offset(x: min(max(x - 7, -7), width - 7))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        controller.beginScrub()
                    }
                    let f = min(max(value.location.x / max(width, 1), 0), 1)
                    controller.scrub(to: f * controller.duration)
                }
                .onEnded { _ in
                    isDragging = false
                    controller.endScrub()
                })
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel("Scrub")
        .accessibilityValue(controller.currentTimecode)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: controller.step(frames: 1)
            case .decrement: controller.step(frames: -1)
            @unknown default: break
            }
        }
    }
}

private struct PlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(Theme.onAccent)
            .frame(width: 36, height: 36)
            .background(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1)
                                                        : 0.4),
                        in: Circle())
            .contentShape(Circle())
    }
}

private struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isEnabled ? Theme.text : Theme.muted.opacity(0.5))
            .frame(width: 28, height: 28)
            .background(configuration.isPressed ? Theme.ground : .clear, in: Circle())
            .contentShape(Circle())
    }
}
