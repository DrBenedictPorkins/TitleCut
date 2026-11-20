import AVFoundation

/// Builds the playable composition from the model (§6.1).
///
/// One composition track per media type. Every frame is drawn by
/// `TitleCutCompositor` from one `TitleCutInstruction` per segment.
public enum CompositionBuilder {
    /// Source tracks and their properties, loaded asynchronously by the caller.
    public struct SourceTracks: @unchecked Sendable {
        /// Retained because tracks reference their asset weakly; inserting a
        /// track whose asset is gone fails with -11800/-12780.
        public var asset: AVAsset
        public var video: AVAssetTrack
        public var videoTransform: CGAffineTransform
        /// Time range of `video` in the source, which bounds crossfade handles.
        public var videoRange: CMTimeRange
        public var audio: AVAssetTrack?
        /// Time range of `audio` in the source.
        public var audioRange: CMTimeRange

        public init(asset: AVAsset, video: AVAssetTrack, videoTransform: CGAffineTransform,
                    videoRange: CMTimeRange, audio: AVAssetTrack?, audioRange: CMTimeRange) {
            self.asset = asset
            self.video = video
            self.videoTransform = videoTransform
            self.videoRange = videoRange
            self.audio = audio
            self.audioRange = audioRange
        }

        /// Loads the tracks of each video in `urls`, keyed as given
        /// (`VideoSegment.sourceID`). A file without a video track is left out.
        public static func load(_ urls: [UUID?: URL]) async throws -> [UUID?: SourceTracks] {
            var loaded: [UUID?: SourceTracks] = [:]
            for (key, url) in urls {
                loaded[key] = try await load(from: AVURLAsset(url: url))
            }
            return loaded
        }

        /// Loads the first video track and first audio track of `asset`.
        public static func load(from asset: AVAsset) async throws -> SourceTracks? {
            guard let video = try await asset.loadTracks(withMediaType: .video).first else {
                return nil
            }
            let (transform, videoRange) = try await video.load(.preferredTransform, .timeRange)
            let audio = try await asset.loadTracks(withMediaType: .audio).first
            let audioRange = try await audio?.load(.timeRange) ?? .zero
            return SourceTracks(asset: asset, video: video, videoTransform: transform,
                                videoRange: videoRange, audio: audio, audioRange: audioRange)
        }
    }

    /// The music strip's song files, loaded asynchronously by the caller.
    public struct MusicTracks: @unchecked Sendable {
        /// Retained, as for `SourceTracks.asset`.
        var assets: [String: AVAsset] = [:]
        /// First audio track per file name.
        var tracks: [String: AVAssetTrack] = [:]

        public static let none = MusicTracks()

        /// Loads every song `project.music` uses from `MusicFiles`. A song
        /// that cannot be read is left out, and its pieces stay silent.
        public static func load(for project: Project) async -> MusicTracks {
            var loaded = MusicTracks()
            for name in Set(project.music.map(\.fileName)) {
                let asset = AVURLAsset(url: MusicFiles.url(for: name))
                guard let track = try? await asset.loadTracks(withMediaType: .audio).first
                else { continue }
                loaded.assets[name] = asset
                loaded.tracks[name] = track
            }
            return loaded
        }
    }

    /// The playable result: the edited tracks plus the video composition that
    /// routes every frame through `TitleCutCompositor`.
    public struct Output {
        public let composition: AVMutableComposition
        /// `nil` when the project has no segments.
        public let videoComposition: AVVideoComposition?
        /// Music volume and fades; `nil` without music.
        public var audioMix: AVAudioMix?
    }

    /// The composition of a project whose clips all play its first video,
    /// `Project.source`, whose tracks are `tracks`.
    /// - Parameter watermark: Adds the `Watermark` wordmark over the whole
    ///   output, for unpaid exports.
    public static func build(_ project: Project, tracks: SourceTracks,
                             music: MusicTracks = .none,
                             watermark: Bool = false) throws -> Output {
        try build(project, sources: [nil: tracks], music: music, watermark: watermark)
    }

