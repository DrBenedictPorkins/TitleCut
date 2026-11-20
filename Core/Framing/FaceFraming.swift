import AVFoundation
import Foundation
import Vision

/// Frame Faces: sets each video clip's framing so the largest face in it is
/// centred in a frame narrower than the source (9:16, 1:1). Where the face
/// settles somewhere new for `minimumHold` or longer, the clip is split there
/// and each part framed on its own. Clips without a face, and split-screen
/// clips, keep their framing.
public enum FaceFraming {
    /// One face in a frame, normalised to the upright frame: `centerX` 0 at
    /// the left edge, `area` a fraction of the frame.
    public struct Face: Sendable, Equatable {
        public var centerX: Double
        public var area: Double

        public init(centerX: Double, area: Double) {
            self.centerX = centerX
            self.area = area
        }
    }

    /// Time between sampled frames, and the most samples per clip.
    static let sampleInterval: Tick = Ticks.perSecond / 4
    static let maximumSamples = 400
    /// How long the face must stay somewhere new before the clip is split.
    public static let minimumHold: Tick = Ticks.perSecond

    /// One part of a clip: where it starts in the source, and its framing
    /// (`nil` when no face was seen in it).
    public struct Part: Sendable, Equatable {
        public var sourceStart: Tick
        public var framing: Double?

        public init(sourceStart: Tick, framing: Double?) {
            self.sourceStart = sourceStart
            self.framing = framing
        }
    }

