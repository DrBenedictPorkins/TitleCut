import CoreGraphics
import Foundation

/// How a title looks at one instant of its life (§6.3 step 2).
public struct TitleAppearance: Equatable, Sendable {
    /// 0...1.
    public var opacity: Double
    /// Displacement as fractions of the render size, x right and y down.
    /// A full slide is 1 along its axis, which puts any on-screen title
    /// entirely off-screen.
    public var offset: CGVector
    /// Uniform scale about the title's centre. 1 = as laid out.
    public var scale: Double
    /// Characters (grapheme clusters) drawn, counted from the start of the text.
    public var visibleCharacters: Int
    /// Index into `Title.words` of the word being spoken, if any
    /// (`WordHighlight.index`). Drawn only when the style has a highlight.
    public var highlightedWord: Int?

    public init(opacity: Double = 1, offset: CGVector = .zero, scale: Double = 1,
                visibleCharacters: Int, highlightedWord: Int? = nil) {
        self.opacity = opacity
        self.offset = offset
        self.scale = scale
        self.visibleCharacters = visibleCharacters
        self.highlightedWord = highlightedWord
    }
}

/// Evaluates a title's in and out transitions at an output time.
public enum TransitionEvaluator {
    /// The appearance of `title` at `outputTime`, or `nil` when the title is
    /// not on screen then.
    ///
    /// - Parameter outputRange: The title's output range, as clamped by
    ///   `TimelineMath.titleOutputRange`. The out transition ends at its end.
    public static func appearance(of title: Title, outputRange: TickRange,
                                  at outputTime: Tick) -> TitleAppearance? {
        appearance(of: title, outputRange: outputRange, at: Double(outputTime))
    }

    /// As above, with a fractional output time in ticks.
    public static func appearance(of title: Title, outputRange: TickRange,
                                  at outputTime: Double) -> TitleAppearance? {
        let start = Double(outputRange.start)
        let length = Double(outputRange.duration)
        guard length > 0, outputTime >= start, outputTime < start + length else { return nil }
        let elapsed = outputTime - start
        let characterCount = title.text.count
        let (inLength, outLength) = transitionLengths(in: title.transitionIn,
                                                      out: title.transitionOut,
                                                      titleLength: length)

        var result = TitleAppearance(
            visibleCharacters: characterCount,
            highlightedWord: title.words.flatMap { WordHighlight.index(at: elapsed, in: $0) })
        if inLength > 0 {
            let progress = title.transitionIn.easing.value(at: elapsed / inLength)
            apply(title.transitionIn.kind, shown: progress, characterCount: characterCount,
                  to: &result)
        }
        if outLength > 0 {
            let outStart = length - outLength
            if elapsed >= outStart {
                let progress = title.transitionOut.easing.value(
                    at: (elapsed - outStart) / outLength)
                apply(title.transitionOut.kind, shown: 1 - progress,
                      characterCount: characterCount, to: &result)
            }
        }
        return result
    }

    /// Lengths in ticks of the in and out transitions for a title of
    /// `titleLength` ticks. A `.none` transition has no length. When the two
    /// together exceed the title, both shrink in proportion so they meet
    /// without overlapping (§11.1).
    public static func transitionLengths(in transitionIn: Transition, out transitionOut: Transition,
                                         titleLength: Double) -> (in: Double, out: Double) {
        let inLength = transitionIn.kind == .none ? 0 : Double(max(transitionIn.duration, 0))
        let outLength = transitionOut.kind == .none ? 0 : Double(max(transitionOut.duration, 0))
        let total = inLength + outLength
        guard total > titleLength, total > 0 else { return (inLength, outLength) }
        let factor = max(titleLength, 0) / total
        return (inLength * factor, outLength * factor)
    }

    /// Folds one transition into `appearance`. `shown` is 0 when the title is
    /// fully hidden by the transition and 1 when it is fully shown.
    private static func apply(_ kind: TransitionKind, shown: Double, characterCount: Int,
                              to appearance: inout TitleAppearance) {
        switch kind {
        case .none:
            break
        case .fade:
            appearance.opacity *= shown
        case .slide(let edge):
            let distance = 1 - shown
            switch edge {
            case .top: appearance.offset.dy -= distance
            case .bottom: appearance.offset.dy += distance
            case .leading: appearance.offset.dx -= distance
            case .trailing: appearance.offset.dx += distance
            }
        case .scale:
            appearance.scale *= shown
        case .typewriter:
            let visible = Int((Double(characterCount) * shown + 1e-9).rounded(.down))
            appearance.visibleCharacters = min(appearance.visibleCharacters,
                                               min(max(visible, 0), characterCount))
        }
    }
}
