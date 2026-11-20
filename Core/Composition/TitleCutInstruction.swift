import AVFoundation

/// One instruction per segment, covering that segment's output range (§6.1).
/// A segment with a clip transition at either end gets one more for each
/// side of a cut it plays on (`ClipTransitionPlan`).
///
/// Immutable; carries a snapshot of everything the compositor needs to draw
/// the segment, so rendering never reads the live model.
public final class TitleCutInstruction: NSObject, AVVideoCompositionInstructionProtocol,
                                        Sendable {
    /// What the segment draws.
    public enum Content: Sendable, Equatable {
        /// A range of the source video track; `frame` and `split` as in
        /// `VideoSegment`.
        case video(trackID: CMPersistentTrackID, preferredTransform: CGAffineTransform,
                   frame: ClipFraming, split: SplitScreen?)
        /// A still image, read from `url`, with its camera motion; keyframe
        /// times are relative to `origin`, the output start of its segment.
        case still(url: URL, zoom: [ZoomKeyframe], origin: CMTime)
        /// A title card: solid colour.
        case card(RGBA)
        /// A gap: black.
        case gap

        var trackID: CMPersistentTrackID? {
            if case .video(let trackID, _, _, _) = self { trackID } else { nil }
        }
    }

    /// What a clip transition does over the content. Amounts run linearly
    /// from `from` at the instruction's start to `to` at its end.
    public enum Effect: Sendable, Equatable {
        case none
        /// Black, or white, over the content at the amount as its opacity.
        case dip(white: Bool, from: Double, to: Double)
        /// `other` mixed into the content at the amount as its share.
        case blend(other: Content, from: Double, to: Double)
    }

    public let timeRange: CMTimeRange
    public let content: Content
    public let effect: Effect
    /// Titles whose output range overlaps this instruction's, each with its
    /// style and clamped output range. A title running across segments is in
    /// every instruction it overlaps.
    public let titles: [FrameRenderer.TitleLayer]

    public init(timeRange: CMTimeRange, content: Content, effect: Effect = .none,
                titles: [FrameRenderer.TitleLayer] = []) {
        self.timeRange = timeRange
        self.content = content
        self.effect = effect
        self.titles = titles
    }

    public var enablePostProcessing: Bool { false }
    public var containsTweening: Bool { true }
    public var passthroughTrackID: CMPersistentTrackID { kCMPersistentTrackID_Invalid }

    public var requiredSourceTrackIDs: [NSValue]? {
        var ids = [content.trackID]
        if case .blend(let other, _, _) = effect { ids.append(other.trackID) }
        let tracks = ids.compactMap { $0 }.map { NSNumber(value: $0) }
        return tracks.isEmpty ? nil : tracks
    }
}