    /// The parts of a clip starting at `start`, from the subject's position
    /// in time order (source time; `nil` where no face was seen). A part
    /// ends where the position stays more than `threshold` from the part's
    /// median for `minimumHold`; a move that settles sooner than that after
    /// the part began replaces the part's position instead. Each part's
    /// position is the median of its samples.
    public static func parts(_ samples: [(time: Tick, x: Double?)], start: Tick,
                             threshold: Double) -> [(sourceStart: Tick, x: Double?)] {
        var parts: [(start: Tick, xs: [Double])] = [(start, [])]
        var pending: [(time: Tick, x: Double)] = []
        for sample in samples {
            guard let x = sample.x else { continue }
            guard let anchor = median(parts[parts.count - 1].xs) else {
                parts[parts.count - 1].xs.append(x)
                continue
            }
            if abs(x - anchor) <= threshold {
                parts[parts.count - 1].xs.append(x)
                pending = []
                continue
            }
            pending.append((sample.time, x))
            guard let first = pending.first, sample.time - first.time >= minimumHold else {
                continue
            }
            if first.time - parts[parts.count - 1].start < minimumHold {
                parts[parts.count - 1].xs = pending.map(\.x)
            } else {
                parts.append((first.time, pending.map(\.x)))
            }
            pending = []
        }
        return parts.map { ($0.start, median($0.xs)) }
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// The framing that puts `centerX` (0...1 across the upright source) in
    /// the middle of the frame, zoomed in `zoom` times, clamped so the frame
    /// stays on the picture; `nil` when the frame does not crop the source's
    /// sides.
    public static func framing(centering centerX: Double, sourceSize: CGSize,
                               renderSize: CGSize, zoom: Double = 1) -> Double? {
        guard sourceSize.width > 0, sourceSize.height > 0,
              renderSize.width > 0, renderSize.height > 0 else { return nil }
        let width = ClipFraming(x: 0.5, zoom: zoom)
            .visibleRect(sourceSize: sourceSize, in: renderSize).width
        guard width < 1 else { return nil }
        return min(max((centerX - width / 2) / (1 - width), 0), 1)
    }

    /// The start of the first frame showing the face's new position, found
    /// by halving the frames between `old`, a time showing the old position,
    /// and `new`, a time showing the new one. `isNew` is asked about a time
    /// in the middle of a frame. Returns `new`'s frame start when no frame
    /// lies between them, or `new` when the frame rate is unknown.
    static func firstFrame(after old: Tick, upTo new: Tick, frameRate: Double,
                           isNew: (Tick) async throws -> Bool) async rethrows -> Tick {
        guard frameRate.isFinite, frameRate > 0, old < new else { return new }
        let frame = Double(Ticks.perSecond) / frameRate
        var low = Int((Double(old) / frame).rounded(.down))
        var high = Int((Double(new) / frame).rounded(.down))
        while high - low > 1 {
            let middle = (low + high) / 2
            if try await isNew(Tick((Double(middle) + 0.5) * frame)) {
                high = middle
            } else {
                low = middle
            }
        }
        return max(Tick((Double(high) * frame).rounded()), old + 1)
    }

    /// Source times to sample in `range`: every `sampleInterval`, centred,
    /// at most `maximumSamples`, at least one.
    public static func sampleTimes(in range: TickRange) -> [Tick] {
        let count = min(max(Int(range.duration / sampleInterval), 1), maximumSamples)
        let step = range.duration / Tick(count)
        return (0..<count).map { range.start + step / 2 + step * Tick($0) }
    }

    /// Commands that split each clip in `plan` (clip ID to its parts) where
    /// its parts begin and set each part's framing where it changes, in the
    /// order to perform them as one undo step. Split parts get IDs from
    /// `makeID`.
    public static func commands(_ plan: [UUID: [Part]], in project: Project,
                                makeID: () -> UUID = UUID.init) -> [ProjectCommand] {
        var splits: [ProjectCommand] = []
        var framings: [ProjectCommand] = []
        var cursor: Tick = 0
        for segment in project.segments {
            defer { cursor += segment.duration }
            guard case .video(let video) = segment, let parts = plan[video.id],
                  !parts.isEmpty else { continue }
            let range = video.sourceRange
            var ids = [video.id]
            for part in parts.dropFirst() {
                guard part.sourceStart > range.start, part.sourceStart < range.end else {
                    continue
                }
                let id = makeID()
                splits.append(.splitSegment(
                    atOutputTime: cursor + video.outputOffset(ofSource: part.sourceStart),
                    newSegmentID: id))
                ids.append(id)
            }
            let kept = [parts[0]] + parts.dropFirst().filter {
                $0.sourceStart > range.start && $0.sourceStart < range.end
            }
            for (id, part) in zip(ids, kept) {
                guard let framing = part.framing,
                      ids.count > 1 || abs((video.framing ?? 0.5) - framing) > 0.001
                else { continue }
                framings.append(.setSegmentFraming(id: id, framing: framing))
            }
        }
        return splits + framings
    }

    /// Finds the parts of every video clip of `project` in the video at
    /// `url`, the project's first video. Clips with no face are left out.
    public static func find(in project: Project, url: URL,
                            progress: @escaping @Sendable (Double) -> Void = { _ in })
        async throws -> [UUID: [Part]] {
        try await find(in: project, urls: [nil: url], progress: progress)
    }

    /// Finds the parts of every video clip of `project`, each in its video's
    /// file from `urls` (keyed by `VideoSegment.sourceID`). Clips with no
    /// face, whose video is missing from `urls`, whose video the frame
    /// does not crop at the sides, or shown split screen are left out.
    /// - Parameter progress: Fraction of clips done, 0...1, on any thread.
    /// - Throws: `CancellationError` when the task is cancelled, or an
    ///   AVFoundation error when a video cannot be read.
    public static func find(in project: Project, urls: [UUID?: URL],
                            progress: @escaping @Sendable (Double) -> Void = { _ in })
        async throws -> [UUID: [Part]] {
        let renderSize = project.output.size
        let clips = project.segments.compactMap { segment -> VideoSegment? in
            guard case .video(let video) = segment, video.split == nil,
                  let source = project.source(of: video), urls[video.sourceID] != nil,
                  framing(centering: 0.5, sourceSize: source.naturalSize,
                          renderSize: renderSize, zoom: video.frame.zoom) != nil
            else { return nil }
            return video
        }
        // Samples may land up to 1/20 s off; refining a cut needs the exact frame.
        var generators: [UUID?: AVAssetImageGenerator] = [:]
        var exactGenerators: [UUID?: AVAssetImageGenerator] = [:]
        func generator(for key: UUID?, url: URL, exact: Bool = false) -> AVAssetImageGenerator {
            if let made = exact ? exactGenerators[key] : generators[key] { return made }
            let made = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            made.appliesPreferredTrackTransform = true
            made.maximumSize = CGSize(width: 960, height: 960)
            let tolerance = exact ? .zero : CMTime(value: 1, timescale: 20)
            made.requestedTimeToleranceBefore = tolerance
            made.requestedTimeToleranceAfter = tolerance
            if exact { exactGenerators[key] = made } else { generators[key] = made }
            return made
        }

        var plan: [UUID: [Part]] = [:]
        for (index, clip) in clips.enumerated() {
            try Task.checkCancellation()
            guard let source = project.source(of: clip), let url = urls[clip.sourceID] else {
                continue
            }
            let exact = generator(for: clip.sourceID, url: url, exact: true)
            let generator = generator(for: clip.sourceID, url: url)
            // A quarter of the frame's width, in source widths.
            let threshold = clip.frame.visibleRect(sourceSize: source.naturalSize,
                                                   in: renderSize).width / 4
            var samples: [(time: Tick, x: Double?)] = []
            for time in sampleTimes(in: clip.sourceRange) {
                try Task.checkCancellation()
                guard let image = try? await generator.image(at: Ticks.cmTime(time)).image
                else { continue }
                let largest = try faces(in: image).max { $0.area < $1.area }
                samples.append((time, largest?.centerX))
            }
            var found = parts(samples, start: clip.sourceRange.start, threshold: threshold)
            for index in found.indices.dropFirst() {
                // The face moved between the last sample with it in place and this one.
                let boundary = found[index].sourceStart
                guard let newX = found[index].x,
                      let before = samples.last(where: { $0.time < boundary && $0.x != nil })
                else { continue }
                found[index].sourceStart = try await firstFrame(
                    after: before.time, upTo: boundary, frameRate: source.frameRate) { time in
                    try Task.checkCancellation()
                    guard let image = try? await exact.image(at: Ticks.cmTime(time)).image,
                          let x = try faces(in: image).max(by: { $0.area < $1.area })?.centerX
                    else { return false }
                    return abs(x - newX) <= threshold
                }
            }
            let parts = found
                .map { part in
                    Part(sourceStart: part.sourceStart, framing: part.x.flatMap {
                        framing(centering: $0, sourceSize: source.naturalSize,
                                renderSize: renderSize, zoom: clip.frame.zoom)
                    })
                }
            if parts.contains(where: { $0.framing != nil }) { plan[clip.id] = parts }
            progress(Double(index + 1) / Double(max(clips.count, 1)))
        }
        return plan
    }

    /// Faces in an upright frame.
    static func faces(in image: CGImage) throws -> [Face] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        // Vision's boxes are normalised with a bottom-left origin; x runs left to right.
        return (request.results ?? []).map { face in
            Face(centerX: Double(face.boundingBox.midX),
                 area: Double(face.boundingBox.width * face.boundingBox.height))
        }
    }
}
