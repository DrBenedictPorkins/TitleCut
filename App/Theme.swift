import SwiftUI

/// Design option B, "Daylight". Light only.
enum Theme {
    static let ground = Color(hex: 0xEEF0F3)
    static let text = Color(hex: 0x1C2027)
    static let muted = Color(hex: 0x5B6370)
    static let border = Color(hex: 0xD9DDE3)
    static let accent = Color(hex: 0xC2410C)
    static let onAccent = Color.white
    static let selectedTint = Color(hex: 0xFDEBE1)
    static let selectedText = Color(hex: 0x9A3412)
    static let titleBlockBorder = Color(hex: 0xF6C7AE)
    static let card = Color.white
    /// Preview stage behind the video.
    static let stage = Color(hex: 0x1C2027)
    /// Video segment blocks on the timeline.
    static let segment = Color(hex: 0x3A414D)
    /// Video clips on the timeline, one colour per video in
    /// `Project.sourcesByKey` order; the first video's is `segment`.
    /// Repeats after the last.
    static let videoClips: [Color] = [segment, Color(hex: 0x2F5B87), Color(hex: 0x7A5230),
                                      Color(hex: 0x8A3B5C), Color(hex: 0x5E6B2E)]

    static func videoClip(_ index: Int) -> Color { videoClips[index % videoClips.count] }
    /// Music pieces on the timeline.
    static let music = Color(hex: 0x2F7D6B)
    /// Frozen-frame (still) segments on the timeline.
    static let freeze = Color(hex: 0x5A4E8C)

    static let radius: CGFloat = 12
    static let gap: CGFloat = 12
    static let margin: CGFloat = 12
    static let topBarHeight: CGFloat = 52
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension View {
    /// White card: 12 pt corners, 1 px border.
    func card() -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// Bordered white button used in the top bar and timeline toolbar.
struct BorderedShellButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isEnabled ? Theme.text : Theme.muted.opacity(0.5))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(configuration.isPressed ? Theme.ground : Theme.card,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            .contentShape(Rectangle())
    }
}

/// Accent-filled button with white text.
struct AccentShellButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
    }
}