    /// The composition of `project`, each clip from its video's tracks in
    /// `sources` (keyed by `VideoSegment.sourceID`). A clip whose video is
    /// not in `sources` shows black and is silent.
    /// - Parameter watermark: Adds the `Watermark` wordmark over the whole
    ///   output, for unpaid exports.
    public static func build(_ project: Project, sources: [UUID?: SourceTracks],
                             music: MusicTracks = .none,
                             watermark: Bool = false) throws -> Output {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return Output(composition: composition, videoComposition: nil)
        }
        let audio = !sources.values.contains(where: { $0.audio != nil }) ? nil
            : composition.addMutableTrack(withMediaType: .audio,
                                          preferredTrackID: kCMPersistentTrackID_Invalid)

        var layers = titleLayers(project)
        if watermark, let mark = Watermark.layer(for: project, renderSize: renderSize(project)) {
            layers.append(mark)
        }
        var contents: [TitleCutInstruction.Content] = []
        var starts: [Tick] = []
        var cursor: Tick = 0
        let frame = frameDuration(forRate: project.output.frameRate)
        // Empty time after the last video clip does not count in a track's
        // length, so segments there get a held frame instead (below).
        let lastVideo = project.segments.lastIndex { playedTracks(of: $0, sources) != nil }
        for (index, segment) in project.segments.enumerated() {
            let at = Ticks.cmTime(cursor)
            let outputRange = CMTimeRange(start: at, duration: Ticks.cmTime(segment.duration))
            switch (segment, playedTracks(of: segment, sources)) {
            case (.video(let segment), let tracks?):
                let range = segment.sourceRange.cmTimeRange
                try video.insertTimeRange(range, of: tracks.video, at: at)
                if let audio, let audioTrack = tracks.audio {
                    // Source audio may be shorter than the video; insert the overlap.
                    let overlap = range.intersection(tracks.audioRange)
                    if overlap.duration > .zero {
                        let target = CMTimeAdd(at, CMTimeSubtract(overlap.start, range.start))
                        // After a clip of a silent video the sound track ends early.
                        let end = audio.segments.last?.timeMapping.target.end ?? .zero
                        if end < target {
                            audio.insertEmptyTimeRange(CMTimeRange(start: end, end: target))
                        }
                        try audio.insertTimeRange(overlap, of: audioTrack, at: target)
                    }
                }
                if segment.rate != 1 {
                    // Every track so far ends here, so this scales only this clip.
                    composition.scaleTimeRange(CMTimeRange(start: at, duration: range.duration),
                                               toDuration: Ticks.cmTime(segment.outputDuration))
                }
            default:
                if let lastVideo, index < lastVideo {
                    video.insertEmptyTimeRange(outputRange)
                    audio?.insertEmptyTimeRange(outputRange)
                }
            }
            contents.append(content(of: segment, start: cursor, trackID: video.trackID,
                                    project: project, sources: sources))
            starts.append(cursor)
            cursor += segment.duration
        }

        if let trailing = holdStart(project, sources),
           let tracks = lastVideo.flatMap({ playedTracks(of: project.segments[$0], sources) })
               ?? sources[nil] ?? sources.values.first,
           trailing < cursor {
            // The compositor draws these segments without source frames; the
            // held frame only gives the track its length. Audio stays shorter.
            let start = Ticks.cmTime(trailing)
            let held = CMTimeRange(start: tracks.videoRange.start,
                                   duration: min(frame, tracks.videoRange.duration))
            try video.insertTimeRange(held, of: tracks.video, at: start)
            video.scaleTimeRange(CMTimeRange(start: start, duration: held.duration),
                                 toDuration: Ticks.cmTime(cursor - trailing))
        }

        // Each segment draws in up to three parts: the transition at its
        // start, the middle, and the transition at its end.
        let windows = Dictionary(ClipTransitionPlan.windows(project).map { ($0.index, $0) },
                                 uniquingKeysWith: { first, _ in first })
        var handles = HandleTrack(composition: composition, sources: sources,
                                  frameDuration: frame)
        var instructions: [TitleCutInstruction] = []
        for (index, segment) in project.segments.enumerated() {
            let start = starts[index], end = start + segment.duration
            let head = windows[index]?.after ?? 0
            let tail = windows[index + 1]?.before ?? 0
            var parts: [(range: TickRange, effect: TitleCutInstruction.Effect)] = []
            if let window = windows[index], head > 0 {
                let range = TickRange(start: start, duration: head)
                parts.append((range, try effect(of: window, over: range, incoming: true,
                                                project: project, contents: contents,
                                                starts: starts, handles: &handles)))
            }
            if end - tail > start + head {
                parts.append((TickRange(start: start + head, duration: end - tail - start - head),
                              .none))
            }
            if let window = windows[index + 1], tail > 0 {
                let range = TickRange(start: end - tail, duration: tail)
                parts.append((range, try effect(of: window, over: range, incoming: false,
                                                project: project, contents: contents,
                                                starts: starts, handles: &handles)))
            }
            for part in parts {
                instructions.append(TitleCutInstruction(
                    timeRange: part.range.cmTimeRange, content: contents[index],
                    effect: part.effect,
                    titles: layers.filter { $0.outputRange.overlaps(part.range) }))
            }
        }

        guard !instructions.isEmpty else {
            return Output(composition: composition, videoComposition: nil)
        }
        let videoComposition = AVVideoComposition(configuration: .init(
            customVideoCompositorClass: TitleCutCompositor.self,
            frameDuration: frameDuration(forRate: project.output.frameRate),
            instructions: instructions,
            renderSize: renderSize(project)))
        let musicMix = try addMusic(project, music: music, to: composition, total: cursor)
        let clipSound = audio.flatMap { clipSoundParameters(project, track: $0) }
        let inputs = (clipSound.map { [$0] } ?? []) + (musicMix?.inputParameters ?? [])
        var audioMix: AVAudioMix?
        if !inputs.isEmpty {
            let mix = AVMutableAudioMix()
            mix.inputParameters = inputs
            audioMix = mix
        }
        return Output(composition: composition, videoComposition: videoComposition,
                      audioMix: audioMix)
    }

    /// Each clip's volume on the source sound, and speech kept at its pitch
    /// where a clip plays at another speed; `nil` when every clip plays at
    /// normal speed and volume.
    private static func clipSoundParameters(_ project: Project,
                                            track: AVMutableCompositionTrack)
        -> AVAudioMixInputParameters? {
        let videos = project.segments.compactMap { segment -> VideoSegment? in
            if case .video(let video) = segment { video } else { nil }
        }
        guard videos.contains(where: { $0.speed != nil || $0.volume != nil }) else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.audioTimePitchAlgorithm = .spectral
        var cursor: Tick = 0
        var current: Double = 1
        for segment in project.segments {
            defer { cursor += segment.duration }
            guard case .video(let video) = segment else { continue }
            let volume = video.volume ?? 1
            if volume != current {
                parameters.setVolume(Float(volume), at: Ticks.cmTime(cursor))
                current = volume
            }
        }
        return parameters
    }

    /// The tracks `segment` plays: its video's, for a video clip whose
    /// video is in `sources`; otherwise `nil`.
    private static func playedTracks(of segment: Segment,
                                     _ sources: [UUID?: SourceTracks]) -> SourceTracks? {
        if case .video(let video) = segment { sources[video.sourceID] } else { nil }
    }

    /// Output start of the freezes, cards, gaps and clips of missing videos
    /// after the last clip that plays, or `nil` when such a clip is last.
    private static func holdStart(_ project: Project, _ sources: [UUID?: SourceTracks]) -> Tick? {
        guard let last = project.segments.last, playedTracks(of: last, sources) == nil else {
            return nil
        }
        let lastVideo = project.segments.lastIndex { playedTracks(of: $0, sources) != nil }
        return project.segments.prefix(lastVideo.map { $0 + 1 } ?? 0)
            .reduce(0) { $0 + $1.duration }
    }

    /// What segment `segment` draws, starting at output time `start`.
    private static func content(of segment: Segment, start: Tick, trackID: CMPersistentTrackID,
                                project: Project,
                                sources: [UUID?: SourceTracks]) -> TitleCutInstruction.Content {
        switch segment {
        case .video(let video):
            guard let tracks = sources[video.sourceID] else { return .gap }
            return .video(trackID: trackID, preferredTransform: tracks.videoTransform,
                          frame: video.frame, split: video.split)
        case .still(let still):
            guard let image = project.stills.first(where: { $0.id == still.stillID }) else {
                return .gap
            }
            return .still(url: StillFiles.url(for: image.fileName), zoom: still.zoom,
                          origin: Ticks.cmTime(start))
        case .card(let card):
            return .card(card.color)
        case .gap:
            return .gap
        }
    }

    /// The effect of `window` over `range`: the part after the cut when
    /// `incoming`, else the part before it. A crossfade blends in the
    /// segment on the other side of the cut, run on past its own edge.
    private static func effect(of window: ClipTransitionPlan.Window, over range: TickRange,
                               incoming: Bool, project: Project,
                               contents: [TitleCutInstruction.Content], starts: [Tick],
                               handles: inout HandleTrack) throws -> TitleCutInstruction.Effect {
        let (from, to): (Double, Double) = incoming ? (1, 0) : (0, 1)
        guard window.kind == .crossfade, !window.isEdge else {
            return .dip(white: window.kind == .dipToWhite, from: from, to: to)
        }
        let other = incoming ? window.index - 1 : window.index
        var content = contents[other]
        if case .video(let video) = project.segments[other],
           let tracks = handles.sources[video.sourceID] {
            let offset = range.start - starts[other]
            let source = TickRange(start: video.sourceRange.start
                                       + video.sourceOffset(atOutput: offset),
                                   duration: video.sourceOffset(atOutput: range.duration))
            let trackID = try handles.insert(source, of: tracks, at: range.start,
                                             duration: range.duration)
            content = .video(trackID: trackID, preferredTransform: tracks.videoTransform,
                             frame: video.frame, split: video.split)
        }
        return .blend(other: content, from: from / 2, to: to / 2)
    }

    /// A second video track holding the frames crossfades borrow from past
    /// their clips' edges, made when the first is needed.
    private struct HandleTrack {
        let composition: AVMutableComposition
        let sources: [UUID?: SourceTracks]
        let frameDuration: CMTime
        private var track: AVMutableCompositionTrack?
        private var end: CMTime = .zero

        init(composition: AVMutableComposition, sources: [UUID?: SourceTracks],
             frameDuration: CMTime) {
            self.composition = composition
            self.sources = sources
            self.frameDuration = frameDuration
        }

        /// Puts source range `source` of `tracks` at output time `at` (later
        /// than any before it), played over `duration` output ticks. Where
        /// it runs off the source, the first or last frame holds. Returns
        /// the track's ID.
        mutating func insert(_ source: TickRange, of tracks: SourceTracks, at: Tick,
                             duration: Tick) throws -> CMPersistentTrackID {
            let track: AVMutableCompositionTrack
            if let existing = self.track {
                track = existing
            } else if let added = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                track = added
                self.track = added
            } else {
                throw CompositionError.noHandleTrack
            }
            var time = Ticks.cmTime(at)
            if time > end {
                track.insertEmptyTimeRange(CMTimeRange(start: end, end: time))
            }
            let available = tracks.videoRange
            let wanted = source.cmTimeRange
            let overlap = wanted.intersection(available)
            let held = min(frameDuration, available.duration)
            if wanted.start < available.start {
                let missing = overlap.duration > .zero
                    ? CMTimeSubtract(overlap.start, wanted.start) : wanted.duration
                try hold(CMTimeRange(start: available.start, duration: held), of: tracks,
                         for: missing, at: time, in: track)
                time = CMTimeAdd(time, missing)
            }
            if overlap.duration > .zero {
                try track.insertTimeRange(overlap, of: tracks.video, at: time)
                time = CMTimeAdd(time, overlap.duration)
            }
            let remaining = CMTimeSubtract(CMTimeAdd(Ticks.cmTime(at), wanted.duration), time)
            if remaining > .zero {
                try hold(CMTimeRange(start: CMTimeSubtract(available.end, held), duration: held),
                         of: tracks, for: remaining, at: time, in: track)
                time = CMTimeAdd(time, remaining)
            }
            if source.duration != duration {
                track.scaleTimeRange(CMTimeRange(start: Ticks.cmTime(at), end: time),
                                     toDuration: Ticks.cmTime(duration))
                time = Ticks.cmTime(at + duration)
            }
            end = time
            return track.trackID
        }

        /// One frame of `tracks`' video, stretched to `length`.
        private func hold(_ frame: CMTimeRange, of tracks: SourceTracks, for length: CMTime,
                          at time: CMTime, in track: AVMutableCompositionTrack) throws {
            guard frame.duration > .zero else { return }
            try track.insertTimeRange(frame, of: tracks.video, at: time)
            track.scaleTimeRange(CMTimeRange(start: time, duration: frame.duration),
                                 toDuration: length)
        }
    }

    enum CompositionError: Error {
        case noHandleTrack
    }

    /// Puts the music strip on one more audio track, cut off at the end of
    /// the video, with each piece's volume and fades as volume ramps.
    private static func addMusic(_ project: Project, music: MusicTracks,
                                 to composition: AVMutableComposition,
                                 total: Tick) throws -> AVAudioMix? {
        let pieces = project.music.filter { $0.start < total && music.tracks[$0.fileName] != nil }
        guard !pieces.isEmpty, let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        var trackEnd: Tick = 0
        for piece in pieces {
            guard let song = music.tracks[piece.fileName] else { continue }
            let end = min(piece.end, total)
            let length = end - piece.start
            if piece.start > trackEnd {
                track.insertEmptyTimeRange(TickRange(start: trackEnd,
                                                     duration: piece.start - trackEnd).cmTimeRange)
            }
            try track.insertTimeRange(
                TickRange(start: piece.songRange.start, duration: length).cmTimeRange,
                of: song, at: Ticks.cmTime(piece.start))
            trackEnd = end

            let volume = Float(piece.volume)
            let fadeIn = min(piece.fadeIn, length)
            let fadeOut = min(piece.fadeOut, length - fadeIn)
            parameters.setVolume(fadeIn > 0 ? 0 : volume, at: Ticks.cmTime(piece.start))
            if fadeIn > 0 {
                parameters.setVolumeRamp(
                    fromStartVolume: 0, toEndVolume: volume,
                    timeRange: TickRange(start: piece.start, duration: fadeIn).cmTimeRange)
            }
            if fadeOut > 0 {
                parameters.setVolumeRamp(
                    fromStartVolume: volume, toEndVolume: 0,
                    timeRange: TickRange(start: end - fadeOut, duration: fadeOut).cmTimeRange)
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        return mix
    }

    /// Every title that has a style in the project and a non-empty output
    /// range, with that style and range, in `project.titles` order. Titles
    /// may run past their segment; they are clamped only to the output end (§4.2).
    public static func titleLayers(_ project: Project) -> [FrameRenderer.TitleLayer] {
        project.titles.compactMap { title in
            guard let style = project.styles.first(where: { $0.id == title.styleID }),
                  let range = TimelineMath.titleOutputRange(title, in: project),
                  range.duration > 0 else { return nil }
            return FrameRenderer.TitleLayer(title: title, style: style, outputRange: range)
        }
    }

    /// Output size from `OutputSettings`, falling back to the source size.
    public static func renderSize(_ project: Project) -> CGSize {
        let size = project.output.size
        if size.width > 0, size.height > 0 { return size }
        return project.source?.naturalSize ?? CGSize(width: 1920, height: 1080)
    }

    /// Frame duration for a nominal rate as stored in `OutputSettings`.
    ///
    /// `AVAssetTrack.nominalFrameRate` is a Float, so a 30 fps source arrives
    /// as 29.999998092651367 and a 29.97 fps source as about 29.97003. Rates
    /// within 0.01 of a standard NTSC rate (24000/1001, 30000/1001, 60000/1001)
    /// or of a whole number snap to it exactly; anything else uses the rate as
    /// given at a 600 000 timescale.
    public static func frameDuration(forRate rate: Double) -> CMTime {
        guard rate.isFinite, rate > 0 else { return CMTime(value: 1, timescale: 30) }
        for ntsc in [24, 30, 60] {
            let exact = Double(ntsc * 1000) / 1001
            if abs(rate - exact) < 0.01 {
                return CMTime(value: 1001, timescale: CMTimeScale(ntsc * 1000))
            }
        }
        let whole = rate.rounded()
        if abs(rate - whole) < 0.01 {
            return CMTime(value: 1, timescale: CMTimeScale(whole))
        }
        return CMTime(seconds: 1 / rate, preferredTimescale: 600_000)
    }
}

private extension TickRange {
    func overlaps(_ other: TickRange) -> Bool {
        start < other.end && other.start < end
    }
}
